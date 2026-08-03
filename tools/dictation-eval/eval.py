#!/usr/bin/env python3
"""Offline A/B harness for the dictation refiner's prompt.

Runs `cases.json` through the same system prompt production builds
(`DictationRefiner.preamble` + the `dictation` policy body + the glossary block +
the output-format suffix) and scores each case with substring assertions.

Stdlib only -- no venv, no `pip install`. See README.md.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent.parent
PROMPT_SPEC = REPO_ROOT / "Kikimi" / "Prompts" / "PromptSpec.swift"
REFINER = REPO_ROOT / "Kikimi" / "Dictation" / "DictationRefiner.swift"
CONFIG = Path.home() / ".config" / "kikimi" / "config.yaml"

SCHEMA = {
    "type": "object",
    "properties": {"refined_text": {"type": "string"}},
    "required": ["refined_text"],
    "additionalProperties": False,
}


# --- Endpoint defaults ---------------------------------------------------------


def read_openai_provider() -> dict[str, str]:
    """The scalar keys of `llm.providers.openai` from `~/.config/kikimi/config.yaml`.

    Defaulting the endpoint from the config means the only thing a run needs from the
    operator is the API key (which lives in a Secure-Enclave-encrypted blob and is not
    readable from here). It also keeps the real endpoint out of this repo, which is
    headed for OSS.

    Deliberately a 20-line scanner rather than PyYAML: the section is a flat block of
    `key: value` scalars, and taking a dependency would cost this tool its "stdlib only,
    no venv" property for one nested lookup.
    """
    if not CONFIG.exists():
        return {}
    values: dict[str, str] = {}
    depth = None
    for line in CONFIG.read_text().splitlines():
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if depth is None:
            if stripped == "openai:":
                depth = indent
            continue
        # Any line at or left of `openai:`'s own indentation ends the section.
        if stripped and indent <= depth:
            break
        key, separator, value = stripped.partition(":")
        if not separator:
            continue
        values[key.strip()] = value.strip().strip("'\"")
    return values


def endpoint_default(key: str, env: str, fallback: str = "") -> str:
    if os.environ.get(env):
        return os.environ[env]
    return read_openai_provider().get(key) or fallback


# --- Swift constant extraction -------------------------------------------------
#
# The prompt bodies live in Swift source, and the whole point of this harness is to
# score the body that ships. Extracting the literal keeps the harness in step with
# `PromptSpec.swift` without a build step; the alternative (`Kikimi --render-prompt
# dictation`) needs a built `.app` and injects its own sample glossary, which would
# make the glossary column of the A/B untunable.


def extract_multiline_literal(source: str, name: str) -> str:
    """Returns the Swift triple-quoted literal assigned to `name`, indentation stripped
    the way the Swift compiler strips it (by the closing delimiter's indentation)."""
    start = re.search(rf'\b{re.escape(name)}\s*=\s*"""\n', source)
    if not start:
        raise SystemExit(f"could not find a multi-line literal named {name}")
    rest = source[start.end() :]
    end = re.search(r'\n([ \t]*)"""', rest)
    if not end:
        raise SystemExit(f"unterminated multi-line literal for {name}")
    indent = end.group(1)
    lines = rest[: end.start()].split("\n")
    return "\n".join(line[len(indent) :] if line.startswith(indent) else line for line in lines)


def extract_string_literal(source: str, name: str) -> str:
    match = re.search(rf'\b{re.escape(name)}\s*=\s*"((?:[^"\\]|\\.)*)"', source)
    if not match:
        raise SystemExit(f"could not find a string literal named {name}")
    # Only the escapes Swift prompt literals actually use. `unicode_escape` would round-trip
    # the non-ASCII body through latin-1 and mojibake every Japanese character.
    literal = match.group(1)
    for escaped, plain in (("\\n", "\n"), ("\\t", "\t"), ('\\"', '"'), ("\\\\", "\\")):
        literal = literal.replace(escaped, plain)
    return literal


def build_system_prompt(body: str, glossary_block: str | None) -> str:
    refiner_src = REFINER.read_text()
    spec_src = PROMPT_SPEC.read_text()
    preamble = extract_string_literal(refiner_src, "preamble")
    suffix = extract_multiline_literal(refiner_src, "outputFormatSuffix")

    sections = [body.strip()]
    if glossary_block:
        header = extract_multiline_literal(spec_src, "glossaryHeaderDefaultBody")
        sections.append(header.strip() + "\n\n" + glossary_block.strip())
    context = "\n\n".join(sections)
    return f"{preamble}\n\n{context}\n\n{suffix}"


# --- LLM call ------------------------------------------------------------------


def call(system: str, user: str, args) -> tuple[str, int]:
    """Returns the refined text and the round-trip in milliseconds.

    Latency is reported because `dictation.refine_timeout_ms` (3000 by default) is a hard
    budget: any lever that trades latency for quality -- notably raising
    `reasoning_effort` above production's `none` -- has to be judged against it, and a run
    that scores well while blowing the budget would silently fall back to the raw text."""
    url = args.base_url.rstrip("/") + "/chat/completions"
    if args.api_version:
        url += f"?api-version={args.api_version}"
    body = {
        "model": args.model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "response", "strict": False, "schema": SCHEMA},
        },
    }
    if args.reasoning_effort:
        body["reasoning_effort"] = args.reasoning_effort

    headers = {"Content-Type": "application/json"}
    # Same rule as `OpenAIChatBackend.resolveAuthHeaderKind`: an api_version means the
    # Azure-legacy `api-key` header, otherwise a plain bearer token.
    if args.api_version:
        headers["api-key"] = args.api_key
    else:
        headers["Authorization"] = f"Bearer {args.api_key}"

    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        payload = json.load(response)
    elapsed_ms = round((time.monotonic() - started) * 1000)
    content = payload["choices"][0]["message"]["content"]
    return json.loads(content)["refined_text"], elapsed_ms


