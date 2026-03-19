#!/bin/bash
# emmc_boot_setup.sh — Grava U-Boot na eMMC e prepara boot autônomo
#
# Rodar NO APARELHO via SSH/UART, logado como root, com o SD inserido.
# Segue o plano de teste do eMMC boot (fix alias mmc1=&mmc2).
#
# Uso:
#   ./emmc_boot_setup.sh              # flash U-Boot + diagnóstico
#   ./emmc_boot_setup.sh --full       # flash U-Boot + armbian-install

set -euo pipefail

EMMC="/dev/mmcblk2"
UBOOT_CANDIDATES=(
    "/boot/u-boot-sunxi-with-spl.bin"
    "/boot/u-boot.bin"
)
TOC0_MAGIC="544f4330"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── 1. Verificar eMMC presente ───────────────────────────────────────────────

step "Verificando dispositivos MMC"

lsblk -d -o NAME,SIZE,TYPE | grep mmc || true
echo ""

[ ! -b "$EMMC" ] && error "eMMC $EMMC não encontrada. Verifique dmesg | grep mmc"

EMMC_SIZE=$(blockdev --getsize64 "$EMMC" 2>/dev/null || echo 0)
EMMC_GB=$((EMMC_SIZE / 1024 / 1024 / 1024))
info "eMMC: $EMMC (${EMMC_GB}GB)"

# ── 2. Verificar dmesg para erros MMC ───────────────────────────────────────

step "Log MMC (últimas ocorrências)"
dmesg | grep -i mmc | tail -20 || true

# Verificar ENODEV (sinal do bug do alias)
if dmesg | grep -q "ENODEV\|mmc2.*error\|mmc.*-19"; then
    warn "Erros MMC detectados no dmesg — verifique acima"
else
    info "Sem erros críticos MMC no dmesg"
fi

# ── 3. Localizar U-Boot ──────────────────────────────────────────────────────

step "Localizando U-Boot"

UBOOT=""
for candidate in "${UBOOT_CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
        UBOOT="$candidate"
        info "U-Boot encontrado: $UBOOT ($(du -h "$UBOOT" | cut -f1))"
        break
    fi
done

if [ -z "$UBOOT" ]; then
    # Tentar extrair do SD (mmcblk0)
    warn "u-boot-sunxi-with-spl.bin não encontrado em /boot"
    warn "Tentando extrair do SD card (mmcblk0, setor 16)..."
    UBOOT="/tmp/uboot_from_sd.bin"
    dd if=/dev/mmcblk0 of="$UBOOT" bs=512 skip=16 count=4096 status=none
    info "U-Boot extraído do SD: $UBOOT"
fi

# Verificar TOC0 magic no U-Boot
uboot_magic=$(od -A n -t x1 -j 0 -N 4 "$UBOOT" | tr -d ' \n')
if [ "$uboot_magic" = "$TOC0_MAGIC" ]; then
    info "TOC0 magic confirmado no U-Boot: $uboot_magic"
else
    # U-Boot nos arquivos Armbian começa com SPL; o TOC0 está no offset 0 do binário
    # mas pode haver um header — checar offset 8192 dentro do binário
    uboot_magic2=$(od -A n -t x1 -j 8192 -N 4 "$UBOOT" | tr -d ' \n')
    if [ "$uboot_magic2" = "$TOC0_MAGIC" ]; then
        info "TOC0 confirmado no offset 8192 do U-Boot: $uboot_magic2"
    else
        warn "TOC0 não confirmado (magic: $uboot_magic / $uboot_magic2)"
        warn "Prosseguindo mesmo assim — verifique após gravar"
    fi
fi

# ── 4. Gravar U-Boot na eMMC ─────────────────────────────────────────────────

step "Gravando U-Boot na eMMC (seek=16)"

echo "Comando: dd if=$UBOOT of=$EMMC bs=512 seek=16 conv=fsync"
echo ""
read -rp "Confirmar gravação em $EMMC? [YES/no] " CONFIRM
[ "$CONFIRM" != "YES" ] && { echo "Abortado."; exit 0; }

dd if="$UBOOT" of="$EMMC" bs=512 seek=16 conv=fsync status=progress
sync

info "U-Boot gravado"

# ── 5. Verificar TOC0 na eMMC ────────────────────────────────────────────────

step "Verificando TOC0 na eMMC (offset 8192 = setor 16)"

emmc_magic=$(od -A n -t x1 -j 8192 -N 4 "$EMMC" | tr -d ' \n')
if [ "$emmc_magic" = "$TOC0_MAGIC" ]; then
    info "TOC0 verificado na eMMC: $emmc_magic ✓"
else
    error "TOC0 NÃO encontrado na eMMC! Magic: $emmc_magic (esperado: $TOC0_MAGIC)"
fi

# ── 6. Diagnóstico U-Boot (opcional) ─────────────────────────────────────────

step "Diagnóstico U-Boot prompt (se disponível)"

echo "Para testar interativamente no U-Boot (pressione qualquer tecla no boot):"
echo "  U-Boot> mmc list"
echo "  # Esperado: sunxi-mmc@4022000 (mmc1)"
echo ""
echo "  U-Boot> mmc dev 1"
echo "  # Esperado: switch to partitions #0, OK"
echo "  # mmc1(part 0) is current device"
echo ""

# ── 7. Migrar sistema para eMMC (opcional) ───────────────────────────────────

if [ "${1:-}" = "--full" ]; then
    step "Migrando sistema para eMMC (armbian-install)"
    echo ""
    warn "Isso instalará o sistema completo na eMMC."
    warn "Após concluir, remova o SD e religue."
    echo ""
    armbian-install
else
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           PRÓXIMOS PASSOS                            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "U-Boot gravado na eMMC com sucesso."
    echo ""
    echo "Para instalar o sistema completo na eMMC:"
    echo "  armbian-install"
    echo "  → selecionar: Boot from eMMC - System on eMMC"
    echo ""
    echo "Ou para testar apenas o boot pelo U-Boot da eMMC:"
    echo "  1. Desligar o aparelho"
    echo "  2. Remover o SD card"
    echo "  3. Ligar — deve bootar pelo U-Boot da eMMC"
    echo "     (sistema raiz ainda no SD até armbian-install)"
    echo ""
    echo "Se falhar com ENODEV -19, conecte UART (115200) e verifique:"
    echo "  mmc list  →  sunxi-mmc@4022000 deve aparecer como mmc1"
fi
