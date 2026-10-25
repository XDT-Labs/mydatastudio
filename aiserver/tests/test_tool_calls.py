"""Parsing Gemma 4's native tool-call syntax (docs/plans/llm-tools.md, Phase 1).

llama-cpp-python returns a Gemma tool call in ``tool_choice: "auto"`` mode as
plain ``content``, not as ``tool_calls``. If this parser misses a call, the
user sees ``<|tool_call>call:search{…}`` as the chat reply and nothing gets
searched. If it invents one, we run a tool nobody asked for. The fixtures
here are verbatim model output recorded in
docs/plans/llm-tools/gemma4-tool-format.md, not hand-written guesses.
"""
import json

import pytest

from aichat.tool_calls import (
    ToolCallFormatError,
    ToolCallStreamFilter,
    arguments_to_mappings,
    decode_arguments,
    parse_reply,
    strip_thinking,
)

# Verbatim from the Phase 0 spike.
RECORDED_CALL = (
    '<|tool_call>call:search{after:<|"|>2024-03-01<|"|>,from:<|"|>Sarah<|"|>,'
    'query:<|"|>apartment lease<|"|>,sources:[<|"|>email<|"|>]}<tool_call|>'
)
RECORDED_ANSWER_AFTER_TOOL = (
    "<|channel>thought\n<channel|>I found one email from Sarah regarding the "
    "apartment lease."
)


# ── Argument decoding ────────────────────────────────────────────────────────

def test_decodes_the_recorded_call_arguments():
    args = decode_arguments(
        '{after:<|"|>2024-03-01<|"|>,from:<|"|>Sarah<|"|>,'
        'query:<|"|>apartment lease<|"|>,sources:[<|"|>email<|"|>]}'
    )
    assert args == {
        "after": "2024-03-01",
        "from": "Sarah",
        "query": "apartment lease",
        "sources": ["email"],
    }


def test_decodes_scalars_the_template_can_emit():
    args = decode_arguments("{limit:8,ratio:-0.5,exact:true,fuzzy:false,cursor:null}")
    assert args == {"limit": 8, "ratio": -0.5, "exact": True, "fuzzy": False, "cursor": None}


def test_string_delimiter_needs_no_escaping_for_json_specials():
    # Gemma strings are delimited by <|"|>, so quotes, braces, commas and
    # colons inside them are literal text, not syntax. A naive split on ","
    # or ":" would cut "Re: lease, {draft}" into pieces.
    args = decode_arguments('{query:<|"|>Re: "lease", {draft}<|"|>}')
    assert args == {"query": 'Re: "lease", {draft}'}


def test_decodes_nested_objects_and_empty_containers():
    args = decode_arguments("{filters:{tags:[],range:{}},ids:[1,2]}")
    assert args == {"filters": {"tags": [], "range": {}}, "ids": [1, 2]}


def test_tolerates_whitespace_between_tokens():
    assert decode_arguments('{ query : <|"|>x<|"|> , limit : 3 }') == {"query": "x", "limit": 3}


@pytest.mark.parametrize(
    "bad",
    [
        '{query:<|"|>unterminated}',  # string never closed
        "{query:}",                   # missing value
        "{limit:8",                   # object never closed
        "{limit 8}",                  # missing colon
        "[1,2]",                      # arguments must be an object
        '{a:1} trailing',             # junk after the object
    ],
)
def test_malformed_arguments_raise_rather_than_guess(bad):
    with pytest.raises(ToolCallFormatError):
        decode_arguments(bad)


# ── Whole replies ────────────────────────────────────────────────────────────

def test_recorded_call_becomes_an_openai_tool_call():
    reply = parse_reply(RECORDED_CALL)
    assert reply.content is None
    assert len(reply.tool_calls) == 1
    call = reply.tool_calls[0]
    assert call["type"] == "function"
    assert call["function"]["name"] == "search"
    # OpenAI clients expect arguments as a JSON *string*.
    assert json.loads(call["function"]["arguments"])["from"] == "Sarah"
    assert call["id"].startswith("call_")


def test_text_before_a_call_is_kept_as_content():
    reply = parse_reply("Let me look that up.\n" + RECORDED_CALL)
    assert reply.content == "Let me look that up."
    assert [c["function"]["name"] for c in reply.tool_calls] == ["search"]


def test_several_calls_in_one_reply_keep_their_order_and_get_distinct_ids():
    text = (
        '<|tool_call>call:search{query:<|"|>lease<|"|>}<tool_call|>'
        "<|tool_call>call:list_collections{}<tool_call|>"
    )
    reply = parse_reply(text)
    names = [c["function"]["name"] for c in reply.tool_calls]
    assert names == ["search", "list_collections"]
    assert json.loads(reply.tool_calls[1]["function"]["arguments"]) == {}
    assert reply.tool_calls[0]["id"] != reply.tool_calls[1]["id"]


def test_plain_answer_has_no_tool_calls():
    reply = parse_reply("17 * 3 = 51")
    assert reply.content == "17 * 3 = 51"
    assert reply.tool_calls == []