# --- Scoring -------------------------------------------------------------------


def score(case: dict, refined: str) -> list[str]:
    """Returns the list of violated assertions (empty means the run passed)."""
    failures = []
    for needle in case.get("must_not_contain", []):
        if needle in refined:
            failures.append(f'残存: "{needle}"')
    for needle in case.get("must_contain", []):
        if needle not in refined:
            failures.append(f'消失: "{needle}"')
    for needle, limit in case.get("max_count", {}).items():
        actual = refined.count(needle)
        if actual > limit:
            failures.append(f'重複: "{needle}" x{actual} (<={limit})')
    return failures


def resolve_body(args) -> str:
    """The policy body to score: an explicit file, a git revision's `PromptSpec.swift`,
    or the working tree's."""
    if args.body:
        return Path(args.body).read_text()
    if args.body_rev:
        relative = PROMPT_SPEC.relative_to(REPO_ROOT)
        source = subprocess.run(
            ["git", "show", f"{args.body_rev}:{relative}"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        return extract_multiline_literal(source, "dictationDefaultBody")
    return extract_multiline_literal(PROMPT_SPEC.read_text(), "dictationDefaultBody")


def run(args) -> int:
    cases = json.loads((TOOL_DIR / "cases.json").read_text())["cases"]
    body = resolve_body(args)
    glossary = None if args.no_glossary else Path(args.glossary).read_text()
    system = build_system_prompt(body, glossary)

    if args.print_prompt:
        print(system)
        return 0

    jobs = [(case, trial) for case in cases for trial in range(args.trials)]

    def work(job):
        case, trial = job
        try:
            refined, elapsed_ms = call(system, case["raw"], args)
        except (urllib.error.URLError, KeyError, ValueError) as error:
            return case["id"], trial, None, 0, [f"呼び出し失敗: {error}"]
        return case["id"], trial, refined, elapsed_ms, score(case, refined)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        raw_results = list(pool.map(work, jobs))

    by_case: dict[str, list] = {case["id"]: [] for case in cases}
    for case_id, trial, refined, elapsed_ms, failures in raw_results:
        by_case[case_id].append({"trial": trial, "refined": refined, "elapsed_ms": elapsed_ms, "failures": failures})

    results = {
        "model": args.model,
        "reasoning_effort": args.reasoning_effort,
        "trials": args.trials,
        "system_prompt": system,
        "cases": [],
    }
    total_pass = 0
    for case in cases:
        runs = sorted(by_case[case["id"]], key=lambda r: r["trial"])
        passed = sum(1 for r in runs if not r["failures"])
        total_pass += passed
        results["cases"].append(
            {"id": case["id"], "shape": case.get("shape", ""), "raw": case["raw"], "passed": passed, "runs": runs}
        )
        mark = "OK  " if passed == args.trials else ("FAIL" if passed == 0 else "FLAK")
        print(f'{mark} {passed}/{args.trials}  {case["id"]}  ({case.get("shape", "")})')
        for r in runs:
            if r["failures"]:
                print(f'       - {" / ".join(r["failures"])}')
                print(f'         out: {r["refined"]}')

    total = len(cases) * args.trials
    latencies = sorted(r["elapsed_ms"] for runs in by_case.values() for r in runs if r["elapsed_ms"])
    print(f"\n合計 {total_pass}/{total} runs pass ({len(cases)} cases x {args.trials} trials)")
    if latencies:
        p50 = latencies[len(latencies) // 2]
        p90 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.9))]
        budget = " ★予算超過" if p90 > 3000 else ""
        print(f"レイテンシ p50 {p50}ms / p90 {p90}ms / max {latencies[-1]}ms（refine_timeout_ms=3000）{budget}")
        results["latency_ms"] = {"p50": p50, "p90": p90, "max": latencies[-1]}

    if args.out:
        Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(f"結果を {args.out} に書き出しました")
    return 0 if total_pass == total else 1


