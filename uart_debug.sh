#!/bin/bash
# UART debug session for Tomate MCD-125
# Usage: ./uart_debug.sh [port]
# Default port: /dev/ttyUSB0
#
# Connection (3.3V ONLY — never connect VCC):
#   USB-TTL GND  →  PCB GND
#   USB-TTL RX   →  PCB TX  (PH0)
#   USB-TTL TX   →  PCB RX  (PH1)
#
# UART0 on PCB GYS_A7_V3.1: pads near SoC or board edge, labeled TX/RX/GND

PORT="${1:-/dev/ttyUSB0}"
LOGFILE="uart.log"
BAUD=115200

echo "=== Tomate MCD-125 UART Debug ==="
echo "Port:    $PORT"
echo "Baud:    $BAUD 8N1"
echo "Log:     $LOGFILE (appended)"
echo ""

# Check port exists
if [ ! -e "$PORT" ]; then
    echo "ERROR: $PORT not found."
    echo ""
    echo "Available serial ports:"
    ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  (none found — check USB-TTL connection)"
    exit 1
fi

echo "=== What to expect ==="
echo ""
echo "NORMAL BOOT:"
echo "  U-Boot SPL ..."
echo "  DRAM: 2048 MiB"
echo "  Trying to boot from MMC1 (SD)"
echo "  ...kernel messages..."
echo ""
echo "DIAGNOSIS GUIDE:"
echo "  [no output at all]    → eMMC write offset wrong, or UART wiring issue"
echo "  [SPL only, no DRAM]   → DRAM init failure (timing params wrong)"
echo "  [DRAM OK, no kernel]  → SD card not found (check mmc0 vs mmc1)"
echo "  [kernel panic]        → DTB mismatch or rootfs UUID wrong"
echo ""
echo "U-BOOT ROLLBACK (if you get a U-Boot prompt):"
echo "  load mmc 0 0x40000000 emmc_uboot_backup.bin"
echo "  mmc dev 1"
echo "  mmc write 0x40000000 0 0x1000      # sector 0: backup has zeros@0-15, TOC0@sector16"
echo "  reset"
echo "  (requires emmc_uboot_backup.bin on SD root — run ./prepare_sd_rollback.sh first)"
echo ""
echo "Press Ctrl+A, Ctrl+X to exit picocom."
echo "--- session start $(date) ---"
echo ""
echo "--- session start $(date) ---" >> "$LOGFILE"

# Check if we need sudo for serial port access
if [ ! -w "$PORT" ]; then
    echo "Note: adding to dialout group for permanent access: sudo usermod -aG dialout $USER"
    exec sudo picocom \
        --baud "$BAUD" \
        --databits 8 \
        --parity n \
        --stopbits 1 \
        --flow none \
        --logfile "$LOGFILE" \
        "$PORT"
else
    exec picocom \
        --baud "$BAUD" \
        --databits 8 \
        --parity n \
        --stopbits 1 \
        --flow none \
        --logfile "$LOGFILE" \
        "$PORT"
fi
