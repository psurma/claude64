#!/usr/bin/env python3
"""
Claude API <-> Commodore 64 Ultimate Bridge

Polls C64U memory via HTTP API, relays messages to Claude,
writes responses back to C64 memory.
"""

import sys
import time
import struct
import subprocess
import requests

# Flush stdout immediately for background mode
sys.stdout.reconfigure(line_buffering=True)

# C64U connection
C64U_HOST = "http://192.168.1.103"
POLL_INTERVAL = 0.3  # seconds

# Memory addresses (must match c64claude.asm)
OUT_FLAG = 0xC000
OUT_LEN  = 0xC001
OUT_BUF  = 0xC002
IN_FLAG  = 0xC100
IN_LEN_LO = 0xC101
IN_LEN_HI = 0xC102
IN_BUF   = 0xC103
STATUS   = 0xC500

# Max response size (~1020 bytes)
MAX_RESPONSE = 1020

SYSTEM_PROMPT = """You are Claude, an AI assistant made by Anthropic, chatting with a human on a real Commodore 64 computer from 1982.

IMPORTANT CONSTRAINTS - you MUST follow these:
- Keep responses under 400 characters total
- Use ONLY plain uppercase ASCII letters, numbers, and basic punctuation (. , ! ? - : ; ' ")
- NO markdown, NO asterisks, NO bullet points, NO numbered lists
- NO emoji, NO special characters, NO curly braces or brackets
- NO backticks, NO code blocks
- Use short paragraphs separated by blank lines
- The screen is 40 columns wide - keep lines natural
- Be concise, friendly, and fun
- You can reference the C64, retro computing, 8-bit culture
- If asked to write code, write C64 BASIC or 6502 assembly"""


def call_claude(user_text, conversation_history):
    """Call Claude via 'claude -p' pipe mode."""
    # Build the prompt with conversation context
    prompt_parts = []
    # Include recent history for context
    for msg in conversation_history[-10:]:
        role = msg["role"]
        content = msg["content"]
        if role == "user":
            prompt_parts.append(f"Human: {content}")
        else:
            prompt_parts.append(f"Assistant: {content}")
    prompt_parts.append(f"Human: {user_text}")
    prompt_parts.append("Assistant:")

    full_prompt = "\n\n".join(prompt_parts)

    # Prepend system prompt as context
    full_input = f"{SYSTEM_PROMPT}\n\n{full_prompt}"

    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "sonnet"],
            input=full_input,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            return f"ERROR: CLAUDE RETURNED CODE {result.returncode}"
    except subprocess.TimeoutExpired:
        return "SORRY, I TOOK TOO LONG TO THINK. TRY AGAIN?"
    except FileNotFoundError:
        return "ERROR: CLAUDE CLI NOT FOUND. IS IT INSTALLED?"
    except Exception as e:
        return f"ERROR: {str(e)[:80]}"

def read_mem(address, length):
    """Read bytes from C64 memory."""
    url = f"{C64U_HOST}/v1/machine:readmem"
    params = {"address": f"{address:04x}", "length": str(length)}
    try:
        r = requests.get(url, params=params, timeout=5)
        r.raise_for_status()
        return r.content
    except Exception as e:
        print(f"  [!] readmem error: {e}")
        return None

def write_mem_bytes(address, data):
    """Write raw bytes to C64 memory."""
    url = f"{C64U_HOST}/v1/machine:writemem"
    params = {"address": f"{address:04x}"}
    try:
        r = requests.post(url, params=params, data=data,
                         headers={"Content-Type": "application/octet-stream"},
                         timeout=5)
        r.raise_for_status()
        return True
    except Exception as e:
        print(f"  [!] writemem error: {e}")
        return False

def write_mem_byte(address, value):
    """Write a single byte to C64 memory."""
    url = f"{C64U_HOST}/v1/machine:writemem"
    params = {"address": f"{address:04x}", "data": f"{value:02x}"}
    try:
        r = requests.put(url, params=params, timeout=5)
        r.raise_for_status()
        return True
    except Exception as e:
        print(f"  [!] writemem PUT error: {e}")
        return False

def petscii_to_ascii(data):
    """Convert PETSCII bytes to ASCII string."""
    result = []
    for b in data:
        if b == 0:
            break
        elif 0x41 <= b <= 0x5A:  # PETSCII uppercase A-Z
            result.append(chr(b))  # Same as ASCII uppercase
        elif 0xC1 <= b <= 0xDA:  # PETSCII shifted uppercase
            result.append(chr(b - 0xC1 + 0x41))
        elif 0x20 <= b <= 0x3F:  # Space, digits, punctuation
            result.append(chr(b))
        elif b == 0x0D:  # PETSCII return
            result.append('\n')
        else:
            result.append(chr(b) if 0x20 <= b <= 0x7E else '?')
    return ''.join(result)

