# Gemma 4 tool-call format (as shipped)

Phase 0 recording for [llm-tools.md](../llm-tools.md). Source: `tokenizer.chat_template` in
`gemma-4-12B-it-Q4_0.gguf` (template header: "Google Gemma 4 Canonical Chat Template",
published 2026-07-09), plus raw output captured through `llama-cpp-python` 0.3.31
`Gemma4ChatHandler` with the production loader (`load_local_model`, mmproj attached,
`n_ctx=32768`), `temperature=0`. Recorded 2026-10-25.

If the GGUF or `llama-cpp-python` is upgraded, re-run the spike and update this file. The
parser in `aiserver/src/aichat/tool_calls.py` is written against it.

## Markers

| Purpose | Syntax |
|---|---|
| Tool declaration (in the system turn) | `<\|tool>declaration:NAME{description:…,parameters:{…}}<tool\|>` |
| Tool call (model output) | `<\|tool_call>call:NAME{key:value,…}<tool_call\|>` |
| Tool result (fed back) | `<\|tool_response>response:NAME{…}<tool_response\|>` |
| String delimiter | `<\|"\|>` on both sides, no escaping inside |
| Thinking block | `<\|channel>thought\n…<channel\|>` |
| Turns | `<\|turn>system` / `user` / `model` … `<turn\|>` |

## Argument encoding inside a call

The template's `format_argument` macro, mirrored by what the model emits:

- **Strings:** `<|"|>text<|"|>`.
- **Numbers:** bare. **Booleans:** `true` / `false`. **Null:** `null`.
- **Arrays:** `[a,b]`.
- **Objects:** `{key:value}`. Keys are **bare** (not quoted) at the top level of a call.
  Nested keys are also bare in calls (`escape_keys=False`).
- Keys come out sorted alphabetically, because the template renders them through `dictsort`.

## Captured output

**Auto mode** (`tool_choice: "auto"`). Prompt: "Find emails from Sarah about the apartment
lease since March 2024." 2.5s.

```
<|tool_call>call:search{after:<|"|>2024-03-01<|"|>,from:<|"|>Sarah<|"|>,query:<|"|>apartment lease<|"|>,sources:[<|"|>email<|"|>]}<tool_call|>
```

- llama-cpp returns this as **plain `content`** with `finish_reason: "stop"` and
  `tool_calls: null`. Nothing parses it; that's our job.
- Argument quality was good: the date is resolved, `from` is a separate argument, and `sources`
  is used.

**A question that needs no tool** ("What is 17 * 3?"), auto mode, 1.1s: `17 * 3 = 51`, with no
call.

**Forced mode** (`tool_choice: {"function": {"name": "search"}}`), 2.6s. Structured, OpenAI-shaped:

```json
{"id": "call__0_search_cmpl-…", "type": "function",
 "function": {"name": "search",
              "arguments": "{\"query\": \"from:Sarah apartment lease\", \"sources\": [\"email\"], \"after\": \"2024-03-01\"}"}}
```

Here the JSON grammar replaces Gemma's native syntax, and argument quality **dropped**: the
sender was put into `query` as `from:Sarah` instead of the `from` argument.

**Answer after a tool result**, 3.5s:

```
<|channel>thought\n<channel|>I found one email from Sarah regarding the apartment lease: …
```

The answer starts with an **empty thinking block**, which must be stripped before the text
reaches the user.

## Consequences for Phase 1

1. **The parser reads `content`**, extracts every `<|tool_call>…<tool_call|>` block, decodes the
   argument syntax above into a dict, and returns OpenAI `tool_calls` with `arguments` as a JSON
   string.
2. **Strip `<|channel>…<channel|>` thinking blocks** from all content, with or without tools.
3. **History going back to the model:** the template **raises** if
   `tool_calls[].function.arguments` is a string ("must be a JSON object (mapping), not a
   string"). OpenAI clients send a string, so the server must `json.loads` it before rendering.
   `role: "tool"` messages are matched to their call by `tool_call_id` and rendered as
   `<|tool_response>` by the template itself; no work needed there.
4. **Streaming:** hold back output from the first `<|tool_call>` and from any `<|channel>` until
   its closing marker.
5. **Process exit:** the spike script hit `GGML_ASSERT([rsets->data count] == 0)` in
   `ggml_metal_device_free` while exiting, after all output was produced. It's a known
   llama.cpp Metal teardown issue, and harmless for the eval runner. Worth checking whether the
   aiserver's SIGTERM shutdown path hits it too.
