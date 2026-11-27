#!/usr/bin/env python3
"""Fetch the latest BakaSU manager APK from a Telegram topic.

The BakaSU team posts the manager APKs in a topic of the @BakaSU_Grp
supergroup. There is no public web preview for that group, so the files can
only be read over MTProto with a user session (Telethon).

Required environment:
    TELEGRAM_API_ID     numeric api id from https://my.telegram.org
    TELEGRAM_API_HASH   api hash from https://my.telegram.org
    TELEGRAM_SESSION    StringSession created with scripts/telegram-login.py

Optional environment:
    APK_CHANNEL         chat to look in          (default: BakaSU_Grp)
    APK_TOPIC           forum topic id           (default: 4)
    APK_ARCH            architecture to match    (default: arm64-v8a)
    APK_LIMIT           messages to scan         (default: 60)
    APK_OUT             output file              (default: releases/<name>.apk)
    APK_META            metadata json            (default: releases/bakasu-apk.json)

Exits 0 even when nothing was found - a missing APK must never break the
kernel build.
"""

import asyncio
import hashlib
import json
import os
import re
import sys

CHANNEL = os.environ.get("APK_CHANNEL", "BakaSU_Grp")
TOPIC = int(os.environ.get("APK_TOPIC", "4") or 0)
ARCH = os.environ.get("APK_ARCH", "arm64-v8a")
LIMIT = int(os.environ.get("APK_LIMIT", "60") or 60)
OUT = os.environ.get("APK_OUT", "")
META = os.environ.get("APK_META", "releases/bakasu-apk.json")


def arch_preferences():
    """Which architectures we accept, best first.

    The channel posts both a per-architecture and a "universal" APK, so the
    wanted architecture wins and "universal" is the fallback.
    """
    want = ARCH.lower()
    prefs = []
    if want != "universal":
        prefs.append(want)
    prefs.append("universal")
    return prefs


def matches_arch(name, pref):
    """True when the file name looks like the given architecture."""
    low = name.lower()
    if pref == "universal":
        return "universal" in low
    if pref in low:
        return True
    # arm64 variants: "arm64", "aarch64"
    if pref.startswith("arm64"):
        return any(a in low for a in ("arm64", "aarch64"))
    if pref.startswith("armeabi"):
        return "armeabi" in low
    if pref in ("x86_64", "amd64"):
        return any(a in low for a in ("x86_64", "amd64", "x64"))
    return False


def sanitize(name):
    name = re.sub(r"[^A-Za-z0-9._+-]+", "_", name.strip())
    return name or "BakaSU.apk"


def normalize_session(raw):
    """Clean up a pasted StringSession.

    The session is one long base64url string. People paste it with quotes,
    with line breaks or together with the "Add this as the secret" header -
    so take the longest base64-looking chunk of it.
    """
    text = raw.strip().strip("\"").strip("'")
    best = ""
    for line in text.splitlines():
        cleaned = re.sub(r"[^A-Za-z0-9_+=/-]", "", line.strip())
        if len(cleaned) > len(best):
            best = cleaned
    return best


def fix_session(session):
    """Bring a StringSession into the canonical format.

    Telethon detects the format by the exact length of the payload
    ("ip_len = 4 if len(string) == 352 else 16"), so a single missing or
    extra character makes it try to unpack 275 bytes out of 263.

    The old format (4 byte ip) is re-encoded as the new one (16 byte ip),
    which is unambiguous.
    """
    import base64
    import struct

    if not session.startswith("1"):
        return session, "does not start with the version character '1'"

    payload = session[1:]
    try:
        raw = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
    except Exception as exc:
        return session, f"is not valid base64 ({exc})"

    if len(raw) == 275:
        return session, "is already in the canonical format"
    if len(raw) == 263:
        # '>B4sH256s' -> '>B16sH256s'
        dc_id = raw[0]
        ip = raw[1:5]
        port = struct.unpack(">H", raw[5:7])[0]
        key = raw[7:]
        packed = struct.pack(">B16sH256s", dc_id, ip.ljust(16, b"\x00"), port, key)
        # Keep the base64 padding - Telethon decodes without adding it.
        fixed = "1" + base64.urlsafe_b64encode(packed).decode()
        return fixed, "was converted to the canonical format"
    return session, (f"decodes to {len(raw)} bytes - expected 263 or 275, "
                     f"so it is truncated or has extra characters")