def ascii_to_petscii(text):
    """Convert ASCII string to PETSCII bytes for C64 (uppercase mode)."""
    result = []
    for ch in text:
        c = ord(ch)
        if c == 0x0A or c == 0x0D:  # newline -> PETSCII return
            result.append(0x0D)
        elif 0x41 <= c <= 0x5A:  # Uppercase A-Z -> PETSCII uppercase
            result.append(c)
        elif 0x61 <= c <= 0x7A:  # Lowercase a-z -> PETSCII uppercase
            result.append(c - 0x20)
        elif 0x20 <= c <= 0x3F:  # Space, digits, basic punctuation
            result.append(c)
        elif c == ord('{'):
            result.append(ord('('))
        elif c == ord('}'):
            result.append(ord(')'))
        elif c == ord('\\'):
            result.append(ord('/'))
        elif c == ord('~'):
            result.append(ord('-'))
        elif c == ord('`'):
            result.append(ord("'"))
        elif c == ord('_'):
            result.append(ord('-'))
        elif c == ord('['):
            result.append(ord('('))
        elif c == ord(']'):
            result.append(ord(')'))
        elif c == ord('@'):
            result.append(0x40)  # @ exists in PETSCII
        elif 0x20 <= c <= 0x7E:
            result.append(c)  # Try as-is for other printable ASCII
        # Skip non-printable / unsupported
    return bytes(result)

def send_response(text):
    """Write response text to C64 memory and set flag."""
    petscii = ascii_to_petscii(text)
    if len(petscii) > MAX_RESPONSE:
        petscii = petscii[:MAX_RESPONSE]

    length = len(petscii)
    lo = length & 0xFF
    hi = (length >> 8) & 0xFF

    # Write response buffer
    write_mem_bytes(IN_BUF, petscii)

    # Write length
    write_mem_byte(IN_LEN_LO, lo)
    write_mem_byte(IN_LEN_HI, hi)

    # Set flag last (so C64 sees complete data)
    write_mem_byte(IN_FLAG, 1)

def set_status(status_code):
    """Update bridge status on C64."""
    write_mem_byte(STATUS, status_code)

def main():
    print("=" * 50)
    print("  CLAUDE <-> COMMODORE 64 BRIDGE")
    print("=" * 50)

    conversation = []

    print(f"[*] Connecting to C64U at {C64U_HOST}...")

    # Test connection
    try:
        info = requests.get(f"{C64U_HOST}/v1/info", timeout=5).json()
        print(f"[+] Connected! {info.get('product', 'Unknown')} "
              f"fw:{info.get('firmware_version', '?')} "
              f"core:{info.get('core_version', '?')}")
    except Exception as e:
        print(f"[!] Cannot reach C64U: {e}")
        sys.exit(1)

    # Signal connected
    set_status(1)
    print("[*] Bridge active. Polling for messages...")
    print()

    errors = 0

    while True:
        try:
            time.sleep(POLL_INTERVAL)

            # Read the outgoing flag
            data = read_mem(OUT_FLAG, 1)
            if data is None:
                errors += 1
                if errors > 10:
                    print("[!] Too many errors, reconnecting...")
                    set_status(0)
                    time.sleep(2)
                    set_status(1)
                    errors = 0
                continue

            errors = 0

            if data[0] != 1:
                continue

            # Message ready! Read length and buffer
            header = read_mem(OUT_LEN, 1)
            if header is None:
                continue
            msg_len = header[0]

            if msg_len == 0:
                write_mem_byte(OUT_FLAG, 0)
                continue

            msg_data = read_mem(OUT_BUF, msg_len)
            if msg_data is None:
                continue

            # Clear outgoing flag
            write_mem_byte(OUT_FLAG, 0)

            # Convert to ASCII
            user_text = petscii_to_ascii(msg_data[:msg_len])
            print(f"[C64] > {user_text}")

            # Set thinking status
            set_status(2)

            # Call Claude API
            try:
                reply = call_claude(user_text, conversation)
                print(f"[Claude] {reply}")

                conversation.append({"role": "user", "content": user_text})
                conversation.append({"role": "assistant", "content": reply})

                # Send to C64
                send_response(reply)

            except Exception as e:
                error_msg = f"ERROR: {str(e)[:60]}"
                print(f"[!] {error_msg}")
                send_response(error_msg)

            # Back to connected
            set_status(1)

        except KeyboardInterrupt:
            print("\n[*] Shutting down bridge...")
            set_status(0)
            break
        except Exception as e:
            print(f"[!] Unexpected error: {e}")
            time.sleep(1)

if __name__ == "__main__":
    main()
