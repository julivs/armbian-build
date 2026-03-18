#!/bin/bash
# ssh_wait.sh — Aguarda Armbian ficar disponível via SSH após boot pelo SD
#
# Uso: ./ssh_wait.sh <IP> [timeout_segundos]
#
# Exemplos:
#   ./ssh_wait.sh 10.10.10.38
#   ./ssh_wait.sh 10.10.10.38 180

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

IP="${1:-}"
TIMEOUT="${2:-120}"
PASS="1234"

[ -n "$IP" ] || fail "Uso: $0 <IP> [timeout_segundos]"

echo -e "${CYAN}Aguardando Armbian em ${IP} (timeout: ${TIMEOUT}s)...${NC}"
echo ""

# ── Aguardar porta 22 abrir ───────────────────────────────────────────────────

START_TIME=$(date +%s)
ELAPSED=0

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo ""
        fail "TIMEOUT após ${TIMEOUT}s — Armbian não respondeu em ${IP}:22
Verifique:
  - USB-Ethernet plugado antes do boot
  - IP correto (cheque o roteador DHCP)
  - SD card inserido e device ligado"
    fi

    # Tentar conexão na porta 22 (sem bloquear por muito tempo)
    if nc -z -w2 "$IP" 22 2>/dev/null; then
        echo ""
        ok "Porta 22 aberta em ${IP} (${ELAPSED}s)"
        break
    fi

    printf "\r  aguardando... %3ds/%ds" "$ELAPSED" "$TIMEOUT"
    sleep 3
done

# ── Confirmar que é Armbian ───────────────────────────────────────────────────

echo ""
echo "Verificando identidade do sistema..."

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=no"

# Tentar ler /etc/armbian-release
if command -v sshpass &>/dev/null; then
    ARMBIAN_RELEASE=$(sshpass -p "$PASS" ssh $SSH_OPTS root@"$IP" \
        "cat /etc/armbian-release 2>/dev/null | grep -E 'BOARD|VERSION|DISTRIBUTION'" \
        2>/dev/null || echo "")
else
    warn "sshpass não instalado — verificação de identidade limitada"
    warn "Instale: sudo apt install sshpass"
    # Tenta sem senha (caso já tenha chave configurada)
    ARMBIAN_RELEASE=$(ssh $SSH_OPTS root@"$IP" \
        "cat /etc/armbian-release 2>/dev/null | grep -E 'BOARD|VERSION|DISTRIBUTION'" \
        2>/dev/null || echo "")
fi

if [ -n "$ARMBIAN_RELEASE" ]; then
    ok "Armbian confirmado:"
    echo "$ARMBIAN_RELEASE" | sed 's/^/    /'
else
    warn "Não foi possível ler /etc/armbian-release (credenciais ou sistema diferente)"
    warn "SSH disponível em ${IP} mas identidade não confirmada"
fi

# ── Informações do sistema ────────────────────────────────────────────────────

if command -v sshpass &>/dev/null; then
    SYS_INFO=$(sshpass -p "$PASS" ssh $SSH_OPTS root@"$IP" \
        "echo \"hostname: \$(hostname)\"; echo \"kernel: \$(uname -r)\"; echo \"uptime: \$(uptime -p)\"; ip -4 addr show | grep 'inet ' | awk '{print \"ip: \" \$2}'" \
        2>/dev/null || echo "")
    if [ -n "$SYS_INFO" ]; then
        echo ""
        ok "Informações do sistema:"
        echo "$SYS_INFO" | sed 's/^/    /'
    fi
fi

# ── Resultado ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}ARMBIAN DISPONÍVEL ✓${NC}"
echo ""
echo "SSH: ssh root@${IP}  (senha padrão: 1234)"
echo ""
echo "Próximo passo:"
echo "  ./ssh_first_setup.sh ${IP} <nova_senha> <novo_hostname>"
echo -e "${CYAN}══════════════════════════════════════════${NC}"
