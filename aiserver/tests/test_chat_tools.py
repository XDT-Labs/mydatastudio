"""Tool calling through /v1/chat/completions (docs/plans/llm-tools.md, Phase 1).

The client's agent loop depends on three things this layer guarantees: tools
reach the model, a call comes back as OpenAI ``tool_calls`` (never as visible
``<|tool_call>`` text), and tool history from the client is accepted by the
Gemma template. The model is mocked with output recorded from the real one.
"""
import json
from unittest.mock import Mock, patch

import pytest
from fastapi import HTTPException

from aichat.models import ChatCompletionRequest, ChatMessage
from aichat.routes import generate_chat_completion

RECORDED_CALL = (
    '<|tool_call>call:search{after:<|"|>2024-03-01<|"|>,from:<|"|>Sarah<|"|>,'
    'query:<|"|>apartment lease<|"|>,sources:[<|"|>email<|"|>]}<tool_call|>'
)
TOOLS = [{"type": "function", "function": {
    "name": "search", "description": "Search the archive.",
    "parameters": {"type": "object", "properties": {"query": {"type": "string"}},
                   "required": ["query"]}}}]


def _llm(result):
    llm = Mock()
    llm.chat_handler = object()  # vision handler present; images not stripped
    llm.create_chat_completion = Mock(return_value=result)
    return llm


def _completion(content=None, tool_calls=None, finish="stop"):
    message = {"role": "assistant", "content": content}
    if tool_calls is not None:
        message["tool_calls"] = tool_calls
    return {"id": "x", "model": "m", "choices": [
        {"index": 0, "message": message, "finish_reason": finish}]}


