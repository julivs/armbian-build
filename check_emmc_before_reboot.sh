#!/bin/bash
# check_emmc_before_reboot.sh
# Executar NO DISPOSITIVO (via SSH) antes de remover o SD e rebootar da eMMC.
#
# Uso: bash check_emmc_before_reboot.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES+1)); }

FAILURES=0
EMMC_DEV=""

echo ""
echo -e "${CYAN}=== Verificação pré-boot eMMC — Tomate MCD-125 ===${NC}"
echo ""

# ── 1. Identificar eMMC ──────────────────────────────────────────────────────
echo -e "${CYAN}[1] Identificando dispositivos de bloco${NC}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL

echo ""
for dev in mmcblk0 mmcblk1 mmcblk2; do
    name_file="/sys/block/${dev}/device/name"
    if [ -f "$name_file" ]; then
        name=$(cat "$name_file")
        echo "  /dev/${dev}: $name"
    fi
done
echo ""

# Detectar eMMC (mmcblk com boot partitions)
for dev in mmcblk0 mmcblk1 mmcblk2; do
    if [ -d "/sys/block/${dev}/device" ] && [ -b "/dev/${dev}" ]; then
        if ls /sys/block/${dev}/${dev}boot* &>/dev/null 2>&1; then
            EMMC_DEV="/dev/${dev}"
            ok "eMMC detectada: $EMMC_DEV (tem partições boot)"
            break
        fi
    fi
done

if [ -z "$EMMC_DEV" ]; then
    # Fallback: assumir mmcblk2 conforme configuração do projeto
    EMMC_DEV="/dev/mmcblk2"
    warn "Não detectou eMMC automaticamente, assumindo $EMMC_DEV"
fi

# ── 2. Partições da eMMC ─────────────────────────────────────────────────────
echo -e "${CYAN}[2] Partições da eMMC ($EMMC_DEV)${NC}"
if fdisk -l "$EMMC_DEV" 2>/dev/null; then
    ok "Tabela de partições lida com sucesso"
else
    fail "Não foi possível ler partições de $EMMC_DEV"
fi
echo ""

# ── 3. TOC0 magic na eMMC ────────────────────────────────────────────────────
echo -e "${CYAN}[3] Verificando TOC0 no offset 8192 (setor 16)${NC}"
toc0_magic=$(od -A n -t x1 -j 8192 -N 4 "$EMMC_DEV" | tr -d ' \n')
echo "  Magic encontrado: $toc0_magic"
if [ "$toc0_magic" = "544f4330" ]; then
    ok "TOC0 confirmado (544f4330)"
else
    fail "TOC0 NÃO encontrado! Magic: $toc0_magic (esperado: 544f4330)"
fi

# Mostrar header completo (32 bytes)
echo "  Header TOC0 completo (32 bytes):"
od -A n -t x1 -j 8192 -N 32 "$EMMC_DEV" | tr -s ' '
echo ""

# ── 4. Versão do SPL gravado ─────────────────────────────────────────────────
echo -e "${CYAN}[4] Versão do U-Boot SPL na eMMC${NC}"
spl_ver=$(strings "$EMMC_DEV" 2>/dev/null | grep -m1 "U-Boot SPL" || true)
if [ -n "$spl_ver" ]; then
    ok "SPL: $spl_ver"
    # Verificar se é o Armbian novo (não Android)
    if echo "$spl_ver" | grep -q "armbian\|2024\|2025\|2026"; then
        ok "Confirmado: binário Armbian (não Android OEM)"
    else
        warn "SPL pode ser Android OEM — verifique a data/versão"
    fi
else
    warn "Não foi possível extrair versão do SPL (pode ser comprimido)"
fi
echo ""

# ── 5. Rootfs da eMMC ───────────────────────────────────────────────────────
echo -e "${CYAN}[5] Verificando rootfs da eMMC${NC}"

# Detectar partição root (tentar p2, depois p1)
ROOT_PART=""
for p in "${EMMC_DEV}p2" "${EMMC_DEV}p1"; do
    if [ -b "$p" ]; then
        ROOT_PART="$p"
        break
    fi
done

if [ -z "$ROOT_PART" ]; then
    fail "Nenhuma partição encontrada em $EMMC_DEV"
else
    echo "  Tentando montar $ROOT_PART em /mnt..."
    if mount "$ROOT_PART" /mnt 2>/dev/null; then
        if [ -f /mnt/etc/armbian-release ]; then
            ok "rootfs Armbian encontrado!"
            echo ""
            cat /mnt/etc/armbian-release
        elif [ -d /mnt/etc ]; then
            warn "Partição montada mas não é rootfs Armbian (sem /etc/armbian-release)"
            ls /mnt/etc/ | head -10
        else
            warn "Partição montada mas /etc não encontrado"
            ls /mnt/
        fi
        umount /mnt
    else
        warn "Não foi possível montar $ROOT_PART — pode ser Android ou formato diferente"
    fi
fi
echo ""

# ── 6. /boot da eMMC ────────────────────────────────────────────────────────
echo -e "${CYAN}[6] Verificando /boot da eMMC${NC}"

BOOT_PART=""
for p in "${EMMC_DEV}p1" "${EMMC_DEV}p2"; do
    if [ -b "$p" ]; then
        if mount "$p" /mnt 2>/dev/null; then
            if [ -f /mnt/armbianEnv.txt ] || [ -f /mnt/Image ] || [ -d /mnt/dtb ]; then
                BOOT_PART="$p"
                ok "/boot encontrado em $p"
                echo ""
                echo "  Conteúdo de /mnt:"
                ls /mnt/
                echo ""
                if [ -f /mnt/armbianEnv.txt ]; then
                    echo "  armbianEnv.txt:"
                    cat /mnt/armbianEnv.txt
                fi
                umount /mnt
                break
            fi
            umount /mnt
        fi
    fi
done

if [ -z "$BOOT_PART" ]; then
    warn "Partição /boot com armbianEnv.txt não encontrada"
fi
echo ""

# ── Resultado final ──────────────────────────────────────────────────────────
echo -e "${CYAN}=== Resultado ===${NC}"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}Todos os checks passaram. Pronto para rebootar da eMMC.${NC}"
    echo ""
    echo "Próximo passo:"
    echo "  reboot   (remova o SD ANTES de rebootar, ou durante o countdown)"
else
    echo -e "${RED}$FAILURES check(s) falharam. Verifique antes de rebootar.${NC}"
fi
echo ""
