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