async def main():
    api_id = os.environ.get("TELEGRAM_API_ID", "")
    api_hash = os.environ.get("TELEGRAM_API_HASH", "")
    session = os.environ.get("TELEGRAM_SESSION", "")

    missing = [n for n, v in (("TELEGRAM_API_ID", api_id),
                              ("TELEGRAM_API_HASH", api_hash),
                              ("TELEGRAM_SESSION", session)) if not v]
    if missing:
        print(f"::warning::Telegram session not configured ({', '.join(missing)}) "
              f"- skipping the BakaSU APK")
        return 0

    try:
        from telethon import TelegramClient
        from telethon.sessions import StringSession
    except ImportError:
        print("::warning::telethon is not installed - skipping the BakaSU APK")
        return 0

    # Download to a temporary name and rename it afterwards, so the release
    # carries the original APK name (with its version in it).
    tmp_out = OUT or "releases/.bakaSU-download.apk"
    os.makedirs(os.path.dirname(tmp_out) or ".", exist_ok=True)

    session = normalize_session(session)
    session, note = fix_session(session)
    print(f"Session: {len(session)} characters, {note}")

    try:
        client = TelegramClient(StringSession(session), int(api_id), api_hash)
    except Exception as exc:
        print(f"::warning::TELEGRAM_SESSION does not look like a Telegram StringSession: {exc}")
        print("::warning::Copy the long base64 string printed by "
              "scripts/telegram-login.py into the secret - not the api_hash, "
              "not the api_id and not the phone number.")
        print(f"::warning::The secret has {len(session)} usable characters "
              "(a session is 353 or 369).")
        return 0

    await client.connect()
    if not await client.is_user_authorized():
        print("::warning::The Telegram session is no longer valid - skipping the BakaSU APK")
        await client.disconnect()
        return 0

    # reply_to= selects a forum topic of a supergroup.
    try:
        messages = await client.get_messages(CHANNEL, limit=LIMIT, reply_to=TOPIC or None)
    except Exception as exc:
        print(f"::warning::Could not read @{CHANNEL} topic {TOPIC}: {exc}")
        await client.disconnect()
        return 0

    def find_apk(candidates):
        """Newest APK for the wanted architecture (never a wrong one).

        The per-architecture build is preferred, a "universal" one is the
        fallback.
        """
        apks = []
        for msg in candidates or []:
            doc = getattr(msg, "document", None)
            if not doc:
                continue
            name = getattr(doc, "file_name", None) or ""
            if name.lower().endswith(".apk"):
                apks.append((msg, name))
        for pref in arch_preferences():
            for msg, name in apks:
                if matches_arch(name, pref):
                    return msg, name, pref
        return None

    found = find_apk(messages)

    if not found:
        # The topic filter may not work for every forum setup - scan the whole
        # chat as a fallback.
        try:
            print(f"[fallback] scanning the whole @{CHANNEL} chat")
            everything = await client.get_messages(CHANNEL, limit=LIMIT * 3)
            found = find_apk(everything)
        except Exception as exc:
            print(f"::warning::Could not scan @{CHANNEL}: {exc}")

    if not found:
        print(f"::warning::No {ARCH} APK found in @{CHANNEL} (topic {TOPIC}) - skipping")
        await client.disconnect()
        return 0

    msg, name, kind = found
    print(f"Found: {name} ({kind}, message {msg.id}, {getattr(msg, 'date', '?')})")
    try:
        saved = await client.download_media(msg, file=tmp_out)
    except Exception as exc:
        print(f"::warning::Could not download the APK: {exc}")
        return 0
    finally:
        await client.disconnect()

    saved = saved or tmp_out
    target = OUT or f"releases/{sanitize(name)}"
    if os.path.abspath(saved) != os.path.abspath(target):
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
        os.replace(saved, target)
        saved = target
    if not os.path.exists(saved):
        print("::warning::The APK was not written to disk - skipping")
        return 0

    digest = hashlib.sha256()
    with open(saved, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)

    version = ""
    m = re.search(r"v?(\d+(?:\.\d+)+)", name)
    if m:
        version = m.group(1)

    meta = {
        "file": os.path.basename(saved),
        "original_name": name,
        "version": version,
        "arch": kind,
        "channel": CHANNEL,
        "topic": TOPIC,
        "message_id": msg.id,
        "message_date": str(getattr(msg, "date", "")),
        "size": os.path.getsize(saved),
        "sha256": digest.hexdigest(),
        "caption": (getattr(msg, "text", None) or getattr(msg, "caption", None) or "")[:500],
    }
    if META:
        os.makedirs(os.path.dirname(META) or ".", exist_ok=True)
        with open(META, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=2)
            fh.write("\n")

    print(f"Saved {meta['file']} ({meta['size'] / 1048576:.1f} MiB) sha256={meta['sha256'][:16]}...")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except SystemExit:
        raise
    except Exception as exc:
        # The manager APK is optional - never fail the build because of it.
        print(f"::warning::Could not fetch the BakaSU APK: {exc}")
        sys.exit(0)
