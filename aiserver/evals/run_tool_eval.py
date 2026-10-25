"""Tool-calling eval for the local model (docs/plans/llm-tools.md, Phase 0).

Answers one question before we build on it: does the shipped Gemma model pick
the right tool, with usable arguments, often enough? It needs the real model
on disk, so it is a script, not part of the pytest run.

    cd aiserver
    PYTHONPATH=src .venv/bin/python evals/run_tool_eval.py               # all modes
    PYTHONPATH=src .venv/bin/python evals/run_tool_eval.py --modes auto  # one mode
    PYTHONPATH=src .venv/bin/python evals/run_tool_eval.py --only file-w2

Modes:
  auto    tools + tool_choice "auto"; the call is parsed from Gemma's native
          syntax by aichat.tool_calls (what Phase 1 would ship).
  forced  tool_choice names the expected tool; llama.cpp grammar-constrains
          JSON arguments. An argument-quality reference, not a shippable mode:
          it can't decide *whether* to call. Skipped for no-tool cases.
  router  no tools param; one grammar-constrained JSON reply choosing
          {"tool": NAME|"none", "args": {...}}. The fallback if auto fails.

Gate (from the plan): auto must choose correctly in >= 85% of cases, with
>= 90% schema-valid arguments among correct-tool calls.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import jsonschema

from aichat.tool_calls import arguments_to_mappings, parse_reply

HERE = Path(__file__).parent
DEFAULT_MODEL_DIR = Path.home() / (
    "Library/Application Support/com.xdtlabs.mydatastudio.dev/models/"
    "ggml-org-gemma-4-12B-it-GGUF-local"
)
TODAY = "2026-10-25"
SYSTEM = (
    f"You are an assistant inside a personal archive app. Today is {TODAY}. "
    "The user's emails and files are only reachable through the tools. Use a tool "
    "when the question is about the user's own data; answer directly otherwise. "
    "Never invent results."
)
GATE_TOOL = 0.85
GATE_ARGS = 0.90


def load_cases(only: str | None):
    cases = [json.loads(l) for l in (HERE / "tool_calls.jsonl").read_text().splitlines() if l.strip()]
    return [c for c in cases if not only or c["id"] == only]


def messages_for(case, system=SYSTEM):
    return arguments_to_mappings(
        [{"role": "system", "content": system}, *case.get("history", []),
         {"role": "user", "content": case["prompt"]}]
    )


def args_match(expect: dict, args: dict) -> list[str]:
    """Return the expectations that failed (empty = all matched)."""
    misses = []
    for key, rule in expect.items():
        val = args.get(key)
        ok = val is not None
        if ok and "equals" in rule:
            ok = str(val).lower() == str(rule["equals"]).lower()
        if ok and "contains" in rule:
            ok = rule["contains"].lower() in str(val).lower()
        if ok and "contains_any" in rule:
            ok = any(w.lower() in str(val).lower() for w in rule["contains_any"])
        if ok and "prefix" in rule:
            ok = str(val).startswith(rule["prefix"])
        if ok and "includes" in rule:
            ok = isinstance(val, list) and rule["includes"] in val
        if not ok:
            misses.append(f"{key}={val!r} !~ {rule}")
    return misses


def score(case, tools_by_name, name, args, raw, seconds, errors=()):
    expect = case.get("expect_tool")
    result = {"id": case["id"], "expected": expect, "called": name, "args": args,
              "seconds": round(seconds, 2), "raw": raw, "parse_errors": list(errors)}
    result["tool_correct"] = name == expect
    if name and name in tools_by_name:
        try:
            jsonschema.validate(args, tools_by_name[name]["function"]["parameters"])
            result["args_valid"] = True
        except jsonschema.ValidationError as e:
            result["args_valid"] = False
            result["schema_error"] = e.message
    elif name:
        result["args_valid"] = False
        result["schema_error"] = f"unknown tool {name!r}"
    if result["tool_correct"] and expect:
        result["arg_misses"] = args_match(case.get("expect_args", {}), args or {})
    return result


def run_auto(llm, case, tools, by_name):
    t = time.time()
    r = llm.create_chat_completion(messages=messages_for(case), tools=tools,
                                   tool_choice="auto", temperature=0, max_tokens=300)
    raw = r["choices"][0]["message"].get("content") or ""
    reply = parse_reply(raw)
    call = reply.tool_calls[0] if reply.tool_calls else None
    name = call["function"]["name"] if call else None
    args = json.loads(call["function"]["arguments"]) if call else None
    return score(case, by_name, name, args, raw, time.time() - t, reply.errors)


def run_forced(llm, case, tools, by_name):
    expect = case.get("expect_tool")
    if not expect:
        return None
    t = time.time()
    r = llm.create_chat_completion(
        messages=messages_for(case), tools=tools, temperature=0, max_tokens=300,
        tool_choice={"type": "function", "function": {"name": expect}})
    msg = r["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    name = calls[0]["function"]["name"] if calls else None
    try:
        args = json.loads(calls[0]["function"]["arguments"]) if calls else None
    except json.JSONDecodeError:
        args = None
    return score(case, by_name, name, args, json.dumps(calls) or msg.get("content"), time.time() - t)


def router_system(tools):
    lines = [SYSTEM, "", "Available tools (JSON Schema for args):"]
    for tool in tools:
        f = tool["function"]
        lines.append(f"- {f['name']}: {f['description']} args={json.dumps(f['parameters'])}")
    lines += ["", 'Reply with JSON only: {"tool": "<name>", "args": {...}} to use a tool, '
              'or {"tool": "none", "answer": "<reply>"} to answer directly.']
    return "\n".join(lines)


def run_router(llm, case, tools, by_name):
    names = [t["function"]["name"] for t in tools]
    schema = {"type": "object", "properties": {
        "tool": {"type": "string", "enum": names + ["none"]},
        "args": {"type": "object"}, "answer": {"type": "string"}}, "required": ["tool"]}
    t = time.time()
    r = llm.create_chat_completion(
        messages=messages_for(case, router_system(tools)), temperature=0, max_tokens=300,
        response_format={"type": "json_object", "schema": schema})
    raw = r["choices"][0]["message"].get("content") or ""
    try:
        parsed = json.loads(raw)
        name = None if parsed.get("tool") == "none" else parsed.get("tool")
        args = parsed.get("args") or {} if name else None
    except json.JSONDecodeError:
        name, args = None, None
    return score(case, by_name, name, args, raw, time.time() - t)


def summarize(mode, results):
    results = [r for r in results if r]
    n = len(results)
    correct = sum(r["tool_correct"] for r in results)
    calls = [r for r in results if r["tool_correct"] and r["expected"]]
    valid = sum(r.get("args_valid", False) for r in calls)
    matched = sum(not r.get("arg_misses") for r in calls)
    lat = sorted(r["seconds"] for r in results)
    s = {"mode": mode, "cases": n,
         "tool_correct": correct / n if n else 0,
         "args_valid": valid / len(calls) if calls else 0,
         "args_match": matched / len(calls) if calls else 0,
         "median_s": lat[len(lat) // 2] if lat else 0,
         "max_s": lat[-1] if lat else 0}
    s["passes_gate"] = s["tool_correct"] >= GATE_TOOL and s["args_valid"] >= GATE_ARGS
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="auto,forced,router")
    ap.add_argument("--only", help="run a single case id")
    ap.add_argument("--model-dir", default=str(DEFAULT_MODEL_DIR))
    ap.add_argument("--out", default=str(HERE / "results"))
    opts = ap.parse_args()

    from aichat.model_manager import load_local_model  # heavy import, after argparse

    d = Path(opts.model_dir)
    llm = load_local_model("gemma4-eval", str(d / "gemma-4-12B-it-Q4_0.gguf"),
                           str(d / "mmproj-gemma-4-12B-it-Q8_0.gguf"))
    tools = json.loads((HERE / "tools.json").read_text())
    by_name = {t["function"]["name"]: t for t in tools}
    cases = load_cases(opts.only)
    runners = {"auto": run_auto, "forced": run_forced, "router": run_router}

    report = {"date": time.strftime("%Y-%m-%d %H:%M"), "model": d.name, "summaries": [], "results": {}}
    for mode in opts.modes.split(","):
        results = []
        for case in cases:
            res = runners[mode](llm, case, tools, by_name)
            results.append(res)
            if res:
                flag = "ok " if res["tool_correct"] and not res.get("arg_misses") else "BAD"
                print(f"[{mode}] {flag} {case['id']:<28} -> {res['called']} {json.dumps(res['args'])}", flush=True)
        report["results"][mode] = results
        report["summaries"].append(summarize(mode, results))

    out = Path(opts.out)
    out.mkdir(exist_ok=True)
    path = out / f"tool_eval_{time.strftime('%Y%m%d_%H%M%S')}.json"
    path.write_text(json.dumps(report, indent=2))

    print("\n| Mode | Cases | Right tool | Valid args | Args match | Median s | Max s | Gate |")
    print("|---|---|---|---|---|---|---|---|")
    for s in report["summaries"]:
        print(f"| {s['mode']} | {s['cases']} | {s['tool_correct']:.0%} | {s['args_valid']:.0%} | "
              f"{s['args_match']:.0%} | {s['median_s']} | {s['max_s']} | "
              f"{'pass' if s['passes_gate'] else 'fail'} |")
    print(f"\nFull results: {path}")
    sys.stdout.flush()
    # llama.cpp's Metal backend can assert while freeing at interpreter exit
    # (recorded in gemma4-tool-format.md). The report is already written.
    os._exit(0)


if __name__ == "__main__":
    main()