def test_empty_thinking_block_is_stripped_from_the_answer():
    # Recorded: the answer after a tool result opens with an empty thought
    # channel. Left in, the user sees "<|channel>thought" above the answer.
    reply = parse_reply(RECORDED_ANSWER_AFTER_TOOL)
    assert reply.content == "I found one email from Sarah regarding the apartment lease."


def test_thinking_with_content_is_stripped_too():
    assert strip_thinking("<|channel>thought\nuse search<channel|>Answer") == "Answer"


def test_malformed_call_is_left_visible_and_not_executed():
    # Never invent a call from text we can't parse. Leaving it in content is
    # ugly but honest, and the error is logged for the eval to count.
    text = '<|tool_call>call:search{query:<|"|>lease}<tool_call|>'
    reply = parse_reply(text)
    assert reply.tool_calls == []
    assert reply.content == text
    assert reply.errors and "search" in reply.errors[0]


def test_call_cut_off_by_max_tokens_is_not_executed():
    text = '<|tool_call>call:search{query:<|"|>lea'
    reply = parse_reply(text)
    assert reply.tool_calls == []
    assert reply.errors


# ── History going back to the template ───────────────────────────────────────

def test_string_arguments_in_history_become_mappings_for_the_template():
    # The Gemma template raises on string arguments ("must be a JSON object
    # (mapping), not a string"), but OpenAI clients always send a string.
    messages = [
        {"role": "user", "content": "find the lease"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {"id": "c1", "type": "function",
                 "function": {"name": "search", "arguments": '{"query": "lease"}'}}
            ],
        },
        {"role": "tool", "tool_call_id": "c1", "content": "{}"},
    ]
    out = arguments_to_mappings(messages)
    assert out[1]["tool_calls"][0]["function"]["arguments"] == {"query": "lease"}
    # The caller's list is not mutated: routes.py reuses it for logging.
    assert messages[1]["tool_calls"][0]["function"]["arguments"] == '{"query": "lease"}'
    assert out[0] == messages[0] and out[2] == messages[2]


def test_unparseable_history_arguments_raise():
    messages = [{
        "role": "assistant",
        "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "search", "arguments": "{not json"}}],
    }]
    with pytest.raises(ToolCallFormatError):
        arguments_to_mappings(messages)


# ── Streaming hold-back ──────────────────────────────────────────────────────
#
# Tokens arrive in pieces, so a marker can be split across chunks
# ("<|tool" + "_call>"). Anything that might be the start of a marker is held
# until it is either confirmed (and swallowed) or ruled out (and released).
# The property that matters: the user never sees call syntax or a thought.

def _stream(filt, pieces):
    visible = "".join(filt.feed(p) for p in pieces)
    tail, calls, errors = filt.finish()
    return visible + tail, calls, errors


def test_stream_releases_text_and_swallows_a_call_split_across_chunks():
    pieces = ["Let me ", "check.<|tool", '_call>call:search{query:<|"|>x<|"|>}<tool', "_call|>"]
    shown, calls, errors = _stream(ToolCallStreamFilter(parse_calls=True), pieces)
    assert shown == "Let me check."
    assert [c["function"]["name"] for c in calls] == ["search"]
    assert json.loads(calls[0]["function"]["arguments"]) == {"query": "x"}
    assert errors == []


def test_stream_never_emits_marker_text_at_any_point():
    filt = ToolCallStreamFilter(parse_calls=True)
    for piece in [RECORDED_CALL[i:i + 3] for i in range(0, len(RECORDED_CALL), 3)]:
        assert "<|" not in filt.feed(piece)
    tail, calls, _ = filt.finish()
    assert tail == "" and len(calls) == 1


def test_stream_drops_a_thinking_block_split_across_chunks():
    pieces = ["<|chan", "nel>thought\nsearch first<chan", "nel|>I found ", "one email."]
    shown, calls, _ = _stream(ToolCallStreamFilter(parse_calls=True), pieces)
    assert shown == "I found one email."
    assert calls == []


def test_stream_releases_a_lone_angle_bracket_that_is_not_a_marker():
    # Holding back "<" is right; keeping it forever would eat real text.
    shown, _, _ = _stream(ToolCallStreamFilter(parse_calls=True), ["if a <", " b then"])
    assert shown == "if a < b then"


def test_stream_shows_a_malformed_call_instead_of_running_it():
    bad = '<|tool_call>call:search{query:<|"|>lease}<tool_call|>'
    shown, calls, errors = _stream(ToolCallStreamFilter(parse_calls=True), [bad])
    assert calls == [] and errors
    assert shown == bad


def test_stream_shows_a_call_cut_off_by_max_tokens():
    cut = '<|tool_call>call:search{query:<|"|>lea'
    shown, calls, errors = _stream(ToolCallStreamFilter(parse_calls=True), [cut])
    assert calls == [] and errors
    assert shown == cut


def test_stream_without_tools_offered_never_produces_a_call():
    # Tools weren't offered, so nothing may run. The text stays visible;
    # thinking is still stripped.
    shown, calls, _ = _stream(
        ToolCallStreamFilter(parse_calls=False), ["<|channel>thought\n<channel|>", RECORDED_CALL])
    assert calls == []
    assert shown == RECORDED_CALL