def _chunks(*pieces, finish="stop"):
    out = [{"choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]}]
    out += [{"choices": [{"index": 0, "delta": {"content": p}, "finish_reason": None}]} for p in pieces]
    out.append({"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
    return iter(out)


def _request(**kw):
    kw.setdefault("messages", [ChatMessage(role="user", content="find the lease")])
    return ChatCompletionRequest(model="m", **kw)


async def _call(llm, request):
    with patch("aichat.routes.get_llm_instance", return_value=llm), \
         patch("aichat.routes.get_current_model_id", return_value="m"), \
         patch("aichat.routes.model_registry.lookup", return_value=None):
        response = await generate_chat_completion(request)
        if request.stream:
            body = "".join([p if isinstance(p, str) else p.decode()
                            async for p in response.body_iterator])
            events = [json.loads(line[6:]) for line in body.splitlines()
                      if line.startswith("data: ") and line[6:] != "[DONE]"]
            return events, body
        return response


# ── Request models ───────────────────────────────────────────────────────────

def test_messages_can_carry_a_tool_turn():
    call = {"id": "c1", "type": "function", "function": {"name": "search", "arguments": "{}"}}
    assistant = ChatMessage(role="assistant", content=None, tool_calls=[call])
    tool = ChatMessage(role="tool", tool_call_id="c1", content='{"total": 0}')
    assert assistant.content is None and assistant.tool_calls == [call]
    assert tool.tool_call_id == "c1"
    req = ChatCompletionRequest(messages=[assistant, tool], tools=TOOLS, tool_choice="auto")
    assert req.tools == TOOLS and req.tool_choice == "auto"


# ── Non-streaming ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_tools_reach_the_model_and_a_native_call_comes_back_structured():
    llm = _llm(_completion(content=RECORDED_CALL))
    result = await _call(llm, _request(tools=TOOLS, tool_choice="auto"))

    kwargs = llm.create_chat_completion.call_args.kwargs
    assert kwargs["tools"] == TOOLS and kwargs["tool_choice"] == "auto"
    choice = result["choices"][0]
    assert choice["finish_reason"] == "tool_calls"
    assert choice["message"]["content"] is None
    (call,) = choice["message"]["tool_calls"]
    assert call["function"]["name"] == "search"
    assert json.loads(call["function"]["arguments"])["from"] == "Sarah"


@pytest.mark.asyncio
async def test_answer_without_a_call_is_plain_content_with_thinking_stripped():
    llm = _llm(_completion(content="<|channel>thought\n<channel|>Your lease renews May 1."))
    result = await _call(llm, _request(tools=TOOLS))
    choice = result["choices"][0]
    assert choice["message"]["content"] == "Your lease renews May 1."
    assert not choice["message"].get("tool_calls")
    assert choice["finish_reason"] == "stop"


@pytest.mark.asyncio
async def test_without_tools_thinking_is_stripped_but_nothing_becomes_a_call():
    llm = _llm(_completion(content="<|channel>thought\n<channel|>" + RECORDED_CALL))
    result = await _call(llm, _request())
    assert "tools" not in llm.create_chat_completion.call_args.kwargs
    message = result["choices"][0]["message"]
    assert message["content"] == RECORDED_CALL
    assert not message.get("tool_calls")


@pytest.mark.asyncio
async def test_tool_history_reaches_the_template_with_mapping_arguments():
    # The Gemma template raises on string arguments; clients send strings.
    llm = _llm(_completion(content="Found it."))
    messages = [
        ChatMessage(role="user", content="find the lease"),
        ChatMessage(role="assistant", content=None, tool_calls=[{
            "id": "c1", "type": "function",
            "function": {"name": "search", "arguments": '{"query": "lease"}'}}]),
        ChatMessage(role="tool", tool_call_id="c1", content='{"total": 1}'),
    ]
    await _call(llm, _request(messages=messages, tools=TOOLS))
    sent = llm.create_chat_completion.call_args.kwargs["messages"]
    assert sent[1]["tool_calls"][0]["function"]["arguments"] == {"query": "lease"}
    assert sent[2] == {"role": "tool", "content": '{"total": 1}', "tool_call_id": "c1"}


@pytest.mark.asyncio
async def test_unparseable_history_arguments_are_a_400_not_a_500():
    llm = _llm(_completion(content="x"))
    messages = [ChatMessage(role="assistant", content=None, tool_calls=[{
        "id": "c1", "type": "function", "function": {"name": "search", "arguments": "{oops"}}])]
    with pytest.raises(HTTPException) as exc:
        await _call(llm, _request(messages=messages, tools=TOOLS))
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_forced_tool_choice_passes_llama_cpps_structured_call_through():
    forced = [{"id": "call_x", "type": "function",
               "function": {"name": "search", "arguments": '{"query": "lease"}'}}]
    llm = _llm(_completion(content=None, tool_calls=forced, finish="tool_calls"))
    choice = {"type": "function", "function": {"name": "search"}}
    result = await _call(llm, _request(tools=TOOLS, tool_choice=choice))
    assert result["choices"][0]["message"]["tool_calls"] == forced


# ── Streaming ────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_streamed_call_arrives_as_tool_calls_and_never_as_text():
    pieces = ["Let me look. ", RECORDED_CALL[:15], RECORDED_CALL[15:60], RECORDED_CALL[60:]]
    events, body = await _call(_llm(_chunks(*pieces)), _request(tools=TOOLS, stream=True))

    shown = "".join(e["choices"][0]["delta"].get("content") or "" for e in events)
    assert shown.strip() == "Let me look."
    assert "<|" not in body
    last = events[-1]["choices"][0]
    assert last["finish_reason"] == "tool_calls"
    (call,) = last["delta"]["tool_calls"]
    assert call["index"] == 0 and call["function"]["name"] == "search"
    # Exactly one terminal event, and it's the tool-call one.
    assert sum(1 for e in events if e["choices"][0].get("finish_reason")) == 1
    assert body.rstrip().endswith("data: [DONE]")


@pytest.mark.asyncio
async def test_streamed_answer_keeps_its_finish_reason_and_loses_its_thinking():
    pieces = ["<|channel>thought\n", "<channel|>Renews ", "May 1."]
    events, body = await _call(_llm(_chunks(*pieces)), _request(tools=TOOLS, stream=True))
    shown = "".join(e["choices"][0]["delta"].get("content") or "" for e in events)
    assert shown == "Renews May 1."
    assert "channel" not in body
    assert events[-1]["choices"][0]["finish_reason"] == "stop"
    assert all(e["id"] == events[0]["id"] for e in events)  # stable id for /v1/chat/stop


# ── Cloud models ─────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_tools_sent_to_a_cloud_model_are_refused_not_dropped():
    # Silently dropping them would make the model answer "I can't access
    # your files" with no sign anything went wrong.
    req = ChatCompletionRequest(model="gemini-2.0-flash", tools=TOOLS,
                                messages=[ChatMessage(role="user", content="hi")])
    with patch("aichat.routes.model_registry.lookup", return_value=None), \
         patch("aichat.routes._handle_gemini_request") as cloud:
        with pytest.raises(HTTPException) as exc:
            await generate_chat_completion(req)
    assert exc.value.status_code == 400
    assert "gemini" in exc.value.detail.lower()
    cloud.assert_not_called()
