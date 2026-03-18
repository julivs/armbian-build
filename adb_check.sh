#!/bin/bash
# adb_check.sh — Verifica pré-requisitos ADB antes de operar no eMMC
#
# Uso: ./adb_check.sh
#
# Verifica ADB + root + layout eMMC e emite go/no-go para adb_clear_emmc_spl.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

RESULT=0

# ── ADB disponível ────────────────────────────────────────────────────────────

step "Verificando ADB"

if ! command -v adb &>/dev/null; then
    fail "adb não encontrado. Instale: sudo apt install adb"
    exit 1
fi
ok "adb encontrado: $(adb version | head -1)"

# ── Device conectado ──────────────────────────────────────────────────────────

step "Verificando device USB"

ADB_DEVICES=$(adb devices | tail -n +2 | grep -v '^$')

if [ -z "$ADB_DEVICES" ]; then
    fail "Nenhum device ADB detectado. Verifique cabo USB e depuração USB ativada."
    exit 1
fi

echo "Devices encontrados:"
echo "$ADB_DEVICES"
echo ""

# Verificar se há device autorizado (não offline/unauthorized)
if echo "$ADB_DEVICES" | grep -q "unauthorized"; then
    fail "Device não autorizado — aceite o prompt no dispositivo Android."
    RESULT=1
fi

if echo "$ADB_DEVICES" | grep -q "offline"; then
    fail "Device offline — reconecte o cabo USB."
    RESULT=1
fi

DEVICE_COUNT=$(echo "$ADB_DEVICES" | grep -c "device$" || true)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    fail "Nenhum device disponível."
    exit 1
elif [ "$DEVICE_COUNT" -gt 1 ]; then
    warn "Múltiplos devices conectados — usando o primeiro."
fi

ok "Device ADB disponível"

# ── Verificar root ────────────────────────────────────────────────────────────

step "Verificando acesso root"

# Tentar adb root primeiro (funciona em eng/userdebug builds)
ADB_ROOT_MODE=false
if adb root 2>&1 | grep -qE "restarting adbd as root|already running as root"; then
    sleep 1
    ADB_ROOT_MODE=true
    ok "adb root: adbd rodando como root"
fi

# Wrapper para executar comandos com root
adb_shell_root() {
    if $ADB_ROOT_MODE; then
        adb shell "$@"
    else
        adb shell su -c "$*"
    fi
}

# Verificar uid
UID_CHECK=$(adb_shell_root id 2>/dev/null | head -1 || echo "")
if echo "$UID_CHECK" | grep -q "uid=0"; then
    ok "Root confirmado: $UID_CHECK"
else
    fail "Root NÃO disponível. uid obtido: ${UID_CHECK:-<vazio>}"
    fail "Necessário: adb root (eng build) OU adb shell su (desbloqueado)"
    RESULT=1
fi

# ── Block devices disponíveis ─────────────────────────────────────────────────

step "Listando block devices"

BLOCK_DEVS=$(adb_shell_root "ls /dev/block/mmcblk* 2>/dev/null" || echo "")
if [ -z "$BLOCK_DEVS" ]; then
    fail "Nenhum mmcblk encontrado em /dev/block/"
    RESULT=1
else
    echo "$BLOCK_DEVS"
    ok "Block devices encontrados"
fi

# ── Verificar eMMC (mmcblk2) ──────────────────────────────────────────────────

step "Verificando eMMC (mmcblk2)"

EMMC_SIZE_SECTORS=$(adb_shell_root "cat /sys/block/mmcblk2/size 2>/dev/null" || echo "0")
EMMC_SIZE_SECTORS=$(echo "$EMMC_SIZE_SECTORS" | tr -d '\r\n ')

if [ -z "$EMMC_SIZE_SECTORS" ] || [ "$EMMC_SIZE_SECTORS" = "0" ]; then
    fail "mmcblk2 não encontrado ou inacessível"
    RESULT=1
else
    EMMC_SIZE_MB=$(( EMMC_SIZE_SECTORS * 512 / 1024 / 1024 ))
    EMMC_SIZE_GB=$(( EMMC_SIZE_MB / 1024 ))
    ok "eMMC mmcblk2: ${EMMC_SIZE_SECTORS} setores = ${EMMC_SIZE_MB}MB (~${EMMC_SIZE_GB}GB)"
fi

# ── Ler magic dos primeiros setores ──────────────────────────────────────────

step "Lendo magic do bootloader no eMMC"

echo "Primeiros 2KB do eMMC (mmcblk2):"
RAW_HEX=$(adb_shell_root "dd if=/dev/block/mmcblk2 bs=512 count=4 2>/dev/null | xxd" 2>/dev/null || echo "")
if [ -n "$RAW_HEX" ]; then
    echo "$RAW_HEX" | head -20
else
    warn "Não foi possível ler os primeiros setores do eMMC"
    RESULT=1
fi

# Verificar magic conhecido
# TOC0: 544f4330 no offset 8192 (setor 16)
echo ""
echo "Verificando magic nos setores 0 e 16:"

MAGIC_S0=$(adb_shell_root "dd if=/dev/block/mmcblk2 bs=512 count=1 skip=0 2>/dev/null | xxd | head -1" 2>/dev/null || echo "")
MAGIC_S16=$(adb_shell_root "dd if=/dev/block/mmcblk2 bs=512 count=1 skip=16 2>/dev/null | xxd | head -1" 2>/dev/null || echo "")

echo "  Setor 0  (offset 0):    ${MAGIC_S0:-<ilegível>}"
echo "  Setor 16 (offset 8192): ${MAGIC_S16:-<ilegível>}"

if echo "$MAGIC_S16" | grep -qi "544f4330\|T O C 0\|TOC0"; then
    ok "TOC0 detectado no setor 16 — bootloader Allwinner presente"
elif echo "$MAGIC_S0" | grep -qi "4547 4f4e\|eGON"; then
    ok "eGON detectado no setor 0 — bootloader Allwinner presente"
else
    warn "Magic não reconhecido — pode ser Android puro ou eMMC corrompida"
fi

# ── Partições eMMC ────────────────────────────────────────────────────────────

step "Partições do eMMC"

PARTITIONS=$(adb_shell_root "cat /proc/partitions | grep mmcblk2" 2>/dev/null || echo "")
if [ -n "$PARTITIONS" ]; then
    echo "$PARTITIONS"
else
    warn "Não foi possível listar partições de mmcblk2"
fi

# ── Resultado final ───────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}══════════════════════════════════════════${NC}"
if [ "$RESULT" -eq 0 ]; then
    echo -e "${GREEN}RESULTADO: GO ✓${NC}"
    echo ""
    echo "Todos os pré-requisitos OK."
    echo "Próximo passo: ./adb_clear_emmc_spl.sh"
else
    echo -e "${RED}RESULTADO: NO-GO ✗${NC}"
    echo ""
    echo "Corrija os erros acima antes de continuar."
fi
echo -e "${CYAN}══════════════════════════════════════════${NC}"

exit "$RESULT"
