#!/bin/bash
# adb_clear_emmc_spl.sh — Apaga área SPL do eMMC para forçar boot pelo SD
#
# Uso: ./adb_clear_emmc_spl.sh
#
# Salva backup dos primeiros 2MB antes de apagar.
# Após execução: desligar, inserir SD flashado, ligar → boot automático pelo SD.
#
# ATENÇÃO: requer adb root ou adb shell su (device Android desbloqueado).
# Execute adb_check.sh primeiro para verificar pré-requisitos.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# SPL fica nos primeiros setores do eMMC.
# TOC0 do MCD-125 começa no setor 16 (offset 8192).
# Apagar os primeiros 2MB (4096 setores × 512 bytes) cobre qualquer variação de offset
# e não toca nas partições Android (que ficam muito além desse ponto).
SPL_SECTORS=4096  # 2MB
BACKUP_FILE="emmc_spl_backup_device2.bin"

# ── Verificar ADB ─────────────────────────────────────────────────────────────

step "Verificando ADB"

command -v adb &>/dev/null || fail "adb não encontrado. Execute: sudo apt install adb"
ok "adb disponível"

ADB_DEVICES=$(adb devices | tail -n +2 | grep -v '^$')
[ -n "$ADB_DEVICES" ] || fail "Nenhum device ADB. Verifique cabo USB e depuração USB."

DEVICE_OK=$(echo "$ADB_DEVICES" | grep -c "device$" || true)
[ "$DEVICE_OK" -gt 0 ] || fail "Device não disponível. Execute adb_check.sh para diagnóstico."
ok "Device ADB disponível"

# ── Configurar root ───────────────────────────────────────────────────────────

step "Configurando acesso root"

ADB_ROOT_MODE=false
if adb root 2>&1 | grep -qE "restarting adbd as root|already running as root"; then
    sleep 1
    ADB_ROOT_MODE=true
    ok "adb root: adbd rodando como root"
else
    warn "adb root não disponível — tentando via su"
fi

adb_shell_root() {
    if $ADB_ROOT_MODE; then
        adb shell "$@"
    else
        adb shell su -c "$*"
    fi
}

# Confirmar root
UID_CHECK=$(adb_shell_root id 2>/dev/null | head -1 || echo "")
echo "$UID_CHECK" | grep -q "uid=0" || fail "Root não disponível: $UID_CHECK
Execute adb_check.sh para diagnóstico."
ok "Root confirmado"

# ── Verificar eMMC ────────────────────────────────────────────────────────────

step "Verificando eMMC (mmcblk2)"

EMMC_SIZE_SECTORS=$(adb_shell_root "cat /sys/block/mmcblk2/size 2>/dev/null" | tr -d '\r\n ')
[ -n "$EMMC_SIZE_SECTORS" ] && [ "$EMMC_SIZE_SECTORS" != "0" ] \
    || fail "mmcblk2 não encontrado. Execute adb_check.sh para diagnóstico."

EMMC_SIZE_MB=$(( EMMC_SIZE_SECTORS * 512 / 1024 / 1024 ))
ok "eMMC: ${EMMC_SIZE_MB}MB (${EMMC_SIZE_SECTORS} setores)"

# Sanidade: eMMC do MCD-125 deve ter ≥ 8GB
[ "$EMMC_SIZE_MB" -ge 7000 ] || warn "eMMC parece pequena (${EMMC_SIZE_MB}MB) — verifique se é o device correto"

# ── Mostrar magic atual ───────────────────────────────────────────────────────

step "Magic atual do eMMC (antes de apagar)"

echo "Setores 0–3 (primeiros 2KB):"
adb_shell_root "dd if=/dev/block/mmcblk2 bs=512 count=4 2>/dev/null | xxd" 2>/dev/null | head -16 || \
    warn "Não foi possível ler magic"

