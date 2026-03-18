#!/bin/bash
# deploy_mcd125.sh — Deploy Armbian no Tomate MCD-125
#
# Uso:
#   ./deploy_mcd125.sh              # detecta SD automaticamente
#   ./deploy_mcd125.sh /dev/sdX     # especifica o device
#
# Documenta o procedimento completo em:
#   documents/tomate-mcd125-armbian-deploy.md

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
IMG=$(ls "$REPO_DIR"/output/images/Armbian-unofficial_*Tomate-mcd125*.img 2>/dev/null | head -1)
SHA_FILE="${IMG}.sha"
BACKUP="$REPO_DIR/emmc_uboot_backup.bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Verificações iniciais ───────────────────────────────────────────────────

step "Verificando pré-requisitos"

[ -z "$IMG" ] && error "Imagem Armbian não encontrada em output/images/. Execute o build primeiro:
  ./compile.sh build BOARD=tomate-mcd125 BRANCH=current RELEASE=bookworm BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no"

info "Imagem: $(basename "$IMG") ($(du -h "$IMG" | cut -f1))"

# Verificar SHA256
if [ -f "$SHA_FILE" ]; then
    expected_sha=$(awk '{print $1}' "$SHA_FILE")
    actual_sha=$(sha256sum "$IMG" | awk '{print $1}')
    if [ "$expected_sha" = "$actual_sha" ]; then
        info "SHA256 OK"
    else
        error "SHA256 inválido! Imagem corrompida. Rebuilde com ./compile.sh"
    fi
fi

# Verificar TOC0 no offset 8192 da imagem
toc0_magic=$(od -A n -t x1 -j 8192 -N 4 "$IMG" | tr -d ' \n')
if [ "$toc0_magic" = "544f4330" ]; then
    info "TOC0 confirmado no setor 16 da imagem"
else
    error "TOC0 não encontrado no setor 16! Magic encontrado: $toc0_magic
Esperado: 544f4330 (TOC0). Rebuilde com CONFIG_SPL_IMAGE_TYPE_SUNXI_TOC0=y"
fi

# ── Detectar / validar device ───────────────────────────────────────────────

step "Identificando SD card"

echo ""
echo "Dispositivos disponíveis:"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|nvme\|sr" || true
echo ""

if [ -n "${1:-}" ]; then
    DEV="$1"
else
    # Auto-detectar dispositivos USB removíveis
    mapfile -t USB_DEVS < <(lsblk -d -o NAME,TRAN | awk '$2=="usb"{print "/dev/"$1}')
    if [ ${#USB_DEVS[@]} -eq 1 ]; then
        DEV="${USB_DEVS[0]}"
        warn "SD detectado automaticamente: $DEV"
    elif [ ${#USB_DEVS[@]} -gt 1 ]; then
        error "Múltiplos dispositivos USB detectados. Especifique o device:
  ./deploy_mcd125.sh /dev/sdX"
    else
        error "Nenhum SD card USB detectado. Especifique o device:
  ./deploy_mcd125.sh /dev/sdX"
    fi
fi

[ ! -b "$DEV" ] && error "$DEV não é um dispositivo de bloco"

# Recusar dispositivos montados
if mount | grep -q "^${DEV}"; then
    warn "Desmontando partições de $DEV..."
    mount | grep "^${DEV}" | awk '{print $1}' | xargs -r -I{} udisksctl unmount -b {} 2>/dev/null || \
    mount | grep "^${DEV}" | awk '{print $1}' | xargs -r umount 2>/dev/null || true
fi

# Verificar tamanho (recusar > 64GB — provavelmente não é SD card)
SIZE_BYTES=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
[ "$SIZE_GB" -gt 64 ] && error "$DEV tem ${SIZE_GB}GB — grande demais para SD card. Abortando."
[ "$SIZE_GB" -lt 1 ]  && error "$DEV tem ${SIZE_GB}GB — pequeno demais. Abortando."

info "Device: $DEV (${SIZE_GB}GB)"

# ── Confirmação ─────────────────────────────────────────────────────────────

echo ""
echo -e "${RED}ATENÇÃO: TODOS OS DADOS EM $DEV SERÃO APAGADOS!${NC}"
echo ""
read -rp "Digite YES para confirmar: " CONFIRM
[ "$CONFIRM" != "YES" ] && { echo "Abortado."; exit 0; }

# ── Gravar imagem ───────────────────────────────────────────────────────────

step "Gravando imagem Armbian"

sudo dd if="$IMG" of="$DEV" bs=4M status=progress conv=fsync
sync

info "Imagem gravada com sucesso"

# Verificar TOC0 no SD gravado
toc0_sd=$(sudo od -A n -t x1 -j 8192 -N 4 "$DEV" | tr -d ' \n')
if [ "$toc0_sd" = "544f4330" ]; then
    info "TOC0 verificado no SD gravado"
else
    warn "Não foi possível verificar TOC0 no SD. Verifique manualmente."
fi

# ── Copiar backup Android ────────────────────────────────────────────────────

step "Copiando backup Android para rollback"

if [ ! -f "$BACKUP" ]; then
    warn "emmc_uboot_backup.bin não encontrado — rollback Android não estará disponível"
else
    # Aguardar kernel re-detectar partições
    sleep 2
    partprobe "$DEV" 2>/dev/null || true
    sleep 1

    # Montar partição root do SD
    MOUNT_POINT=$(mktemp -d)
    PART="${DEV}1"

    if sudo mount "$PART" "$MOUNT_POINT" 2>/dev/null; then
        sudo mkdir -p "$MOUNT_POINT/boot"
        sudo cp "$BACKUP" "$MOUNT_POINT/boot/"
        sync
        sudo umount "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
        info "emmc_uboot_backup.bin copiado para /boot/ do SD"
    else
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        warn "Não foi possível montar $PART. Copie manualmente:
  sudo mount ${PART} /mnt && sudo cp $BACKUP /mnt/boot/ && sudo umount /mnt"
    fi
fi

# ── Ejetar ──────────────────────────────────────────────────────────────────

step "Ejetando SD card"

sync
udisksctl power-off -b "$DEV" 2>/dev/null || sudo eject "$DEV" 2>/dev/null || true
info "SD pronto para uso"

# ── Instruções finais ────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         PRÓXIMOS PASSOS — Tomate MCD-125             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "1. Inserir o SD card no aparelho"
echo ""
echo "2. Boot pelo SD:"
echo "   • eMMC com Android intacto:  segurar botão recovery (porta AV)"
echo "     enquanto conecta a energia; soltar após ~3 segundos"
echo "   • eMMC sem bootloader válido: conectar energia normalmente"
echo ""
echo "3. No terminal Armbian (HDMI ou UART 115200):"
echo "   root@tomate-mcd125:~# armbian-install"
echo "   → Selecionar eMMC como destino"
echo ""
echo "4. Após instalação: retirar SD e religar"
echo ""
echo "UART: ./uart_debug.sh"
echo "Docs: documents/tomate-mcd125-armbian-deploy.md"
echo ""

# ── Rollback (se solicitado) ─────────────────────────────────────────────────

if [ "${2:-}" = "--rollback-only" ]; then
    echo ""
    warn "Modo rollback: gerando instruções para restaurar Android"
    echo ""
    echo "No terminal Armbian rodando pelo SD:"
    echo "  dd if=/boot/emmc_uboot_backup.bin of=/dev/mmcblk2 bs=512 count=4096 status=progress"
    echo "  reboot"
fi
