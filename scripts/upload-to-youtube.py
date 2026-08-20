#!/usr/bin/env python3
"""Upload iPhone-batch MP4s to YouTube using sidecar JSON metadata.

Requires a one-time Google Cloud OAuth Desktop client (free):
  1. https://console.cloud.google.com/ → create/select a project
  2. Enable \"YouTube Data API v3\"
  3. OAuth consent screen → External → add your Google account as test user
  4. Credentials → Create OAuth client ID → Desktop app → Download JSON
  5. Save the file as: ~/.config/camcorder-ingest/client_secret.json

First run opens a browser to authorize; token is saved locally (never commit it).

Quota note: default YouTube API quota allows roughly ~6 uploads/day.
This script skips already-uploaded clips (resume-friendly).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Full youtube scope covers upload + playlists ("folders")
SCOPES = ["https://www.googleapis.com/auth/youtube"]
CONFIG_DIR = Path.home() / ".config" / "camcorder-ingest"
DEFAULT_CLIENT = CONFIG_DIR / "client_secret.json"
DEFAULT_TOKEN = CONFIG_DIR / "yt_token.json"
STEM_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]{0,120}$")


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def ensure_deps() -> None:
    try:
        import googleapiclient.discovery  # noqa: F401
        import google_auth_oauthlib.flow  # noqa: F401
        import google.auth.transport.requests  # noqa: F401
    except ImportError:
        die(
            "Missing YouTube libraries. Install with:\n"
            "  python3 -m pip install --user google-api-python-client "
            "google-auth-oauthlib google-auth-httplib2"
        )


def get_youtube(client_secret: Path, token_path: Path):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    if not client_secret.is_file():
        die(
            f"OAuth client file not found:\n  {client_secret}\n\n"
            "Create a Desktop OAuth client in Google Cloud Console and save the\n"
            "downloaded JSON there. See --help for the setup steps."
        )

    creds = None
    if token_path.is_file():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)
        # Force re-consent if saved token is missing playlist-capable scope
        have = set(creds.scopes or [])
        need = set(SCOPES)
        if not need.issubset(have) and "https://www.googleapis.com/auth/youtube" not in have:
            creds = None

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except Exception:
                creds = None
        if not creds or not creds.valid:
            flow = InstalledAppFlow.from_client_secrets_file(str(client_secret), SCOPES)
            # Local server flow opens the browser for Google login
            creds = flow.run_local_server(port=0, prompt="consent")
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(creds.to_json(), encoding="utf-8")
        token_path.chmod(0o600)

    return build("youtube", "v3", credentials=creds)


def clip_year(meta: dict) -> str:
    creation = (meta.get("creation_time") or "").strip()
    if creation:
        try:
            cleaned = creation.replace("Z", "+00:00")
            return str(datetime.fromisoformat(cleaned).year)
        except ValueError:
            pass
    m = re.search(r"(19|20)\d{2}", creation)
    if m:
        return m.group(0)
    return "Unknown"


def playlist_title_for_year(year: str, prefix: str) -> str:
    prefix = (prefix or "Camcorder").strip() or "Camcorder"
    return f"{prefix} {year}"


def list_own_playlists(youtube) -> dict[str, str]:
    """Return {title: playlistId} for the authorized channel."""
    found: dict[str, str] = {}
    token = None
    while True:
        resp = (
            youtube.playlists()
            .list(part="snippet", mine=True, maxResults=50, pageToken=token)
            .execute()
        )
        for item in resp.get("items", []):
            title = item["snippet"]["title"]
            found[title] = item["id"]
        token = resp.get("nextPageToken")
        if not token:
            break
    return found


def get_or_create_year_playlist(
    youtube,
    year: str,
    prefix: str,
    privacy: str,
    cache: dict[str, str],
) -> str:
    title = playlist_title_for_year(year, prefix)
    if title in cache:
        return cache[title]
    # Create
    body = {
        "snippet": {
            "title": title,
            "description": f"Family camcorder clips from {year}.",
        },
        "status": {"privacyStatus": privacy},
    }
    resp = youtube.playlists().insert(part="snippet,status", body=body).execute()
    pid = resp["id"]
    cache[title] = pid
    print(f"    created playlist  {title!r}  ({pid})")
    return pid


def add_video_to_playlist(youtube, playlist_id: str, video_id: str) -> None:
    youtube.playlistItems().insert(
        part="snippet",
        body={
            "snippet": {
                "playlistId": playlist_id,
                "resourceId": {"kind": "youtube#video", "videoId": video_id},
            }
        },
    ).execute()


def load_log(path: Path) -> dict:
    if not path.is_file():
        return {"uploaded": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"uploaded": {}}
    data.setdefault("uploaded", {})
    return data


def save_log(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def list_clips(batch: Path) -> list[dict]:
    clips = []
    for jp in sorted(batch.glob("*.json")):
        if jp.name.startswith("metadata") or jp.name.startswith("youtube"):
            continue
        stem = jp.stem
        if not STEM_RE.match(stem):
            continue
        mp4 = batch / f"{stem}.mp4"
        if not mp4.is_file():
            continue
        meta = json.loads(jp.read_text(encoding="utf-8"))
        clips.append({"id": stem, "mp4": mp4, "json": jp, "meta": meta})
    return clips


def build_body(meta: dict, privacy: str, category_id: str) -> dict:
    title = (meta.get("title") or "").strip()
    desc = (meta.get("description") or "").strip()
    # If title was left as CLIP-DDMMYYYY, prefer description for YouTube
    if not title or re.fullmatch(r"\d{5}-\d{8}", title):
        title = (desc[:100] if desc else "") or title or "Untitled camcorder clip"
    title = title[:100]
    desc_parts = []
    if desc:
        desc_parts.append(desc)
    if (meta.get("location_name") or "").strip():
        desc_parts.append(f"Location: {meta['location_name'].strip()}")
    if (meta.get("creation_time") or "").strip():
        desc_parts.append(f"Recorded: {meta['creation_time'].strip()}")
    if (meta.get("notes") or "").strip():
        desc_parts.append(f"Notes: {meta['notes'].strip()}")
    description = "\n\n".join(desc_parts)[:4900]

    tags = []
    loc = (meta.get("location_name") or "").strip()
    if loc:
        tags.append(loc[:30])
    tags.extend(["family", "camcorder", "home video"])

    body: dict = {
        "snippet": {
            "title": title,
            "description": description,
            "tags": tags[:10],
            "categoryId": category_id,
        },
        "status": {
            "privacyStatus": privacy,
            "selfDeclaredMadeForKids": False,
        },
    }

    # Optional recording date (YouTube accepts RFC 3339)
    creation = (meta.get("creation_time") or "").strip()
    if creation:
        try:
            cleaned = creation.replace("Z", "+00:00")
            dt = datetime.fromisoformat(cleaned)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            body["recordingDetails"] = {
                "recordingDate": dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
            }
        except ValueError:
            pass

    lat = (meta.get("latitude") or "").strip()
    lon = (meta.get("longitude") or "").strip()
    if lat and lon:
        try:
            body["recordingDetails"] = body.get("recordingDetails") or {}
            body["recordingDetails"]["location"] = {
                "latitude": float(lat),
                "longitude": float(lon),
            }
        except ValueError:
            pass

    return body


def upload_one(youtube, clip: dict, privacy: str, category_id: str) -> dict:
    from googleapiclient.http import MediaFileUpload

    body = build_body(clip["meta"], privacy, category_id)
    media = MediaFileUpload(
        str(clip["mp4"]),
        mimetype="video/mp4",
        resumable=True,
        chunksize=8 * 1024 * 1024,
    )
    request = youtube.videos().insert(
        part=",".join(body.keys()),
        body=body,
        media_body=media,
    )

    response = None
    last_progress = -1
    while response is None:
        status, response = request.next_chunk()
        if status:
            pct = int(status.progress() * 100)
            if pct != last_progress and pct % 5 == 0:
                print(f"    … {pct}%", flush=True)
                last_progress = pct
    return response


def main() -> None:
    ensure_deps()

    parser = argparse.ArgumentParser(
        description="Upload camcorder iPhone-batch MP4s to YouTube",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dir",
        required=True,
        help="iPhone batch folder containing .mp4 + .json sidecars",
    )
    parser.add_argument(
        "--privacy",
        choices=("private", "unlisted", "public"),
        default="private",
        help="YouTube privacy (default: private)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Upload at most N new clips this run (0 = all remaining)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would be uploaded; do not upload",
    )
    parser.add_argument(
        "--client-secret",
        default=str(DEFAULT_CLIENT),
        help=f"OAuth client JSON (default: {DEFAULT_CLIENT})",
    )
    parser.add_argument(
        "--token",
        default=str(DEFAULT_TOKEN),
        help=f"Saved OAuth token path (default: {DEFAULT_TOKEN})",
    )
    parser.add_argument(
        "--category-id",
        default="22",
        help="YouTube category ID (22 = People & Blogs)",
    )
    parser.add_argument(
        "--only",
        default="",
        help="Comma-separated clip stems/prefixes to upload (e.g. 00011,00014)",
    )
    parser.add_argument(
        "--playlist-prefix",
        default="Camcorder",
        help='Year playlist name prefix (default: "Camcorder" → "Camcorder 2016")',
    )
    parser.add_argument(
        "--no-playlists",
        action="store_true",
        help="Do not create/add to year playlists",
    )
    parser.add_argument(
        "--create-playlists-only",
        action="store_true",
        help="Only create missing year playlists from batch dates (no uploads)",
    )
    args = parser.parse_args()

    batch = Path(args.dir).expanduser().resolve()
    if not batch.is_dir():
        die(f"Batch folder not found: {batch}")

    clips = list_clips(batch)
    if not clips:
        die(f"No .mp4+.json pairs in {batch}")

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    if only:
        clips = [
            c
            for c in clips
            if c["id"] in only or any(c["id"].startswith(p) for p in only)
        ]
        if not clips:
            die("No clips matched --only filter")

    log_path = batch / "youtube-upload-log.json"
    log = load_log(log_path)
    uploaded = log["uploaded"]

    pending = [c for c in clips if c["id"] not in uploaded]
    years = sorted({clip_year(c["meta"]) for c in clips})
    print(f"Batch:    {batch}")
    print(f"Clips:    {len(clips)} total, {len(uploaded)} already uploaded, {len(pending)} pending")
    print(f"Privacy:  {args.privacy}")
    print(f"Years:    {', '.join(years)}")
    if not args.no_playlists:
        print(f"Folders:  playlists named \"{args.playlist_prefix} YYYY\"")
    if args.limit > 0:
        pending = pending[: args.limit]
        print(f"Limit:    {args.limit} this run")
    print()

    if args.dry_run:
        targets = clips if args.create_playlists_only else pending
        if not args.create_playlists_only and not pending:
            print("Nothing pending to upload.")
            return
        for c in targets:
            title = (c["meta"].get("title") or c["id"]).strip()
            year = clip_year(c["meta"])
            pl = playlist_title_for_year(year, args.playlist_prefix)
            if args.create_playlists_only:
                print(f"  would ensure playlist  {pl!r}  (from {c['id']})")
            else:
                print(f"  would upload  {c['id']}.mp4  →  {title!r}  [{pl}]")
        # unique playlists only summary
        uniq = sorted({playlist_title_for_year(clip_year(c["meta"]), args.playlist_prefix) for c in targets})
        print(f"\nYear playlists involved: {', '.join(uniq)}")
        print("Dry run only. Re-run without --dry-run to apply.")
        return

    client_secret = Path(args.client_secret).expanduser()
    token_path = Path(args.token).expanduser()
    youtube = get_youtube(client_secret, token_path)

    playlist_cache = list_own_playlists(youtube) if not args.no_playlists else {}

    if args.create_playlists_only:
        ensured = []
        for year in years:
            title = playlist_title_for_year(year, args.playlist_prefix)
            existed = title in playlist_cache
            get_or_create_year_playlist(
                youtube, year, args.playlist_prefix, args.privacy, playlist_cache
            )
            ensured.append(title + ("" if existed else " (new)"))
        print("Done. Year playlists ready:")
        for name in ensured:
            print(f"  • {name}")
        return

    if not pending:
        print("Nothing to upload — all selected clips are already in the log.")
        return

    ok = 0
    failed = 0
    for i, clip in enumerate(pending, 1):
        title = (clip["meta"].get("title") or clip["id"]).strip()
        year = clip_year(clip["meta"])
        size_mb = clip["mp4"].stat().st_size / (1024 * 1024)
        pl_name = playlist_title_for_year(year, args.playlist_prefix)
        print(f"[{i}/{len(pending)}] {clip['id']}  ({size_mb:.1f} MB)  {title!r}  → {pl_name}")
        try:
            resp = upload_one(youtube, clip, args.privacy, args.category_id)
            video_id = resp.get("id", "")
            url = f"https://youtu.be/{video_id}" if video_id else ""
            playlist_id = ""
            if video_id and not args.no_playlists:
                playlist_id = get_or_create_year_playlist(
                    youtube, year, args.playlist_prefix, args.privacy, playlist_cache
                )
                add_video_to_playlist(youtube, playlist_id, video_id)
                print(f"    added to playlist  {pl_name}")
            uploaded[clip["id"]] = {
                "video_id": video_id,
                "url": url,
                "title": title,
                "privacy": args.privacy,
                "year": year,
                "playlist": pl_name,
                "playlist_id": playlist_id,
                "uploaded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "file": clip["mp4"].name,
            }
            log["uploaded"] = uploaded
            save_log(log_path, log)
            print(f"    OK  {url}")
            ok += 1
            # gentle pacing between uploads
            time.sleep(1)
        except Exception as e:
            failed += 1
            err = str(e)
            print(f"    FAILED: {err}", file=sys.stderr)
            if "quotaExceeded" in err or "dailyLimitExceeded" in err or "uploadLimitExceeded" in err:
                print(
                    "\nYouTube daily upload limit reached. Re-run tomorrow — "
                    "already-uploaded clips will be skipped automatically.",
                    file=sys.stderr,
                )
                break

    print()
    print(f"Done. Uploaded={ok}  Failed={failed}  Log={log_path}")
    if ok:
        print("Videos are on your channel in year playlists (YouTube Studio → Playlists).")


if __name__ == "__main__":
    main()
