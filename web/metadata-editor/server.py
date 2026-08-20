#!/usr/bin/env python3
"""Lightweight local web UI to review clip thumbnails and edit metadata.

Uses only the Python standard library + ffmpeg/ffprobe on PATH.
Does not re-encode video — remuxes metadata tags into the MP4 and updates JSON sidecars.
"""

from __future__ import annotations

import argparse
import csv
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
META_KEYS = [
    "source_file",
    "output_file",
    "creation_time",
    "title",
    "description",
    "location_name",
    "latitude",
    "longitude",
    "iso6709",
    "source_fps",
    "output_fps",
    "notes",
]
STEM_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]{0,120}$")
EDITABLE = {
    "title",
    "description",
    "location_name",
    "latitude",
    "longitude",
    "creation_time",
    "notes",
}

# Set in main()
BATCH_DIR: Path = Path()
IPHONE_ROOT: Path = Path()
THUMB_DIR: Path = Path()
STATE_LOCK = threading.Lock()


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def iso6709(lat: str, lon: str) -> str:
    if not lat.strip() or not lon.strip():
        return ""
    try:
        la = float(lat)
        lo = float(lon)
    except ValueError:
        return ""
    def fmt(v: float, pos: str, neg: str) -> str:
        sign = pos if v >= 0 else neg
        return f"{sign}{abs(v):.4f}"
    return f"{fmt(la, '+', '-')}{fmt(lo, '+', '-')}/"


def date_suffix(iso: str) -> str:
    if not iso:
        return datetime.now(timezone.utc).strftime("%d%m%Y")
    try:
        # accept Z or offset
        cleaned = iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(cleaned)
        return dt.strftime("%d%m%Y")
    except ValueError:
        return datetime.now(timezone.utc).strftime("%d%m%Y")


def parse_ddmmyyyy(value: str, fallback: str) -> str:
    value = (value or "").strip()
    if not value:
        return fallback
    try:
        dt = datetime.strptime(value, "%d%m%Y")
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return fallback


def load_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, data: dict) -> None:
    out = {k: str(data.get(k, "") or "") for k in META_KEYS}
    path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def append_fix_log(batch: Path, row: dict) -> None:
    csv_path = batch / "metadata-fixes.csv"
    write_header = not csv_path.is_file()
    with csv_path.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=META_KEYS, extrasaction="ignore")
        if write_header:
            w.writeheader()
        w.writerow({k: row.get(k, "") for k in META_KEYS})


def flags_for(meta: dict) -> list[str]:
    title = (meta.get("title") or "").strip()
    desc = (meta.get("description") or "").strip()
    loc = (meta.get("location_name") or "").strip()
    low = f"{title} {desc} {loc}".lower()
    flags: list[str] = []
    if re.fullmatch(r"\d{5}-\d{8}", title):
        flags.append("default-title")
    if not desc:
        flags.append("empty-desc")
    if not loc:
        flags.append("empty-loc")
    for needle, label in [
        ("christman", "typo"),
        ("chlesea", "typo"),
        ("jervis bau", "typo"),
        ("sought coogee", "typo"),
        ("allowe", "typo"),
        ("jervis bay act", "act-vs-nsw"),
    ]:
        if needle in low and label not in flags:
            flags.append(label)
    if loc.endswith("NSw") and "typo" not in flags:
        flags.append("typo")
    return flags


def list_batches(iphone_root: Path) -> list[dict]:
    batches = []
    if not iphone_root.is_dir():
        return batches
    for d in sorted(iphone_root.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not d.is_dir():
            continue
        n = len(list(d.glob("*.mp4")))
        if n == 0:
            continue
        batches.append({"id": d.name, "path": str(d), "clips": n})
    return batches


def list_clips(batch: Path) -> list[dict]:
    clips = []
    for jp in sorted(batch.glob("*.json")):
        if jp.name == "metadata-log.csv":
            continue
        stem = jp.stem
        mp4 = batch / f"{stem}.mp4"
        if not mp4.is_file():
            continue
        meta = load_json(jp)
        meta.setdefault("title", stem)
        meta.setdefault("output_file", str(mp4))
        flags = flags_for(meta)
        clips.append(
            {
                "id": stem,
                "file": f"{stem}.mp4",
                "json": jp.name,
                "title": meta.get("title") or stem,
                "description": meta.get("description") or "",
                "location_name": meta.get("location_name") or "",
                "latitude": meta.get("latitude") or "",
                "longitude": meta.get("longitude") or "",
                "creation_time": meta.get("creation_time") or "",
                "notes": meta.get("notes") or "",
                "source_fps": meta.get("source_fps") or "",
                "output_fps": meta.get("output_fps") or "",
                "source_file": meta.get("source_file") or "",
                "iso6709": meta.get("iso6709") or "",
                "flags": flags,
                "needs_attention": bool(
                    set(flags) & {"typo", "empty-desc", "act-vs-nsw"}
                ),
                "size_mb": round(mp4.stat().st_size / (1024 * 1024), 2),
                "mtime": int(mp4.stat().st_mtime),
            }
        )
    return clips


def ensure_thumb(batch: Path, stem: str) -> Path:
    THUMB_DIR.mkdir(parents=True, exist_ok=True)
    out = THUMB_DIR / f"{stem}.jpg"
    if out.is_file() and out.stat().st_size > 0:
        return out
    mp4 = batch / f"{stem}.mp4"
    if not mp4.is_file():
        raise FileNotFoundError(stem)
    # Grab a frame ~1s in (or start if shorter)
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        "1",
        "-i",
        str(mp4),
        "-frames:v",
        "1",
        "-vf",
        "scale=480:-2",
        "-q:v",
        "4",
        str(out),
    ]
    proc = run(cmd, check=False)
    if proc.returncode != 0 or not out.is_file():
        # retry from start
        cmd[cmd.index("-ss") + 1] = "0"
        run(cmd, check=True)
    return out


