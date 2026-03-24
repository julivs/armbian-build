#!/usr/bin/env python3
"""
uart_helper.py — Serial interaction helper for Tomate MCD-125 / Allwinner H313
Usage:
  python3 uart_helper.py capture --duration 90 --log /tmp/boot.txt
  python3 uart_helper.py run --cmd "dmesg | grep emac" --prompt "# " --timeout 10
  python3 uart_helper.py uboot --cmd "mmc dev 1; mmc info" --timeout 15
"""

import argparse
import sys
import time
import threading

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed. Run: pip3 install pyserial", file=sys.stderr)
    sys.exit(1)


DEFAULT_PORT = "/dev/ttyUSB0"
DEFAULT_BAUD = 115200

# Patterns that signal U-Boot autoboot prompt
UBOOT_AUTOBOOT_PATTERNS = [b"Hit any key", b"autoboot", b"stop autoboot"]
UBOOT_PROMPT = b"=>"


def open_port(port, baud):
    return serial.Serial(
        port,
        baudrate=baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.1,
    )


def cmd_capture(args):
    """Capture serial output for a fixed duration and save to log file."""
    port = open_port(args.port, args.baud)
    log_path = args.log
    duration = args.duration

    print(f"[uart_helper] Capturing {duration}s from {args.port} → {log_path}", flush=True)

    buf = bytearray()
    deadline = time.time() + duration

    try:
        while time.time() < deadline:
            chunk = port.read(256)
            if chunk:
                buf.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            remaining = deadline - time.time()
            if remaining <= 0:
                break
    except KeyboardInterrupt:
        print("\n[uart_helper] Interrupted by user", flush=True)
    finally:
        port.close()

    with open(log_path, "wb") as f:
        f.write(buf)

    print(f"\n[uart_helper] Saved {len(buf)} bytes to {log_path}", flush=True)


def read_until_prompt(port, prompt_bytes, timeout, extra_patterns=None):
    """Read from serial until prompt is found or timeout expires. Returns accumulated bytes."""
    buf = bytearray()
    deadline = time.time() + timeout
    prompt = prompt_bytes if isinstance(prompt_bytes, bytes) else prompt_bytes.encode()

    while time.time() < deadline:
        chunk = port.read(256)
        if chunk:
            buf.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            if buf.endswith(prompt) or prompt in buf[-len(prompt) - 10:]:
                break
            if extra_patterns:
                for pat in extra_patterns:
                    if pat in buf:
                        return buf, pat
    return buf, None


def cmd_run(args):
    """Send a command to Linux shell and wait for shell prompt."""
    port = open_port(args.port, args.baud)
    prompt = args.prompt.encode() if isinstance(args.prompt, str) else args.prompt
    timeout = args.timeout

    print(f"[uart_helper] Sending command: {args.cmd!r}", flush=True)

    if not args.no_preamble:
        # Send a newline first to get a fresh prompt
        port.write(b"\n")
        time.sleep(0.3)
        port.reset_input_buffer()

    # Send the command
    port.write(args.cmd.encode() + b"\n")

    buf, _ = read_until_prompt(port, prompt, timeout)
    port.close()

    if not buf:
        print("[uart_helper] WARNING: No output received (timeout?)", flush=True)
        sys.exit(1)


