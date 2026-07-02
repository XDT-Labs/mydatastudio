"""
Built-in skill registry for /command intercept.

Skills stored in the Flutter SQLite DB are injected by the client before the
HTTP request arrives. This registry provides the same built-in defaults for
callers that access the API directly (e.g. curl), and backs the GET /skills
endpoint so Flutter can enumerate them for autocomplete.

Custom user-defined skills (from the aichat_skills table) are NOT here;
the Flutter client handles those on its side.
"""

from typing import Optional

# trigger → { name, description, system_prompt }
SKILL_REGISTRY: dict[str, dict] = {
    "/summarize": {
        "name": "Summarize",
        "description": "Condense content into a concise bullet-point summary.",
        "system_prompt": (
            "You are a summarization assistant. Summarize the following content "
            "concisely using bullet points. Be brief and capture only the key points."
        ),
    },
    "/analyze": {
        "name": "Analyze",
        "description": "Deep analysis of themes, patterns, and key insights.",
        "system_prompt": (
            "You are an analytical assistant. Analyze the following content in depth. "
            "Identify themes, patterns, key insights, and notable details. "
            "Structure your response clearly."
        ),
    },
    "/translate": {
        "name": "Translate",
        "description": "Translate text to English.",
        "system_prompt": (
            "You are a translation assistant. Translate the user's message to English. "
            "Output only the translation with no additional commentary."
        ),
    },
    "/explain": {
        "name": "Explain",
        "description": "Explain a concept or text in simple terms.",
        "system_prompt": (
            "You are a teacher. Explain the following in simple, clear terms that "
            "anyone can understand. Use examples where helpful."
        ),
    },
    "/rewrite": {
        "name": "Rewrite",
        "description": "Rewrite text to be clearer and more professional.",
        "system_prompt": (
            "You are a professional editor. Rewrite the following text to be clearer, "
            "more concise, and more professional while preserving the original meaning. "
            "Output only the rewritten text."
        ),
    },
}


def apply_skill(messages: list[dict]) -> list[dict]:
    """
    If the last user message starts with a known /trigger, replace the system
    message with the skill's prompt and strip the trigger word from the content.
    Returns the (possibly modified) message list.
    """
    if not messages:
        return messages

    last = messages[-1]
    if last.get("role") != "user":
        return messages

    content = last.get("content", "")
    if not isinstance(content, str) or not content.startswith("/"):
        return messages

    trigger, _, rest = content.partition(" ")
    skill = SKILL_REGISTRY.get(trigger)
    if not skill:
        return messages

    result = list(messages)
    # Strip the trigger from the user message (keep any text that followed it)
    result[-1] = {**last, "content": rest if rest.strip() else content}

    # Replace or prepend system message with the skill's prompt
    if result and result[0].get("role") == "system":
        result[0] = {"role": "system", "content": skill["system_prompt"]}
    else:
        result.insert(0, {"role": "system", "content": skill["system_prompt"]})

    return result


def list_skills() -> list[dict]:
    """Return all built-in skills as a list for the GET /skills endpoint."""
    return [
        {"trigger": trigger, **info}
        for trigger, info in SKILL_REGISTRY.items()
    ]
