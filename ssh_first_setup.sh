#!/bin/bash
# ssh_first_setup.sh — Setup inicial do Armbian via SSH (sem interação)
#
# Equivale ao wizard do primeiro boot Armbian, executado remotamente.
#
# Uso: ./ssh_first_setup.sh <IP> [nova_senha] [novo_hostname]
#
# Exemplos:
#   ./ssh_first_setup.sh 10.10.10.38
#   ./ssh_first_setup.sh 10.10.10.38 minhaSenha
#   ./ssh_first_setup.sh 10.10.10.38 minhaSenha tomate-mcd125-2

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

IP="${1:-}"
NEW_PASS="${2:-}"
NEW_HOSTNAME="${3:-}"
DEFAULT_PASS="1234"

[ -n "$IP" ] || fail "Uso: $0 <IP> [nova_senha] [novo_hostname]"

# Se nova senha não informada, usar padrão (apenas primeiros acessos)
if [ -z "$NEW_PASS" ]; then
    warn "Senha não informada — mantendo senha padrão '1234'"
    warn "Recomendado: $0 $IP <nova_senha> [hostname]"
    NEW_PASS="$DEFAULT_PASS"
    CHANGE_PASS=false
else
    CHANGE_PASS=true
fi

# Verificar sshpass
if ! command -v sshpass &>/dev/null; then
    fail "sshpass não encontrado. Instale: sudo apt install sshpass"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=no"

# Função para executar comando remoto com senha atual
ssh_run() {
    sshpass -p "$CURRENT_PASS" ssh $SSH_OPTS root@"$IP" "$@"
}

CURRENT_PASS="$DEFAULT_PASS"

# ── Verificar conectividade ───────────────────────────────────────────────────

step "Verificando conectividade SSH"

if ! nc -z -w5 "$IP" 22 2>/dev/null; then
    fail "Porta 22 não acessível em ${IP}. Execute ssh_wait.sh primeiro."
fi

# Testar autenticação com senha padrão
if ! sshpass -p "$DEFAULT_PASS" ssh $SSH_OPTS root@"$IP" "true" 2>/dev/null; then
    # Tentar com a nova senha (já configurada anteriormente)
    if [ "$NEW_PASS" != "$DEFAULT_PASS" ] && \
       sshpass -p "$NEW_PASS" ssh $SSH_OPTS root@"$IP" "true" 2>/dev/null; then
        warn "Senha padrão '1234' não funciona — usando nova senha informada"
        CURRENT_PASS="$NEW_PASS"
        CHANGE_PASS=false  # já está com a senha correta
    else
        fail "Autenticação falhou. Verifique a senha ou use chave SSH."
    fi
fi

ok "Autenticação SSH OK (${IP})"

# ── Desativar wizard de primeiro boot ─────────────────────────────────────────

step "Desativando wizard de primeiro boot Armbian"

# Armbian verifica /root/.not_logged_in_yet — se existir, exibe wizard
# Remover ou criar .bash_profile temporário para pular o wizard
ssh_run "rm -f /root/.not_logged_in_yet 2>/dev/null; true"
ok "Wizard de primeiro boot desativado"

# ── Mudar senha root ──────────────────────────────────────────────────────────

if $CHANGE_PASS; then
    step "Alterando senha root"
    ssh_run "echo 'root:${NEW_PASS}' | chpasswd"
    ok "Senha root alterada"
    CURRENT_PASS="$NEW_PASS"
fi

# ── Mudar hostname ────────────────────────────────────────────────────────────

if [ -n "$NEW_HOSTNAME" ]; then
    step "Configurando hostname: $NEW_HOSTNAME"
    ssh_run "hostnamectl set-hostname '${NEW_HOSTNAME}'"
    # Atualizar /etc/hosts
    ssh_run "sed -i 's/127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/' /etc/hosts || \
             echo '127.0.1.1\t${NEW_HOSTNAME}' >> /etc/hosts"
    ok "Hostname configurado: $NEW_HOSTNAME"
fi

# ── Instalar chave SSH pública ────────────────────────────────────────────────

step "Configurando chave SSH"

# Verificar se há chave pública disponível
PUB_KEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [ -f "$key_file" ]; then
        PUB_KEY=$(cat "$key_file")
        ok "Chave pública encontrada: $key_file"
        break
    fi
done

if [ -n "$PUB_KEY" ]; then
    ssh_run "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    ssh_run "echo '${PUB_KEY}' >> /root/.ssh/authorized_keys"
    ssh_run "chmod 600 /root/.ssh/authorized_keys"
    ok "Chave pública instalada — próximos acessos sem senha"
else
    warn "Nenhuma chave pública encontrada em ~/.ssh/ — acesso futuro requer senha"
fi

# ── Informações do sistema ────────────────────────────────────────────────────

step "Estado do sistema"

SYS_INFO=$(ssh_run "
echo \"=== Hostname ===\"
hostname
echo \"=== Kernel ===\"
uname -r
echo \"=== Uptime ===\"
uptime
echo \"=== IPs ===\"
ip -4 addr show | grep 'inet ' | awk '{print \$2, \$NF}'
echo \"=== Armbian ===\"
cat /etc/armbian-release 2>/dev/null | grep -E 'BOARD|VERSION|DISTRIBUTION' || echo 'N/A'
echo \"=== Disco ===\"
df -h / | tail -1
echo \"=== eMMC ===\"
lsblk -d /dev/mmcblk2 2>/dev/null || echo 'mmcblk2 não detectado'
" 2>/dev/null)

echo "$SYS_INFO"

# ── Resumo e próximos passos ──────────────────────────────────────────────────

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              SETUP INICIAL CONCLUÍDO ✓                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Acesso SSH:"
if [ -n "$PUB_KEY" ]; then
    echo "  ssh root@${IP}  (sem senha — chave instalada)"
else
    echo "  ssh root@${IP}  (senha: ${NEW_PASS})"
fi
echo ""
echo "Próximos passos:"
echo ""
echo "  1. Instalar Armbian no eMMC:"
echo "     ssh root@${IP} armbian-install"
echo ""
echo "  2. Configurar /home e /var no eMMC:"
echo "     scp setup_emmc_data.sh root@${IP}:/root/"
echo "     ssh root@${IP} bash /root/setup_emmc_data.sh --yes"
echo ""
echo "  3. Reboot manual e remover SD:"
echo "     ssh root@${IP} reboot"
echo ""