def cmd_uboot(args):
    """
    Interrupt U-Boot autoboot and run a command at the U-Boot prompt.

    Two modes:
    - Normal (default): waits for 'Hit any key' pattern then sends interrupt.
    - Spam (--spam): immediately starts sending spaces every 50ms in a background
      thread for the first `--spam-duration` seconds. Use this when the autoboot
      window is too short (e.g. 1 second) for pattern-detection to work.
      Start the script BEFORE powering/rebooting the device.
    """
    port = open_port(args.port, args.baud)
    timeout = args.timeout
    deadline = time.time() + timeout

    if args.spam:
        spam_end = time.time() + args.spam_duration
        print(f"[uart_helper] SPAM mode: sending spaces every 50ms for {args.spam_duration}s — power/reboot the device NOW", flush=True)

        stop_spam = threading.Event()

        def spammer():
            while not stop_spam.is_set() and time.time() < spam_end:
                try:
                    port.write(b" ")
                except Exception:
                    break
                time.sleep(0.05)

        t = threading.Thread(target=spammer, daemon=True)
        t.start()

        # While spamming, also print everything we receive
        buf = bytearray()
        while time.time() < deadline:
            chunk = port.read(256)
            if chunk:
                buf.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            if UBOOT_PROMPT in buf[-20:]:
                break

        stop_spam.set()
        t.join(timeout=1)
        # Drain any stale '=> ' prompts U-Boot sent in response to extra spaces
        time.sleep(0.3)
        port.reset_input_buffer()

    else:
        print(f"[uart_helper] Waiting for U-Boot (timeout {timeout}s)...", flush=True)

        buf = bytearray()
        interrupted = False

        # Phase 1: watch for autoboot message, send \r to interrupt
        while time.time() < deadline:
            chunk = port.read(256)
            if chunk:
                buf.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()

            for pat in UBOOT_AUTOBOOT_PATTERNS:
                if pat in buf:
                    print(f"\n[uart_helper] Detected '{pat.decode()}' — sending interrupt", flush=True)
                    port.write(b" ")
                    time.sleep(0.1)
                    port.write(b"\r")
                    interrupted = True
                    break

            if interrupted:
                break

            if UBOOT_PROMPT in buf[-10:]:
                interrupted = True
                break

        if not interrupted:
            print("[uart_helper] WARNING: U-Boot autoboot window not detected (already booted?)", flush=True)
            port.write(b" \r")

        # Phase 2: wait for U-Boot prompt
        remaining = deadline - time.time()
        print(f"[uart_helper] Waiting for U-Boot prompt...", flush=True)
        read_until_prompt(port, UBOOT_PROMPT, max(remaining, 5))

    # Final phase: send the command
    if args.cmd:
        print(f"\n[uart_helper] Running U-Boot command: {args.cmd!r}", flush=True)
        port.write(args.cmd.encode() + b"\r")
        remaining = deadline - time.time()
        read_until_prompt(port, UBOOT_PROMPT, max(remaining, 5))

    port.close()


def main():
    parser = argparse.ArgumentParser(description="UART helper for MCD-125 serial console")
    parser.add_argument("--port", default=DEFAULT_PORT, help=f"Serial port (default: {DEFAULT_PORT})")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help=f"Baud rate (default: {DEFAULT_BAUD})")

    sub = parser.add_subparsers(dest="mode", required=True)

    # capture mode
    p_cap = sub.add_parser("capture", help="Capture serial output for N seconds")
    p_cap.add_argument("--duration", type=float, default=60, help="Capture duration in seconds (default: 60)")
    p_cap.add_argument("--log", default="/tmp/uart_log.txt", help="Output log file (default: /tmp/uart_log.txt)")
    p_cap.set_defaults(func=cmd_capture)

    # run mode
    p_run = sub.add_parser("run", help="Send a command to Linux shell and capture output")
    p_run.add_argument("--cmd", required=True, help="Command to run")
    p_run.add_argument("--prompt", default="# ", help="Shell prompt to wait for (default: '# ')")
    p_run.add_argument("--timeout", type=float, default=15, help="Timeout in seconds (default: 15)")
    p_run.add_argument("--no-preamble", action="store_true", help="Skip leading newline/buffer-clear (use for login sequences)")
    p_run.set_defaults(func=cmd_run)

    # uboot mode
    p_ub = sub.add_parser("uboot", help="Interrupt U-Boot autoboot and run a command")
    p_ub.add_argument("--cmd", default="", help="U-Boot command to run (optional)")
    p_ub.add_argument("--timeout", type=float, default=30, help="Total timeout in seconds (default: 30)")
    p_ub.add_argument("--spam", action="store_true", help="Spam spaces immediately (for narrow autoboot windows)")
    p_ub.add_argument("--spam-duration", type=float, default=10, help="How long to spam spaces (default: 10s)")
    p_ub.set_defaults(func=cmd_uboot)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