def apply_metadata_to_mp4(mp4: Path, meta: dict) -> None:
    tmp = mp4.with_suffix(".meta.tmp.mp4")
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(mp4),
        "-map",
        "0",
        "-c",
        "copy",
        "-movflags",
        "+faststart+use_metadata_tags",
        "-metadata",
        f"creation_time={meta.get('creation_time', '')}",
        "-metadata",
        f"title={meta.get('title', '')}",
        "-metadata",
        f"date={meta.get('creation_time', '')}",
    ]
    desc = meta.get("description") or ""
    loc = meta.get("location_name") or ""
    iso = meta.get("iso6709") or ""
    if desc:
        cmd += ["-metadata", f"description={desc}", "-metadata", f"comment={desc}"]
    if loc:
        cmd += ["-metadata", f"location={loc}"]
    if iso:
        cmd += [
            "-metadata",
            f"com.apple.quicktime.location.ISO6709={iso}",
            "-metadata",
            f"location-eng={iso}",
        ]
    cmd.append(str(tmp))
    try:
        run(cmd, check=True)
        os.replace(tmp, mp4)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

    # Match filesystem date to creation_time when possible
    creation = meta.get("creation_time") or ""
    try:
        cleaned = creation.replace("Z", "+00:00")
        dt = datetime.fromisoformat(cleaned)
        ts = dt.timestamp()
        os.utime(mp4, (ts, ts))
    except Exception:
        pass


def save_clip(batch: Path, stem: str, updates: dict) -> dict:
    if not STEM_RE.match(stem):
        raise ValueError("invalid clip id")
    jp = batch / f"{stem}.json"
    mp4 = batch / f"{stem}.mp4"
    if not jp.is_file() or not mp4.is_file():
        raise FileNotFoundError(stem)

    with STATE_LOCK:
        meta = load_json(jp)
        for k in EDITABLE:
            if k in updates:
                meta[k] = str(updates[k] if updates[k] is not None else "")
        # Allow DDMMYYYY shorthand for creation_time
        ct = meta.get("creation_time") or ""
        if re.fullmatch(r"\d{8}", ct.strip()):
            meta["creation_time"] = parse_ddmmyyyy(ct.strip(), meta.get("creation_time") or "")
        meta["iso6709"] = iso6709(meta.get("latitude", ""), meta.get("longitude", ""))
        meta["output_file"] = str(mp4)

        write_json(jp, meta)
        apply_metadata_to_mp4(mp4, meta)

        # Refresh date-based filename if it was CLIP-DDMMYYYY
        clip_id = stem.split("-", 1)[0]
        new_base = f"{clip_id}-{date_suffix(meta.get('creation_time', ''))}"
        if re.fullmatch(r"\d{5}-\d{8}", stem) and new_base != stem:
            new_mp4 = batch / f"{new_base}.mp4"
            new_json = batch / f"{new_base}.json"
            if not new_mp4.exists():
                mp4.rename(new_mp4)
                jp.rename(new_json)
                # move thumb cache if present
                old_thumb = THUMB_DIR / f"{stem}.jpg"
                new_thumb = THUMB_DIR / f"{new_base}.jpg"
                if old_thumb.is_file():
                    old_thumb.rename(new_thumb)
                stem = new_base
                mp4 = new_mp4
                jp = new_json
                meta["output_file"] = str(mp4)
                write_json(jp, meta)

        append_fix_log(batch, meta)

    # Return fresh list item
    for c in list_clips(batch):
        if c["id"] == stem:
            return c
    raise RuntimeError("saved but clip missing from listing")