# ── Confirmação explícita ─────────────────────────────────────────────────────

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║              OPERAÇÃO DESTRUTIVA — CONFIRME              ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Esta operação irá:"
echo "  1. Salvar backup: $BACKUP_FILE (primeiros 2MB do eMMC)"
echo "  2. Apagar os primeiros 2MB do eMMC (área SPL/bootloader)"
echo "  3. O device não conseguirá mais bootar pelo eMMC"
echo "  4. Na próxima inicialização com SD Armbian inserido,"
echo "     o boot será automático pelo SD"
echo ""
echo -e "${YELLOW}NÃO apaga partições Android (dados/sistema ficam intactos)${NC}"
echo -e "${YELLOW}Rollback possível com o arquivo de backup gerado${NC}"
echo ""
read -rp "Digite YES para confirmar: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Abortado."; exit 0; }

# ── Salvar backup ─────────────────────────────────────────────────────────────

step "Salvando backup dos primeiros 2MB"

if [ -f "$BACKUP_FILE" ]; then
    warn "Arquivo $BACKUP_FILE já existe — sobrescrevendo"
fi

echo "Lendo ${SPL_SECTORS} setores (2MB) do device..."
adb exec-out "dd if=/dev/block/mmcblk2 bs=512 count=${SPL_SECTORS} 2>/dev/null" > "$BACKUP_FILE"

BACKUP_SIZE=$(wc -c < "$BACKUP_FILE")
[ "$BACKUP_SIZE" -ge $((SPL_SECTORS * 512 - 512)) ] || \
    fail "Backup incompleto: ${BACKUP_SIZE} bytes (esperado ~$((SPL_SECTORS * 512)))"

ok "Backup salvo: $BACKUP_FILE (${BACKUP_SIZE} bytes)"

# Verificar magic no backup
BACKUP_MAGIC=$(od -A n -t x1 -j 8192 -N 4 "$BACKUP_FILE" 2>/dev/null | tr -d ' \n')
if [ "$BACKUP_MAGIC" = "544f4330" ]; then
    ok "TOC0 confirmado no backup (offset 8192) — bootloader Allwinner preservado"
elif [ -n "$BACKUP_MAGIC" ]; then
    warn "Magic no backup: $BACKUP_MAGIC (esperado 544f4330/TOC0)"
else
    warn "Não foi possível verificar magic no backup"
fi

# ── Apagar área SPL ───────────────────────────────────────────────────────────

step "Apagando área SPL (primeiros 2MB)"

echo "Zerando ${SPL_SECTORS} setores no eMMC..."
adb_shell_root "dd if=/dev/zero of=/dev/block/mmcblk2 bs=512 count=${SPL_SECTORS} 2>&1" || \
    fail "Erro ao apagar área SPL"

ok "Área SPL zerada"

# ── Verificar que foi zerado ──────────────────────────────────────────────────

step "Verificando que área foi zerada"

echo "Primeiros 2KB após zerar:"
VERIFY=$(adb_shell_root "dd if=/dev/block/mmcblk2 bs=512 count=4 2>/dev/null | xxd" 2>/dev/null || echo "")
if [ -n "$VERIFY" ]; then
    echo "$VERIFY" | head -8
    # Checar se é tudo zeros
    NONZERO=$(echo "$VERIFY" | grep -v "0000 0000 0000 0000 0000 0000 0000 0000" | grep -c "^" || true)
    if [ "$NONZERO" -le 2 ]; then
        ok "Área zerada com sucesso (sem bytes não-nulos)"
    else
        warn "Alguns bytes não-nulos detectados (${NONZERO} linhas) — verifique manualmente"
    fi
else
    warn "Não foi possível verificar o resultado"
fi

# ── Instruções finais ─────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              PRÓXIMOS PASSOS                             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "1. Desligar o device (adb shell reboot -p OU desconectar energia)"
echo "2. Inserir o SD card com Armbian já flashado"
echo "3. Conectar o adaptador USB-Ethernet"
echo "4. Ligar o device → boot automático pelo SD"
echo "5. Aguardar Armbian:"
echo "   ./ssh_wait.sh <IP_DO_DEVICE>"
echo ""
echo "Backup do eMMC original: $BACKUP_FILE"
echo "Para restaurar Android:"
echo "  adb shell 'dd if=/dev/zero ...'"
echo "  OU via Armbian: dd if=/boot/emmc_uboot_backup.bin of=/dev/mmcblk2 bs=512 count=${SPL_SECTORS}"
echo ""
