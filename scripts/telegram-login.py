#!/usr/bin/env python3
"""Create a Telegram StringSession for the CI (run this locally, once).

Usage (bash):
    TELEGRAM_API_ID=12345678 \\
    TELEGRAM_API_HASH=abcdef... \\
    TELEGRAM_PHONE=+91XXXXXXXXXX \\
    python3 scripts/telegram-login.py

Usage (fish, or no shell at all):
    python3 scripts/telegram-login.py --api-id 12345678 \\
        --api-hash abcdef... --phone +91XXXXXXXXXX

Check a session you already have:
    python3 scripts/telegram-login.py --api-id ... --api-hash ... \\
        --session <the long string> --check

It prints a long session string. Put it into the repository secret
TELEGRAM_SESSION (Settings -> Secrets and variables -> Actions).

The session gives full access to the Telegram account it was created with -
use a dedicated account if that matters to you.
"""

import asyncio
import os
import sys

try:
    from telethon import TelegramClient
    from telethon.errors import SessionPasswordNeededError
    from telethon.sessions import StringSession
except ImportError:
    sys.exit("telethon is missing - install it with: pip install telethon")

def arg(flag, env):
    """A value from the command line or from the environment."""
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return os.environ.get(env, "")


api_id = arg("--api-id", "TELEGRAM_API_ID")
api_hash = arg("--api-hash", "TELEGRAM_API_HASH")
phone = arg("--phone", "TELEGRAM_PHONE")

CHECK_ONLY = "--check" in sys.argv

required = [("TELEGRAM_API_ID", api_id), ("TELEGRAM_API_HASH", api_hash)]
if not CHECK_ONLY:
    required.append(("TELEGRAM_PHONE", phone))
missing = [n for n, v in required if not v]
if missing:
    sys.exit("Missing: " + ", ".join(missing))


def normalize_session(raw):
    """Clean up a pasted StringSession (quotes, line breaks, extra text)."""
    import re

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
        packed = struct.pack(">B16sH256s", raw[0], raw[1:5].ljust(16, b"\x00"),
                             raw[5:7], raw[7:])
        fixed = "1" + base64.urlsafe_b64encode(packed).decode().rstrip("=")
        return fixed, "was converted to the canonical format"
    return session, (f"decodes to {len(raw)} bytes - expected 263 or 275, "
                     f"so it is truncated or has extra characters")


async def main():
    # --check verifies a session that is already stored somewhere.
    if CHECK_ONLY:
        session = normalize_session(arg("--session", "TELEGRAM_SESSION"))
        if not session:
            sys.exit("TELEGRAM_SESSION is empty")
        try:
            client = TelegramClient(StringSession(session), int(api_id), api_hash)
        except Exception as exc:
            sys.exit(f"Not a valid StringSession: {exc}")
        await client.connect()
        try:
            if not await client.is_user_authorized():
                sys.exit("The session is not authorized (log in again)")
            me = await client.get_me()
            print(f"Session OK - {me.first_name} (@{me.username}) {me.phone}")
        finally:
            await client.disconnect()
        return

    # Every Telethon method is a coroutine - they must be awaited.
    client = TelegramClient(StringSession(), int(api_id), api_hash)
    await client.connect()

    try:
        if not await client.is_user_authorized():
            sent = await client.send_code_request(phone)
            code = input("Enter the login code from Telegram: ").strip()
            try:
                await client.sign_in(phone=phone, code=code,
                                     phone_code_hash=sent.phone_code_hash)
            except SessionPasswordNeededError:
                await client.sign_in(password=input("Two-factor password: ").strip())
            print("Logged in.")

        session = client.session.save()
        if not session:
            sys.exit("Could not create a session - check api_id/api_hash and the phone number.")

        # Always hand out the canonical format, so the secret has exactly one
        # valid length.
        session, note = fix_session(session)
        print(f"Session ({note}): {len(session)} characters")

        print()
        print(f"Add this as the TELEGRAM_SESSION secret ({len(session)} characters):")
        print()
        print(session)
        print()
        print("Copy that single line - nothing else, no quotes, no line breaks.")
    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
