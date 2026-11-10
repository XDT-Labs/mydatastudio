"""Gemma 4 native tool-call syntax ⇄ OpenAI ``tool_calls``.

In ``tool_choice: "auto"`` mode llama-cpp-python hands back Gemma's tool call
as plain text in ``content``::

    <|tool_call>call:search{from:<|"|>Sarah<|"|>,query:<|"|>lease<|"|>}<tool_call|>

This module turns that into OpenAI-shaped ``tool_calls`` and strips the
thinking blocks (``<|channel>…<channel|>``) Gemma opens answers with. It also
converts history going the other way: the Gemma chat template refuses
``arguments`` as a JSON string, which is what every OpenAI client sends.

The format is recorded in docs/plans/llm-tools/gemma4-tool-format.md. Parsing
is strict: text we can't decode is never turned into a call.
"""
from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

CALL_OPEN = "<|tool_call>"
CALL_CLOSE = "<tool_call|>"
STRING_DELIM = '<|"|>'
THINK_OPEN = "<|channel>"
THINK_CLOSE = "<channel|>"

_CALL_HEAD = re.compile(r"call:([A-Za-z_][A-Za-z0-9_.\-]*)")
_NUMBER = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?")
# Bare object keys end at the colon. Anything structural in a key means the
# text isn't what the template emits.
_BARE_KEY = re.compile(r"[^\s:{}\[\],]+")


class ToolCallFormatError(ValueError):
    """Text that looks like a Gemma tool call but doesn't decode."""


@dataclass
class ParsedReply:
    """A model reply split into the text to show and the calls to run."""

    content: Optional[str]
    tool_calls: List[Dict[str, Any]] = field(default_factory=list)
    # One message per block that looked like a call but didn't parse.
    errors: List[str] = field(default_factory=list)


def strip_thinking(text: str) -> str:
    """Remove every ``<|channel>…<channel|>`` block and trim the result.

    An unclosed block (generation cut off mid-thought) is dropped to the end:
    half a thought is not an answer.
    """
    out: List[str] = []
    pos = 0
    while True:
        start = text.find(THINK_OPEN, pos)
        if start == -1:
            out.append(text[pos:])
            break
        out.append(text[pos:start])
        end = text.find(THINK_CLOSE, start + len(THINK_OPEN))
        if end == -1:
            break
        pos = end + len(THINK_CLOSE)
    return "".join(out).strip()


def parse_reply(text: str) -> ParsedReply:
    """Split a raw Gemma reply into visible content and OpenAI tool calls."""
    text = strip_thinking(text)
    calls: List[Dict[str, Any]] = []
    errors: List[str] = []
    kept: List[str] = []
    pos = 0
    while True:
        start = text.find(CALL_OPEN, pos)
        if start == -1:
            kept.append(text[pos:])
            break
        kept.append(text[pos:start])
        end = text.find(CALL_CLOSE, start)
        block_end = len(text) if end == -1 else end + len(CALL_CLOSE)
        block = text[start:block_end]
        try:
            if end == -1:
                raise ToolCallFormatError("tool call never closed (output cut off?)")
            name, args = _decode_call(text[start + len(CALL_OPEN):end])
            calls.append(_openai_call(name, args, len(calls)))
        except ToolCallFormatError as e:
            label = _CALL_HEAD.match(text, start + len(CALL_OPEN))
            errors.append(f"{label.group(1) if label else '<unknown>'}: {e}")
            kept.append(block)  # leave it visible; never guess a call
        pos = block_end
    content = "".join(kept).strip()
    return ParsedReply(content=content or None, tool_calls=calls, errors=errors)


def decode_arguments(text: str) -> Dict[str, Any]:
    """Decode a Gemma argument object (``{key:value,…}``) into a dict."""
    parser = _Parser(text)
    value = parser.value()
    parser.skip_ws()
    if not parser.at_end():
        raise ToolCallFormatError(f"unexpected text after arguments at {parser.pos}")
    if not isinstance(value, dict):
        raise ToolCallFormatError("arguments must be an object")
    return value


