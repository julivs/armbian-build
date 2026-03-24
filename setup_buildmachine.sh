#!/bin/bash
# =============================================================================
# setup_buildmachine.sh — Armbian build environment setup for MCD-125 project
# Target: Linux Mint (Ubuntu/Debian based), x86_64
# Usage:  bash setup_buildmachine.sh [--username <user>]
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REPO_URL="https://github.com/julivs/armbian-build.git"
REPO_BRANCH="mcd-125"
REPO_DIR="$HOME/armbian-build"
UPSTREAM_URL="https://github.com/armbian/build.git"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }
step()  { echo -e "\n\e[1;34m==> $*\e[0m"; }

require_not_root() {
    [ "$(id -u)" -ne 0 ] || error "Run as a normal user (not root). sudo will be used when needed."
}

# --------------------------------------------------------------------------
# 1. System update
# --------------------------------------------------------------------------
step "Updating system packages"
sudo apt-get update -qq
sudo apt-get upgrade -y

# --------------------------------------------------------------------------
# 2. Build dependencies
# --------------------------------------------------------------------------
step "Installing build dependencies"
sudo apt-get install -y \
    git curl wget \
    ca-certificates gnupg lsb-release \
    python3 python3-pip python3-serial \
    jq bc bison flex \
    libssl-dev libelf-dev \
    qemu-user-static binfmt-support \
    device-tree-compiler \
    u-boot-tools \
    parted dosfstools \
    rsync pigz \
    screen minicom \
    xz-utils zstd \
    pv \
    fdisk \
    fakeroot

# --------------------------------------------------------------------------
# 3. Docker CE
# --------------------------------------------------------------------------
step "Installing Docker CE"
if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
else
    # Remove old/distro docker packages
    sudo apt-get remove -y docker docker.io containerd runc 2>/dev/null || true

    # Add Docker official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Use Ubuntu codename (Linux Mint ships with UBUNTU_CODENAME in os-release)
    UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    info "Docker installed: $(docker --version)"
fi

# Add current user to docker group (requires logout/login to take effect)
if ! groups | grep -qw docker; then
    info "Adding $USER to docker group"
    sudo usermod -aG docker "$USER"
    warn "Docker group added — you must log out and back in before running builds."
    warn "Or run: newgrp docker"
fi

# --------------------------------------------------------------------------
# 4. Serial/UART access (ttyUSB0 for uart_helper.py)
# --------------------------------------------------------------------------
step "Configuring UART/serial access"
if ! groups | grep -qw dialout; then
    sudo usermod -aG dialout "$USER"
    info "Added $USER to dialout group (for /dev/ttyUSB0)"
fi

# --------------------------------------------------------------------------
# 5. Clone the Armbian build repo
# --------------------------------------------------------------------------
step "Cloning armbian-build fork"
if [ -d "$REPO_DIR/.git" ]; then
    info "Repo already exists at $REPO_DIR — pulling latest"
    git -C "$REPO_DIR" fetch origin
    git -C "$REPO_DIR" checkout "$REPO_BRANCH"
    git -C "$REPO_DIR" pull origin "$REPO_BRANCH"
else
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# Add upstream remote if not present
if ! git -C "$REPO_DIR" remote | grep -q upstream; then
    git -C "$REPO_DIR" remote add upstream "$UPSTREAM_URL"
    info "Added upstream remote: $UPSTREAM_URL"
fi

info "Repo ready at: $REPO_DIR"
info "Branch: $(git -C "$REPO_DIR" branch --show-current)"
info "Last commit: $(git -C "$REPO_DIR" log --oneline -1)"

# --------------------------------------------------------------------------
# 6. Python dependencies
# --------------------------------------------------------------------------
step "Checking Python dependencies"
python3 -c "import serial" 2>/dev/null \
    && info "pyserial already installed: $(python3 -c 'import serial; print(serial.__version__)')" \
    || { pip3 install pyserial --break-system-packages; info "pyserial installed"; }

# --------------------------------------------------------------------------
# 7. documents/ transfer reminder
# --------------------------------------------------------------------------
step "Documents folder (PDFs, datasheets)"
cat <<'DOCS'
The documents/ folder is gitignored (large PDFs/binaries).
Transfer from your current machine via one of:

  Option A — rsync over SSH (fastest):
    rsync -avz --progress \
      usuario@IP_ORIGEM:~/Documents/replay/armbian_build/armbian-build/documents/ \
      ~/armbian-build/documents/

  Option B — pendrive:
    Copy ~/Documents/replay/armbian_build/armbian-build/documents/
    to ~/armbian-build/documents/ on the new machine.

Key files in documents/:
  - H616_Datasheet_V1.0_cleaned.pdf
  - H616_User_Manual_V1.0_cleaned.pdf
  - emac1-dts-history.md
  - hardwareimages/dados.txt  (hardware chip IDs)
DOCS

# --------------------------------------------------------------------------
# 8. userpatches/ transfer reminder (gitignored)
# --------------------------------------------------------------------------
step "userpatches/ folder (gitignored)"
cat <<'UP'
The userpatches/ folder is gitignored by Armbian upstream.
Transfer from your current machine:

  rsync -avz --progress \
    usuario@IP_ORIGEM:~/Documents/replay/armbian_build/armbian-build/userpatches/ \
    ~/armbian-build/userpatches/

Contents needed for MCD-125:
  userpatches/kernel/archive/sunxi-6.12/
    - sunxi-gmac-debug-prints.patch
    - sunxi-gmac-mdio-debug.patch
    - sunxi-gmac-mac-reset-before-mdio.patch
UP

# --------------------------------------------------------------------------
# 9. Quick build test command
# --------------------------------------------------------------------------
step "All done!"
cat <<EOF

=======================================================================
  Build machine setup complete.

  If you added yourself to docker/dialout groups, LOG OUT and back in
  (or run: newgrp docker).

  Test with a quick build:
    cd ~/armbian-build
    ./compile.sh BOARD=tomate-mcd125 BRANCH=current \\
      BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIG=no

  UART helper (requires USB-UART adapter on /dev/ttyUSB0):
    python3 uart_helper.py run --cmd "uname -a" --prompt "# " --timeout 10

  Flash SD:
    sudo bash flash_sd.sh /dev/sdX
=======================================================================
EOF
