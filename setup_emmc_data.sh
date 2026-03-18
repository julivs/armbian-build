#!/bin/bash
# setup_emmc_data.sh — Configura eMMC como partição de dados persistentes
#
# Estratégia:
#   SD card  → rootfs (leitura, protege ciclos de escrita)
#   eMMC p1  → /home, /var (escrita)
#   tmpfs    → /tmp (RAM, zero escrita em disco)
#
# Executar NO DISPOSITIVO como root, com SD bootado.
# Requer que a eMMC (mmcblk2) esteja disponível.
#
# Uso: bash setup_emmc_data.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

NON_INTERACTIVE=false
[[ "${1:-}" == "--yes" ]] && NON_INTERACTIVE=true

EMMC_DEV="/dev/mmcblk2"
EMMC_PART="${EMMC_DEV}p1"
DATA_MOUNT="/data"

# ── Pré-checks ───────────────────────────────────────────────────────────────

step "Verificando pré-requisitos"

[ "$(id -u)" -eq 0 ] || fail "Execute como root"
[ -b "$EMMC_DEV" ]   || fail "eMMC $EMMC_DEV não encontrada"

# Confirmar que não estamos rodando da eMMC
ROOT_DEV=$(findmnt -n -o SOURCE /)
if echo "$ROOT_DEV" | grep -q "mmcblk2"; then
    fail "Root filesystem está na eMMC! Este script deve ser executado com root no SD."
fi
ok "Root está no SD: $ROOT_DEV"

# Verificar espaço no SD para continuar operando
SD_AVAIL=$(df / --output=avail | tail -1)
[ "$SD_AVAIL" -gt $((500 * 1024)) ] || warn "SD com menos de 500MB livre"

echo ""
echo "Configuração planejada:"
echo "  eMMC ($EMMC_PART) → $DATA_MOUNT"
echo "  /home  → bind de $DATA_MOUNT/home"
echo "  /var   → bind de $DATA_MOUNT/var"
echo "  /tmp   → tmpfs (RAM, 256MB)"
echo ""
echo -e "${YELLOW}ATENÇÃO: A eMMC será formatada. Todo conteúdo atual será apagado.${NC}"
echo ""
if $NON_INTERACTIVE; then
    CONFIRM="s"
    warn "Modo não-interativo (--yes): confirmação automática"
else
    read -rp "Continuar? [s/N] " CONFIRM
fi
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Abortado."; exit 0; }

# ── Formatar eMMC ────────────────────────────────────────────────────────────

step "Formatando eMMC"

# Desmontar se estiver montada
if mountpoint -q "$EMMC_PART" 2>/dev/null || grep -q "$EMMC_PART" /proc/mounts; then
    umount "$EMMC_PART" || warn "Não foi possível desmontar $EMMC_PART — continuando"
fi

mkfs.ext4 -F -L armbian-data "$EMMC_PART"
ok "eMMC formatada como ext4 (label: armbian-data)"

# ── Montar e criar estrutura ─────────────────────────────────────────────────

step "Criando estrutura de diretórios na eMMC"

mkdir -p "$DATA_MOUNT"
mount "$EMMC_PART" "$DATA_MOUNT"

mkdir -p "$DATA_MOUNT/home"
mkdir -p "$DATA_MOUNT/var"
ok "Estrutura criada: $DATA_MOUNT/{home,var}"

# ── Migrar /home ─────────────────────────────────────────────────────────────

step "Migrando /home para eMMC"

if [ -d /home ] && [ "$(ls -A /home)" ]; then
    cp -a /home/. "$DATA_MOUNT/home/"
    ok "Conteúdo de /home copiado"
else
    ok "/home vazio — nada a migrar"
fi

# ── Migrar /var ──────────────────────────────────────────────────────────────

step "Migrando /var para eMMC"

# Parar serviços que escrevem em /var para garantir consistência
warn "Parando serviços antes de migrar /var..."
systemctl stop rsyslog 2>/dev/null || true
systemctl stop cron    2>/dev/null || true
systemctl stop syslog  2>/dev/null || true

cp -a /var/. "$DATA_MOUNT/var/"
ok "Conteúdo de /var copiado"

# Reiniciar serviços (rodam do /var original até o próximo boot)
systemctl start rsyslog 2>/dev/null || true
systemctl start cron    2>/dev/null || true

# ── Atualizar fstab ──────────────────────────────────────────────────────────

step "Configurando /etc/fstab"

UUID=$(blkid -s UUID -o value "$EMMC_PART")
[ -n "$UUID" ] || fail "Não foi possível obter UUID de $EMMC_PART"
ok "UUID da eMMC: $UUID"

# Backup do fstab atual
cp /etc/fstab /etc/fstab.bak
ok "Backup: /etc/fstab.bak"

# Remover entradas antigas relacionadas à eMMC (se houver)
sed -i '/mmcblk2/d' /etc/fstab
sed -i '/armbian-data/d' /etc/fstab

# Adicionar novas entradas
cat >> /etc/fstab << EOF

# eMMC como armazenamento persistente (dados do usuário)
UUID=$UUID $DATA_MOUNT ext4 defaults,noatime,nofail 0 2
$DATA_MOUNT/home /home none bind,x-systemd.requires-mounts-for=$DATA_MOUNT 0 0
$DATA_MOUNT/var  /var  none bind,x-systemd.requires-mounts-for=$DATA_MOUNT 0 0

# /tmp em RAM (protege SD de escritas)
tmpfs /tmp tmpfs defaults,size=256M,noatime 0 0
EOF

ok "fstab atualizado"
echo ""
cat /etc/fstab
echo ""

# ── Verificar ────────────────────────────────────────────────────────────────

step "Verificação"

ok "eMMC montada em $DATA_MOUNT:"
df -h "$DATA_MOUNT"

echo ""
ok "Conteúdo de $DATA_MOUNT:"
ls -la "$DATA_MOUNT/"

# ── Instruções finais ────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}=== Pronto ===${NC}"
echo ""
echo "Após o reboot:"
echo "  /home → eMMC (mmcblk2p1)"
echo "  /var  → eMMC (mmcblk2p1)"
echo "  /tmp  → RAM (tmpfs, máx 256MB)"
echo "  rootfs (/) → SD card (leitura)"
echo ""
echo "Verificar após reboot:"
echo "  findmnt /home   # deve mostrar mmcblk2p1"
echo "  findmnt /var    # deve mostrar mmcblk2p1"
echo "  findmnt /tmp    # deve mostrar tmpfs"
echo ""
if $NON_INTERACTIVE; then
    echo -e "${YELLOW}Modo não-interativo: reboot não automático.${NC}"
    echo "Execute manualmente: reboot"
else
    echo -e "${YELLOW}Rebootando em 5 segundos... Ctrl+C para cancelar.${NC}"
    for i in 5 4 3 2 1; do echo -n "$i "; sleep 1; done
    echo ""
    reboot
fi