def compare(args) -> int:
    before = json.loads(Path(args.before).read_text())
    after = json.loads(Path(args.after).read_text())
    before_by_id = {c["id"]: c for c in before["cases"]}

    # 3 試行では 0/3 と 3/3 の差もサンプリングで出る（同一プロンプトの再実行で観測済み）。
    # ケース単位の増減を読むには 10 以上が要る。
    if min(before["trials"], after["trials"]) < 10:
        print(f'※ trials={before["trials"]}/{after["trials"]}: ケース単位の増減はぶれの範囲かもしれない\n')

    print(f'{"case":<32} {"before":>8} {"after":>8}')
    for case in after["cases"]:
        old = before_by_id.get(case["id"])
        old_pass = f'{old["passed"]}/{before["trials"]}' if old else "-"
        new_pass = f'{case["passed"]}/{after["trials"]}'
        arrow = ""
        if old:
            old_rate = old["passed"] / before["trials"]
            new_rate = case["passed"] / after["trials"]
            arrow = "  改善" if new_rate > old_rate else ("  退行" if new_rate < old_rate else "")
        print(f'{case["id"]:<32} {old_pass:>8} {new_pass:>8}{arrow}')

    old_total = sum(c["passed"] for c in before["cases"])
    new_total = sum(c["passed"] for c in after["cases"])
    print(
        f'\n合計 {old_total}/{len(before["cases"]) * before["trials"]}'
        f' → {new_total}/{len(after["cases"]) * after["trials"]}'
    )
    for label, data in (("before", before), ("after", after)):
        latency = data.get("latency_ms")
        if latency:
            print(f'{label:<7} p50 {latency["p50"]}ms / p90 {latency["p90"]}ms  effort={data.get("reasoning_effort") or "(未指定)"}')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run", help="cases.json を1本ずつ整形させて採点する")
    run_parser.add_argument("--body", help="方針層本文のファイル（省略時は作業ツリーの PromptSpec.swift から抽出）")
    run_parser.add_argument(
        "--body-rev",
        help="git のリビジョンの PromptSpec.swift から本文を取る（A/B の変更前側。例: --body-rev HEAD）",
    )
    run_parser.add_argument("--glossary", default=str(TOOL_DIR / "sample-glossary.md"))
    run_parser.add_argument("--no-glossary", action="store_true", help="用語集ブロックを注入しない")
    # 3 だとサンプリングのぶれがケース単位の差に匹敵する（同一プロンプトの再実行で 0/3 と 3/3 の
    # 両方を観測した）。判断に使う測定は 10 以上にする。
    run_parser.add_argument("--trials", type=int, default=10, help="1ケースあたりの試行回数（既定: 10）")
    run_parser.add_argument("--concurrency", type=int, default=8)
    run_parser.add_argument("--out", help="結果 JSON の出力先（compare で使う）")
    run_parser.add_argument("--print-prompt", action="store_true", help="組み立てた system prompt を出して終了")
    # 既定は ~/.config/kikimi/config.yaml の llm.providers.openai から取る。API キーだけは
    # Secure Enclave 鍵で暗号化されていて読めないので、env か --api-key で渡す。
    run_parser.add_argument("--model", default=endpoint_default("model", "KIKIMI_EVAL_MODEL", "gpt-5.4-mini"))
    run_parser.add_argument("--base-url", default=endpoint_default("base_url", "KIKIMI_EVAL_BASE_URL"))
    run_parser.add_argument("--api-key", default=os.environ.get("KIKIMI_EVAL_API_KEY", ""))
    run_parser.add_argument("--api-key-file", help="API キーを書いたファイル（--api-key より優先）")
    run_parser.add_argument("--api-version", default=endpoint_default("api_version", "KIKIMI_EVAL_API_VERSION"))
    run_parser.add_argument(
        "--reasoning-effort",
        default=endpoint_default("reasoning_effort", "KIKIMI_EVAL_REASONING_EFFORT"),
        help="production の設定に合わせる（既定は config.yaml の値）",
    )
    run_parser.add_argument("--timeout", type=float, default=60.0)
    run_parser.set_defaults(func=run)

    compare_parser = sub.add_parser("compare", help="2つの結果 JSON を並べる")
    compare_parser.add_argument("before")
    compare_parser.add_argument("after")
    compare_parser.set_defaults(func=compare)

    args = parser.parse_args()
    if args.command == "run" and not args.print_prompt:
        if args.api_key_file:
            args.api_key = Path(args.api_key_file).read_text().strip()
        if not args.base_url:
            raise SystemExit(
                f"エンドポイントが決まりません。{CONFIG} の llm.providers.openai.base_url を設定するか、"
                "--base-url / KIKIMI_EVAL_BASE_URL で渡してください"
            )
        if not args.api_key:
            raise SystemExit("API キーが必要です（--api-key-file / --api-key / KIKIMI_EVAL_API_KEY）")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
