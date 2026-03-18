#!/bin/bash
# Flash Armbian image to SD card for Tomate MCD-125 recovery
# Run from: /home/juliano/Documents/replay/armbian_build/armbian-build/
#
# After flashing:
#   1. Run ./prepare_sd_rollback.sh to copy emmc_uboot_backup.bin to SD boot partition
#   2. Insert SD card, hold recovery button (AV port), connect power
#   3. Monitor with: ./uart_debug.sh

set -e

IMG=$(ls output/images/Armbian-unofficial_*Tomate-mcd125*.img 2>/dev/null | head -1)

if [ -z "$IMG" ]; then
    echo "ERROR: No Armbian image found in output/images/"
    echo "Build first: ./compile.sh build BOARD=tomate-mcd125 BRANCH=current RELEASE=bookworm KERNEL_CONFIGURE=no EXPERT=yes"
    exit 1
fi

echo "=== Tomate MCD-125 — SD Card Flash Tool ==="
echo ""
echo "Image: $IMG"
echo "Size:  $(du -h "$IMG" | cut -f1)"
echo ""

# List available block devices (SD cards)
echo "Available block devices:"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|nvme\|sr" || true
echo ""

if [ -z "$1" ]; then
    echo "Usage: $0 /dev/sdX"
    echo ""
    echo "WARNING: This will ERASE the target device completely!"
    echo "Confirm with: lsblk"
    exit 1
fi

DEV="$1"

if [ ! -b "$DEV" ]; then
    echo "ERROR: $DEV is not a block device"
    exit 1
fi

# Safety check: refuse if device is mounted
if mount | grep -q "^$DEV"; then
    echo "ERROR: $DEV appears to be mounted. Unmount first."
    mount | grep "^$DEV"
    exit 1
fi

# Get device size for sanity check (reject if > 64GB — probably not an SD card)
SIZE_BYTES=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
if [ "$SIZE_GB" -gt 64 ]; then
    echo "ERROR: $DEV is ${SIZE_GB}GB — too large for an SD card. Aborting."
    exit 1
fi

echo "Target: $DEV (${SIZE_GB}GB)"
echo ""
echo "WARNING: ALL DATA ON $DEV WILL BE ERASED!"
read -rp "Type YES to confirm: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Flashing image..."
sudo dd if="$IMG" of="$DEV" bs=4M status=progress conv=fsync
sync

echo ""
echo "Flash complete!"
echo ""
echo "=== Next steps ==="
echo ""
echo "1. Copy Android backup to SD boot partition for U-Boot rollback:"
echo "   ./prepare_sd_rollback.sh"
echo ""
echo "2. Safely eject the SD card:"
echo "   sudo eject $DEV"
echo ""
echo "3. Insert SD into Tomate MCD-125, hold recovery button (AV port),"
echo "   then connect power. Hold ~3 seconds, then release."
echo ""
echo "4. Monitor boot via UART:"
echo "   ./uart_debug.sh"
echo ""
echo "Expected UART output:"
echo "  U-Boot SPL 2024.01 ..."
echo "  DRAM: 2048 MiB"
echo "  Trying to boot from MMC1 (SD) ..."
echo ""
echo "If BROM falls to FEL (no output): U-Boot TOC0 signature issue."
echo "Check: strings output/u-boot/u-boot-sunxi-with-spl.bin | grep -E 'TOC0|eGON'"