def arguments_to_mappings(messages: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Copy ``messages`` with every ``tool_calls[].function.arguments`` as a dict.

    The Gemma template raises on string arguments; OpenAI clients always send
    strings. Messages without tool calls are returned as-is (same objects).
    """
    out: List[Dict[str, Any]] = []
    for msg in messages:
        calls = msg.get("tool_calls")
        if not calls:
            out.append(msg)
            continue
        converted = []
        for call in calls:
            fn = dict(call.get("function") or {})
            args = fn.get("arguments")
            if isinstance(args, str):
                try:
                    fn["arguments"] = json.loads(args) if args.strip() else {}
                except json.JSONDecodeError as e:
                    raise ToolCallFormatError(
                        f"tool call {call.get('id')!r} has arguments that are not JSON: {e}"
                    ) from e
            converted.append({**call, "function": fn})
        out.append({**msg, "tool_calls": converted})
    return out


class ToolCallStreamFilter:
    """Stream-side counterpart to ``parse_reply``.

    Feed each content delta in; get back only the text that is safe to show.
    Thinking blocks are dropped and, when ``parse_calls`` is set, tool-call
    blocks are held. Anything that might be the start of a marker split
    across deltas ("<|tool" + "_call>") is held until it's confirmed or ruled
    out. ``finish()`` returns the remaining visible text and the parsed calls.
    A call that doesn't parse is released as text at the end, never run.
    """

    _NORMAL, _CALL, _THINK = "normal", "call", "think"

    def __init__(self, parse_calls: bool):
        self.parse_calls = parse_calls
        self._state = self._NORMAL
        self._buf = ""
        self._blocks: List[str] = []

    def _openers(self) -> List[str]:
        return [THINK_OPEN, CALL_OPEN] if self.parse_calls else [THINK_OPEN]

    def feed(self, text: str) -> str:
        self._buf += text
        out: List[str] = []
        while True:
            if self._state == self._NORMAL:
                hits = [(self._buf.find(m), m) for m in self._openers()]
                hits = [(i, m) for i, m in hits if i != -1]
                if not hits:
                    keep = _partial_suffix(self._buf, self._openers())
                    out.append(self._buf[:len(self._buf) - keep])
                    self._buf = self._buf[len(self._buf) - keep:]
                    return "".join(out)
                i, marker = min(hits)
                out.append(self._buf[:i])
                self._buf = self._buf[i:]
                self._state = self._CALL if marker == CALL_OPEN else self._THINK
            elif self._state == self._CALL:
                end = self._buf.find(CALL_CLOSE)
                if end == -1:
                    return "".join(out)
                end += len(CALL_CLOSE)
                self._blocks.append(self._buf[:end])
                self._buf = self._buf[end:]
                self._state = self._NORMAL
            else:  # thinking: discard, keeping only a possible partial close
                end = self._buf.find(THINK_CLOSE)
                if end == -1:
                    keep = _partial_suffix(self._buf, [THINK_CLOSE])
                    self._buf = self._buf[len(self._buf) - keep:]
                    return "".join(out)
                self._buf = self._buf[end + len(THINK_CLOSE):]
                self._state = self._NORMAL

    def finish(self):
        """Return ``(visible_tail, tool_calls, errors)`` once the stream ends."""
        tail: List[str] = []
        if self._state == self._NORMAL:
            tail.append(self._buf)
        elif self._state == self._CALL:
            self._blocks.append(self._buf)  # unclosed; parse_reply reports it
        self._buf = ""
        calls: List[Dict[str, Any]] = []
        errors: List[str] = []
        for block in self._blocks:
            reply = parse_reply(block)
            for call in reply.tool_calls:
                calls.append(_openai_call(
                    call["function"]["name"],
                    json.loads(call["function"]["arguments"]),
                    len(calls),
                ))
            errors.extend(reply.errors)
            if reply.errors:
                tail.append(block)
        self._blocks = []
        return "".join(tail), calls, errors


def _partial_suffix(text: str, markers: List[str]) -> int:
    """Length of the longest suffix of ``text`` that starts some marker."""
    best = 0
    for marker in markers:
        for n in range(min(len(marker) - 1, len(text)), 0, -1):
            if text.endswith(marker[:n]):
                best = max(best, n)
                break
    return best


def _decode_call(body: str):
    head = _CALL_HEAD.match(body)
    if not head:
        raise ToolCallFormatError("missing 'call:NAME'")
    return head.group(1), decode_arguments(body[head.end():])


def _openai_call(name: str, args: Dict[str, Any], index: int) -> Dict[str, Any]:
    return {
        "id": f"call_{index}_{uuid.uuid4().hex[:12]}",
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(args)},
    }


class _Parser:
    """Recursive-descent decoder for the template's ``format_argument`` output."""

    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def at_end(self) -> bool:
        return self.pos >= len(self.text)

    def skip_ws(self) -> None:
        while not self.at_end() and self.text[self.pos].isspace():
            self.pos += 1

    def expect(self, token: str) -> None:
        self.skip_ws()
        if not self.text.startswith(token, self.pos):
            raise ToolCallFormatError(f"expected {token!r} at {self.pos}")
        self.pos += len(token)

    def peek(self, token: str) -> bool:
        self.skip_ws()
        return self.text.startswith(token, self.pos)

    def value(self) -> Any:
        self.skip_ws()
        if self.at_end():
            raise ToolCallFormatError("expected a value, found end of input")
        if self.peek(STRING_DELIM):
            return self.string()
        ch = self.text[self.pos]
        if ch == "{":
            return self.obj()
        if ch == "[":
            return self.array()
        for word, val in (("true", True), ("false", False), ("null", None)):
            if self.text.startswith(word, self.pos):
                self.pos += len(word)
                return val
        m = _NUMBER.match(self.text, self.pos)
        if m:
            self.pos = m.end()
            raw = m.group(0)
            return float(raw) if any(c in raw for c in ".eE") else int(raw)
        raise ToolCallFormatError(f"unexpected {ch!r} at {self.pos}")

    def string(self) -> str:
        self.expect(STRING_DELIM)
        end = self.text.find(STRING_DELIM, self.pos)
        if end == -1:
            raise ToolCallFormatError("string never closed")
        s = self.text[self.pos:end]
        self.pos = end + len(STRING_DELIM)
        return s

    def key(self) -> str:
        if self.peek(STRING_DELIM):
            return self.string()
        m = _BARE_KEY.match(self.text, self.pos)
        if not m:
            raise ToolCallFormatError(f"expected a key at {self.pos}")
        self.pos = m.end()
        return m.group(0)

    def obj(self) -> Dict[str, Any]:
        self.expect("{")
        result: Dict[str, Any] = {}
        if self.peek("}"):
            self.pos += 1
            return result
        while True:
            k = self.key()
            self.expect(":")
            result[k] = self.value()
            if self.peek(","):
                self.pos += 1
                continue
            self.expect("}")
            return result

    def array(self) -> List[Any]:
        self.expect("[")
        items: List[Any] = []
        if self.peek("]"):
            self.pos += 1
            return items
        while True:
            items.append(self.value())
            if self.peek(","):
                self.pos += 1
                continue
            self.expect("]")
            return items
