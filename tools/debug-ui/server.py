#!/usr/bin/env python3
"""
qingsheng debug UI backend — stdlib only, no pip install.

Serves a single-page web UI for interactively testing the qingsheng skill:
- scenarios are stored as JSON files in cases/ with associated images
- hitting "Run" shells out to `claude -p --append-system-prompt <SKILL.md>`
- left/right split lets you compare two skill versions on the same scenario
- marking a run as "standard answer" saves it as the gold answer for that case

No API key required — uses `claude -p` headless mode which rides on the user's
existing Claude Code OAuth session.

Usage:
    python3 server.py                       # default port 8765
    python3 server.py --port 8900
    python3 server.py --skill /path/to/SKILL.md   # default left-side skill
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# ---- paths ----
HERE = Path(__file__).resolve().parent
CASES_DIR = HERE / "cases"
STATIC_DIR = HERE / "static"
# repo root is two levels up from tools/debug-ui/
REPO_ROOT = HERE.parent.parent
DEFAULT_SKILL = REPO_ROOT / "skill" / "SKILL.md"

CASES_DIR.mkdir(parents=True, exist_ok=True)
STATIC_DIR.mkdir(parents=True, exist_ok=True)

# ---- helpers ----

def _now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _slug(s: str) -> str:
    s = re.sub(r"[^\w\-一-龥]+", "-", (s or "").strip())
    s = s.strip("-").lower()
    return s[:60] or "case"


def _case_file(case_id: str) -> Path:
    return CASES_DIR / f"{case_id}.json"


def _case_dir(case_id: str) -> Path:
    return CASES_DIR / case_id


def _load_case(case_id: str) -> dict | None:
    p = _case_file(case_id)
    if not p.exists():
        return None
    return json.loads(p.read_text())


def _save_case(case: dict) -> None:
    cid = case["id"]
    _case_file(cid).write_text(json.dumps(case, ensure_ascii=False, indent=2))


def _list_cases() -> list[dict]:
    out = []
    for f in sorted(CASES_DIR.glob("*.json")):
        try:
            c = json.loads(f.read_text())
        except Exception:
            continue
        out.append({
            "id": c["id"],
            "name": c.get("name", c["id"]),
            "created_at": c.get("created_at"),
            "updated_at": c.get("updated_at"),
            "has_gold": bool(c.get("gold_answer")),
            "run_count": len(c.get("runs", [])),
            "image_count": len(c.get("scenario", {}).get("images", [])),
            "platform": c.get("scenario", {}).get("metadata", {}).get("platform", ""),
            "target": c.get("scenario", {}).get("metadata", {}).get("target_name", ""),
        })
    return sorted(out, key=lambda x: x.get("updated_at") or x.get("created_at") or "", reverse=True)


def _save_image(case_id: str, filename: str, data_url: str) -> str:
    """Decode a data URL and save it under cases/<id>/. Returns the filename."""
    m = re.match(r"data:([^;]+);base64,(.+)$", data_url, re.DOTALL)
    if not m:
        raise ValueError("invalid data URL")
    mime = m.group(1)
    raw = base64.b64decode(m.group(2))
    ext = {"image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
           "image/webp": ".webp", "image/gif": ".gif"}.get(mime, ".bin")
    d = _case_dir(case_id)
    d.mkdir(parents=True, exist_ok=True)
    base = _slug(Path(filename).stem) or uuid.uuid4().hex[:8]
    name = f"{base}{ext}"
    i = 0
    while (d / name).exists():
        i += 1
        name = f"{base}-{i}{ext}"
    (d / name).write_bytes(raw)
    return name


# ---- claude runner ----

def _build_user_prompt(case: dict) -> str:
    """Build the user-side prompt from a case. Screenshots are referenced by
    absolute path so the model can Read them via its Read tool."""
    sc = case.get("scenario", {})
    meta = sc.get("metadata", {}) or {}
    text = (sc.get("text") or "").strip()
    images = sc.get("images") or []
    case_id = case["id"]

    parts = []
    # Metadata hints (don't force them — user may have left blank)
    hints = []
    if meta.get("platform"):
        hints.append(f"平台：{meta['platform']}")
    if meta.get("target_name"):
        hints.append(f"对方：{meta['target_name']}")
    if meta.get("relationship"):
        hints.append(f"关系背景：{meta['relationship']}")
    if meta.get("how_they_met"):
        hints.append(f"怎么认识的：{meta['how_they_met']}")
    if hints:
        parts.append("【用户提供的背景】\n" + "\n".join(hints))

    if text:
        parts.append("【用户的问题】\n" + text)

    if images:
        img_paths = [str((_case_dir(case_id) / n).resolve()) for n in images]
        lines = ["【用户上传的截图】（请先用 Read 工具逐张读取）"]
        for p in img_paths:
            lines.append(p)
        parts.append("\n".join(lines))

    if not parts:
        parts.append("（用户没有提供具体描述，请按 skill 的规则开始。）")

    return "\n\n".join(parts)


def run_claude(skill_path: str, case: dict, model: str = "sonnet",
               max_turns: int = 8, timeout: int = 300) -> dict:
    """Execute `claude -p` with the given SKILL.md as appended system prompt
    and the case scenario as the user prompt. Returns a run record."""
    skill_p = Path(skill_path).expanduser().resolve()
    if not skill_p.exists():
        return {"error": f"skill file not found: {skill_p}"}

    skill_content = skill_p.read_text()
    skill_dir = skill_p.parent
    user_prompt = _build_user_prompt(case)

    # allow access to the skill dir (for references/) and the case image dir
    add_dirs = [str(skill_dir)]
    img_dir = _case_dir(case["id"])
    if img_dir.exists():
        add_dirs.append(str(img_dir.resolve()))

    cmd = [
        "claude", "-p",
        "--no-session-persistence",
        "--model", model,
        "--append-system-prompt", skill_content,
        "--output-format", "json",
        "--max-turns", str(max_turns),
    ]
    for d in add_dirs:
        cmd += ["--add-dir", d]
    cmd += ["--", user_prompt]

    started = time.time()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(skill_dir),          # so `references/foo.md` resolves
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {
            "error": f"claude -p timed out after {timeout}s",
            "duration_s": round(time.time() - started, 1),
        }
    duration = round(time.time() - started, 1)

    if proc.returncode != 0:
        return {
            "error": f"claude exited {proc.returncode}",
            "stderr": proc.stderr[-2000:],
            "duration_s": duration,
        }

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {
            "error": "claude returned non-JSON",
            "raw_stdout": proc.stdout[-2000:],
            "stderr": proc.stderr[-2000:],
            "duration_s": duration,
        }

    return {
        "output": payload.get("result", ""),
        "is_error": bool(payload.get("is_error")),
        "duration_s": duration,
        "skill_path": str(skill_p),
        "skill_mtime": skill_p.stat().st_mtime,
        "model": model,
        "timestamp": _now_iso(),
    }


# ---- HTTP handler ----

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "qingsheng-debug/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{datetime.now().strftime('%H:%M:%S')}] {fmt % args}\n")

    # ---- helpers ----
    def _send_json(self, code: int, body):
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _send_file(self, path: Path, status=200):
        if not path.exists() or not path.is_file():
            return self._send_json(404, {"error": "not found", "path": str(path)})
        data = path.read_bytes()
        self.send_response(status)
        self.send_header("Content-Type",
                         CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n == 0:
            return {}
        raw = self.rfile.read(n)
        return json.loads(raw.decode("utf-8"))

    # ---- routing ----
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path

        # static + root
        if path == "/" or path == "/index.html":
            return self._send_file(STATIC_DIR / "index.html")
        if path.startswith("/static/"):
            return self._send_file(STATIC_DIR / path[len("/static/"):])

        # API
        if path == "/api/cases":
            return self._send_json(200, {"cases": _list_cases()})

        m = re.match(r"^/api/cases/([^/]+)$", path)
        if m:
            c = _load_case(m.group(1))
            if not c:
                return self._send_json(404, {"error": "case not found"})
            return self._send_json(200, c)

        m = re.match(r"^/api/cases/([^/]+)/images/(.+)$", path)
        if m:
            cid, fname = m.group(1), m.group(2)
            return self._send_file(_case_dir(cid) / fname)

        if path == "/api/default-skill":
            return self._send_json(200, {"path": str(DEFAULT_SKILL)})

        return self._send_json(404, {"error": "not found", "path": path})

    def do_POST(self):
        url = urlparse(self.path)
        path = url.path

        try:
            body = self._read_json()
        except Exception as e:
            return self._send_json(400, {"error": f"bad json: {e}"})

        # create/update case
        if path == "/api/cases":
            name = (body.get("name") or "").strip() or "untitled"
            cid = body.get("id") or f"{_slug(name)}-{uuid.uuid4().hex[:6]}"
            existing = _load_case(cid) or {}

            # Persist images (from data URLs) to disk
            image_filenames = list(existing.get("scenario", {}).get("images") or [])
            for img in body.get("scenario", {}).get("new_images", []) or []:
                fn = img.get("filename") or "image.png"
                du = img.get("data_url") or ""
                try:
                    saved = _save_image(cid, fn, du)
                    image_filenames.append(saved)
                except Exception as e:
                    return self._send_json(400, {"error": f"image save failed: {e}"})

            scenario_in = body.get("scenario", {}) or {}
            case = {
                "id": cid,
                "name": name,
                "created_at": existing.get("created_at") or _now_iso(),
                "updated_at": _now_iso(),
                "scenario": {
                    "text": scenario_in.get("text", existing.get("scenario", {}).get("text", "")),
                    "images": image_filenames,
                    "metadata": scenario_in.get("metadata",
                                                existing.get("scenario", {}).get("metadata", {})),
                },
                "gold_answer": existing.get("gold_answer"),
                "runs": existing.get("runs", []),
            }
            _save_case(case)
            return self._send_json(200, case)

        # delete images from a case (by filename)
        m = re.match(r"^/api/cases/([^/]+)/delete-image$", path)
        if m:
            cid = m.group(1)
            c = _load_case(cid)
            if not c:
                return self._send_json(404, {"error": "case not found"})
            fname = body.get("filename")
            imgs = c.get("scenario", {}).get("images", [])
            if fname in imgs:
                imgs.remove(fname)
                try:
                    (_case_dir(cid) / fname).unlink(missing_ok=True)
                except Exception:
                    pass
            c["scenario"]["images"] = imgs
            c["updated_at"] = _now_iso()
            _save_case(c)
            return self._send_json(200, c)

        # run skill on case
        if path == "/api/run":
            case_id = body.get("case_id")
            skill_path = body.get("skill_path") or str(DEFAULT_SKILL)
            model = body.get("model") or "sonnet"
            side = body.get("side") or "left"  # just for UI labeling in the run record
            max_turns = int(body.get("max_turns") or 8)

            c = _load_case(case_id)
            if not c:
                return self._send_json(404, {"error": "case not found"})

            result = run_claude(skill_path, c, model=model, max_turns=max_turns)
            run_rec = {
                "side": side,
                **result,
            }
            c.setdefault("runs", []).append(run_rec)
            c["updated_at"] = _now_iso()
            _save_case(c)
            return self._send_json(200, {"case": c, "run": run_rec})

        # mark a specific run index as gold answer
        m = re.match(r"^/api/cases/([^/]+)/gold$", path)
        if m:
            cid = m.group(1)
            c = _load_case(cid)
            if not c:
                return self._send_json(404, {"error": "case not found"})
            run_idx = body.get("run_index")
            note = body.get("note") or ""
            runs = c.get("runs") or []
            if run_idx is None or not (0 <= run_idx < len(runs)):
                return self._send_json(400, {"error": "invalid run_index"})
            run = runs[run_idx]
            c["gold_answer"] = {
                "text": run.get("output", ""),
                "marked_at": _now_iso(),
                "source_run_index": run_idx,
                "skill_path": run.get("skill_path"),
                "skill_mtime": run.get("skill_mtime"),
                "note": note,
            }
            c["updated_at"] = _now_iso()
            _save_case(c)
            return self._send_json(200, c)

        # attach user feedback to a specific run
        m = re.match(r"^/api/cases/([^/]+)/feedback$", path)
        if m:
            cid = m.group(1)
            c = _load_case(cid)
            if not c:
                return self._send_json(404, {"error": "case not found"})
            run_idx = body.get("run_index")
            feedback = body.get("feedback") or ""
            tags = body.get("tags") or []
            runs = c.get("runs") or []
            if run_idx is None or not (0 <= run_idx < len(runs)):
                return self._send_json(400, {"error": "invalid run_index"})
            runs[run_idx]["user_feedback"] = feedback
            runs[run_idx]["feedback_tags"] = tags
            c["updated_at"] = _now_iso()
            _save_case(c)
            return self._send_json(200, c)

        return self._send_json(404, {"error": "not found", "path": path})

    def do_DELETE(self):
        m = re.match(r"^/api/cases/([^/]+)$", self.path)
        if m:
            cid = m.group(1)
            f = _case_file(cid)
            d = _case_dir(cid)
            if f.exists():
                f.unlink()
            if d.exists():
                shutil.rmtree(d, ignore_errors=True)
            return self._send_json(200, {"ok": True})
        return self._send_json(404, {"error": "not found"})


def main():
    global DEFAULT_SKILL
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--skill", default=str(DEFAULT_SKILL),
                    help="default SKILL.md path used by the UI")
    args = ap.parse_args()
    DEFAULT_SKILL = Path(args.skill).expanduser().resolve()

    if not shutil.which("claude"):
        sys.stderr.write("WARNING: `claude` CLI not found in PATH — /api/run will fail\n")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f">>> qingsheng debug UI running at {url}")
    print(f">>> cases dir: {CASES_DIR}")
    print(f">>> default skill: {DEFAULT_SKILL}")
    print(">>> Ctrl+C to stop")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n>>> shutting down")


if __name__ == "__main__":
    main()