class Handler(BaseHTTPRequestHandler):
    server_version = "CamcorderMetaEditor/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: bytes, content_type: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send(code, data, "application/json; charset=utf-8")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            self._serve_static("index.html")
            return
        if path.startswith("/static/"):
            self._serve_static(path[len("/static/") :])
            return

        if path == "/api/health":
            self._json(200, {"ok": True, "batch": str(BATCH_DIR), "clips": len(list_clips(BATCH_DIR))})
            return

        if path == "/api/batches":
            self._json(200, {"batches": list_batches(IPHONE_ROOT), "current": BATCH_DIR.name})
            return

        if path == "/api/clips":
            self._json(
                200,
                {
                    "batch": BATCH_DIR.name,
                    "path": str(BATCH_DIR),
                    "clips": list_clips(BATCH_DIR),
                },
            )
            return

        if path.startswith("/api/thumb/"):
            stem = path[len("/api/thumb/") :]
            if not STEM_RE.match(stem):
                self._json(400, {"error": "bad id"})
                return
            try:
                thumb = ensure_thumb(BATCH_DIR, stem)
            except Exception as e:
                self._json(404, {"error": str(e)})
                return
            data = thumb.read_bytes()
            self._send(200, data, "image/jpeg", {"Cache-Control": "public, max-age=86400"})
            return

        if path.startswith("/api/video/"):
            stem = path[len("/api/video/") :]
            if not STEM_RE.match(stem):
                self._json(400, {"error": "bad id"})
                return
            mp4 = BATCH_DIR / f"{stem}.mp4"
            if not mp4.is_file():
                self._json(404, {"error": "missing"})
                return
            self._serve_file_range(mp4, "video/mp4")
            return

        self._json(404, {"error": "not found"})

    def do_PUT(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/clips/"):
            stem = path[len("/api/clips/") :]
            if not STEM_RE.match(stem):
                self._json(400, {"error": "bad id"})
                return
            try:
                body = self._read_json()
                clip = save_clip(BATCH_DIR, stem, body)
                self._json(200, {"ok": True, "clip": clip})
            except FileNotFoundError:
                self._json(404, {"error": "clip not found"})
            except Exception as e:
                self._json(500, {"error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/batch":
            body = self._read_json()
            batch_id = str(body.get("id") or "").strip()
            if not STEM_RE.match(batch_id):
                self._json(400, {"error": "bad batch id"})
                return
            global BATCH_DIR, THUMB_DIR
            candidate = IPHONE_ROOT / batch_id
            if not candidate.is_dir():
                self._json(404, {"error": "batch not found"})
                return
            BATCH_DIR = candidate
            THUMB_DIR = BATCH_DIR / ".thumbs"
            self._json(200, {"ok": True, "batch": BATCH_DIR.name, "clips": len(list_clips(BATCH_DIR))})
            return
        self._json(404, {"error": "not found"})

    def _serve_static(self, rel: str) -> None:
        rel = rel.lstrip("/")
        if ".." in rel or rel.startswith("/"):
            self._json(400, {"error": "bad path"})
            return
        path = STATIC / rel
        if not path.is_file():
            self._json(404, {"error": "missing static"})
            return
        ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self._send(200, path.read_bytes(), ctype)

    def _serve_file_range(self, path: Path, content_type: str) -> None:
        size = path.stat().st_size
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            spec = range_header.split("=", 1)[1]
            start_s, _, end_s = spec.partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size - 1
            end = min(end, size - 1)
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Type", content_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            with path.open("rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with path.open("rb") as f:
            shutil.copyfileobj(f, self.wfile, length=65536)


def resolve_batch(iphone_root: Path, batch_arg: str | None) -> Path:
    if batch_arg:
        p = Path(batch_arg).expanduser().resolve()
        if p.is_dir() and any(p.glob("*.mp4")):
            return p
        # treat as batch name under iPhone root
        cand = iphone_root / batch_arg
        if cand.is_dir():
            return cand
        die(f"Batch not found: {batch_arg}")
    batches = list_batches(iphone_root)
    if not batches:
        die(f"No iPhone batches with .mp4 under {iphone_root}")
    return Path(batches[0]["path"])


def main() -> None:
    global BATCH_DIR, IPHONE_ROOT, THUMB_DIR

    parser = argparse.ArgumentParser(description="Local thumbnail + metadata editor")
    parser.add_argument(
        "--iphone-root",
        default=str(Path.home() / "Videos" / "CamcorderIngest" / "iPhone"),
        help="Folder containing batch subfolders",
    )
    parser.add_argument(
        "--dir",
        "--batch",
        dest="batch",
        default=None,
        help="Batch folder path or name (default: newest under iPhone root)",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true", help="Open browser after start")
    args = parser.parse_args()

    for bin_name in ("ffmpeg", "ffprobe"):
        if shutil.which(bin_name) is None:
            die(f"{bin_name} not found on PATH")

    IPHONE_ROOT = Path(args.iphone_root).expanduser().resolve()
    BATCH_DIR = resolve_batch(IPHONE_ROOT, args.batch)
    THUMB_DIR = BATCH_DIR / ".thumbs"
    THUMB_DIR.mkdir(parents=True, exist_ok=True)

    if not STATIC.is_dir():
        die(f"Missing static UI at {STATIC}")

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print()
    print("  Camcorder metadata editor")
    print(f"  Batch: {BATCH_DIR}")
    print(f"  Open:  {url}")
    print("  Ctrl+C to stop")
    print()

    if args.open:
        try:
            import webbrowser

            webbrowser.open(url)
        except Exception:
            pass

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        httpd.server_close()


if __name__ == "__main__":
    main()
