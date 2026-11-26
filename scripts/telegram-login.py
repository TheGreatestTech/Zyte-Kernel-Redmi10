#!/usr/bin/env python3
"""Create a Telegram StringSession for the CI (run this locally, once).

Usage:
    TELEGRAM_API_ID=12345678 \\
    TELEGRAM_API_HASH=abcdef... \\
    TELEGRAM_PHONE=+91XXXXXXXXXX \\
    python3 scripts/telegram-login.py

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

api_id = os.environ.get("TELEGRAM_API_ID", "")
api_hash = os.environ.get("TELEGRAM_API_HASH", "")
phone = os.environ.get("TELEGRAM_PHONE", "")

missing = [n for n, v in (("TELEGRAM_API_ID", api_id),
                          ("TELEGRAM_API_HASH", api_hash),
                          ("TELEGRAM_PHONE", phone)) if not v]
if missing:
    sys.exit("Missing: " + ", ".join(missing))


async def main():
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
        print("Add this as the TELEGRAM_SESSION secret:")
        print()
        print(session)
        print()
    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
