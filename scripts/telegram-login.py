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

import os
import sys

try:
    from telethon import TelegramClient
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

client = TelegramClient(StringSession(), int(api_id), api_hash)
client.connect()

if not client.is_user_authorized():
    sent = client.send_code_request(phone)
    code = input("Enter the login code from Telegram: ").strip()
    try:
        client.sign_in(phone=phone, code=code, phone_code_hash=sent.phone_code_hash)
    except Exception:
        # 2FA: the password prompt only works on a TTY.
        client.sign_in(password=input("Two-factor password: ").strip())

print()
print("Add this as the TELEGRAM_SESSION secret:")
print()
print(client.session.save())
print()
client.disconnect()
