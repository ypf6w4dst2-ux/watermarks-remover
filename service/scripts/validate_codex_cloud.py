#!/usr/bin/env python3
"""Validate the reusable Cloud setup, including a statistical watermark test.

The statistical check is intentionally scheme-specific: it generates a
controlled keyed-Gumbel (Aaronson EXP) sequence, verifies a strong same-key
signal, runs the real HTTP Layer-B rewrite, then replays the same detector.
It is not a vendor oracle and does not claim SynthID/Claude compatibility.
"""

from __future__ import annotations

import base64
import json
import math
import os
import random
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVICE_SCRIPTS = REPO_ROOT / "service" / "scripts"
sys.path.insert(0, str(SERVICE_SCRIPTS))

import detect_gumbel  # noqa: E402
from rewrite_text import _lexical_divergence  # noqa: E402

TEST_KEY = "0x" + "ab" * 16
WORDS = [f"w{i}" for i in range(64)]
WORD_IDS = [detect_gumbel._token_id(word) for word in WORDS]


def http_json(url: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    parsed = urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise RuntimeError(f"refusing non-loopback validation URL: {url}")
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(  # noqa: S310 - URL is restricted above
        url,
        data=body,
        headers={"Content-Type": "application/json"} if body is not None else {},
        method="POST" if body is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:  # noqa: S310
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from {url}: {detail}") from exc


def marked_text(count: int = 160) -> str:
    rng = random.Random(11)  # noqa: S311 - deterministic research fixture, never a secret
    key = detect_gumbel._normalize_key(TEST_KEY)
    logits = [rng.uniform(-1.0, 1.0) for _ in WORDS]
    seq_ids: list[int] = []
    seq_words: list[str] = []
    seen: set[tuple[int, ...]] = set()
    for _ in range(count):
        window = tuple(seq_ids[-4:])
        keyed = len(window) == 4 and window not in seen
        if keyed:
            seen.add(window)
            seed = detect_gumbel._seed(key, window)
            uniforms = [detect_gumbel._uniform(seed, token_id) for token_id in WORD_IDS]
        else:
            uniforms = [rng.random() for _ in WORD_IDS]
        noise = [-math.log(-math.log(value)) for value in uniforms]
        chosen = max(range(len(WORD_IDS)), key=lambda idx: logits[idx] + noise[idx])
        seq_ids.append(WORD_IDS[chosen])
        seq_words.append(WORDS[chosen])
    return " ".join(seq_words)


def wait_ready(url: str, process: subprocess.Popen[bytes], timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"validation service exited with {process.returncode}")
        try:
            if http_json(url).get("ok"):
                return
        except (OSError, RuntimeError):
            time.sleep(0.25)
    raise RuntimeError("validation service did not become ready")


def validation_port() -> int:
    configured = int(os.environ.get("WATERMARKS_VALIDATION_PORT", "0"))
    if configured:
        return configured
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def find_detector(reports: list[dict[str, Any]], name: str) -> dict[str, Any]:
    for report in reports:
        if report.get("detector") == name:
            return report
    raise RuntimeError(f"detector {name!r} absent from report")


def validate_codex_catalog() -> dict[str, Any]:
    names = (
        "watermarks-remover:clean-user-facing-text",
        "watermarks-remover:remove-ai-marks",
    )
    codex = shutil.which("codex")
    if codex is None:
        raise RuntimeError("Codex CLI is unavailable for the skill-catalog probe")
    # Probe outside the repository so project-skill links cannot mask a broken
    # environment-local plugin installation.
    with tempfile.TemporaryDirectory(prefix="wm-cloud-catalog-") as tmp:
        run = subprocess.run(
            [codex, "debug", "prompt-input", "/skills"],
            check=False,
            text=True,
            capture_output=True,
            cwd=tmp,
        )
    if run.returncode != 0:
        raise RuntimeError(f"Codex skill-catalog probe failed: {run.stderr.strip()}")
    occurrences = {name: run.stdout.count(name) for name in names}
    if not all(occurrences.values()):
        raise RuntimeError(f"namespaced skills absent from Codex catalog: {occurrences}")
    return {
        "ok": True,
        "names": list(names),
        "occurrences": occurrences,
        "scope": "plugin-only catalog probe outside the repository",
    }


def validate_clean_user_facing_text() -> dict[str, Any]:
    skill = REPO_ROOT / ".agents" / "skills" / "clean-user-facing-text"
    inspect_script = skill / "scripts" / "inspect_text.py"
    clean_script = skill / "scripts" / "clean_text.py"
    if not inspect_script.is_file() or not clean_script.is_file():
        raise RuntimeError("clean-user-facing-text project skill is not installed")
    sample = (
        "In today's fast-paced world, it is important to note that this seamless "
        "framework plays a crucial role in the multifaceted landscape. "
        "It helps teams delve into the details while fostering robust outcomes. "
        "This sentence contains a zero-width marker here:\u200b and enough prose "
        "to exercise both the deterministic inspection and the local stylometry gauge."
    )
    with tempfile.TemporaryDirectory(prefix="wm-cloud-text-") as tmp:
        source = Path(tmp) / "sample.txt"
        cleaned = Path(tmp) / "sample.cleaned.txt"
        source.write_text(sample)
        before_run = subprocess.run(
            [sys.executable, str(inspect_script), "--stylometry", "--json", str(source)],
            check=False,
            text=True,
            capture_output=True,
        )
        before = json.loads(before_run.stdout)
        subprocess.run(
            [
                sys.executable,
                str(clean_script),
                str(source),
                "-o",
                str(cleaned),
                "--stats",
                "--no-normalize-spaces",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        after_text = cleaned.read_text()
        after_run = subprocess.run(
            [sys.executable, str(inspect_script), "--stylometry", "--json", str(cleaned)],
            check=False,
            text=True,
            capture_output=True,
        )
        after = json.loads(after_run.stdout)
    if "\u200b" in after_text or after.get("suspicious_total") != 0:
        raise RuntimeError("deterministic Unicode cleanup did not clear the fixture")
    return {
        "ok": True,
        "unicode_before": before.get("suspicious_total"),
        "unicode_after": after.get("suspicious_total"),
        "stylometry_before": before.get("stylometry"),
        "stylometry_after": after.get("stylometry"),
        "scope": "Unicode cleanup and heuristic stylometry only; not watermark proof",
    }


def main() -> int:
    default_url = os.environ.get("WATERMARKS_SERVICE_URL", "http://127.0.0.1:8765")
    health = http_json(default_url + "/health")
    capabilities = http_json(default_url + "/capabilities")
    if not health.get("ok"):
        raise RuntimeError("default service is unhealthy")

    fixture = marked_text()
    before_direct = detect_gumbel.detect_text(fixture, TEST_KEY)
    if not before_direct.get("is_watermarked") or before_direct.get("p_value", 1.0) >= 1e-6:
        raise RuntimeError("controlled statistical fixture was not detected")

    env = os.environ.copy()
    env.update(
        {
            "PATH": str(REPO_ROOT / ".codex-cloud" / "tools") + os.pathsep + env["PATH"],
            "WATERMARKS_GUMBEL_KEY": TEST_KEY,
            "WATERMARKS_REWRITE_BACKEND": "openai-compatible",
            "WATERMARKS_REWRITE_MODEL": "qwen2.5-1.5b-instruct",
            "WATERMARKS_REWRITE_BASE_URL": "http://127.0.0.1:11434",
            "WATERMARKS_REWRITE_API_KEY": "local-watermarks",
            "WATERMARKS_REWRITE_REASONING_EFFORT": "off",
            "WATERMARKS_CLEAN_STRATEGY_FILE": str(
                REPO_ROOT / "config" / "clean_strategy.codex-cloud.json"
            ),
        }
    )
    test_port = validation_port()
    log_path = REPO_ROOT / ".codex-cloud" / "run" / "validation-service.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            [
                sys.executable,
                str(SERVICE_SCRIPTS / "server.py"),
                "--host",
                "127.0.0.1",
                "--port",
                str(test_port),
            ],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            validation_url = f"http://127.0.0.1:{test_port}"
            wait_ready(validation_url + "/health", process)
            result = http_json(
                validation_url + "/clean",
                {
                    "file": base64.b64encode(fixture.encode()).decode(),
                    "name": "controlled-keyed-gumbel.txt",
                    "options": {
                        "strategy": "paraphrase@1",
                        "detect_before": True,
                        "detect_after": True,
                        "also_layer_a_text": True,
                    },
                },
            )
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    reports = result["report"]["text_detectors"]
    before = find_detector(reports["before"], "gumbel")
    after = find_detector(reports["after"], "gumbel")
    rewritten = base64.b64decode(result["cleaned"]).decode()
    statistical_ok = bool(
        before.get("is_watermarked")
        and not after.get("is_watermarked")
        and _lexical_divergence(fixture, rewritten) >= 0.05
        and result["report"]["layer_b"].get("mode") == "strategy"
    )
    if not statistical_ok:
        raise RuntimeError("statistical before/after validation did not clear the controlled mark")

    skills = {
        name: (REPO_ROOT / ".agents" / "skills" / name / "SKILL.md").is_file()
        for name in ("clean-user-facing-text", "remove-ai-marks")
    }
    if not all(skills.values()):
        raise RuntimeError("one or more project skills are inaccessible")

    report = {
        "ok": True,
        "service": health,
        "skills": skills,
        "codex_catalog": validate_codex_catalog(),
        "capabilities": capabilities,
        "clean_user_facing_text": validate_clean_user_facing_text(),
        "statistical_validation": {
            "ok": statistical_ok,
            "scheme": "keyed-Gumbel (Aaronson EXP), controlled same-key replay",
            "tokens": before.get("tokens_total"),
            "counted": before.get("counted"),
            "before": {
                "is_watermarked": before.get("is_watermarked"),
                "p_value": before.get("p_value"),
                "score": before.get("score"),
            },
            "after": {
                "is_watermarked": after.get("is_watermarked"),
                "p_value": after.get("p_value"),
                "score": after.get("score"),
            },
            "lexical_divergence": round(_lexical_divergence(fixture, rewritten), 4),
            "layer_b": result["report"]["layer_b"],
            "limitation": (
                "Research same-key validation only; it does not prove removal of "
                "SynthID, Claude, or any unknown vendor watermark."
            ),
        },
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
