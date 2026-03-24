#!/bin/bash
# check_build.sh — Verifica se o build mais recente contém as modificações esperadas.
# Sempre rodar após compile.sh build antes de gravar no SD.
#
# Verificações:
#   1. DTB: descompila e procura propriedades e UUID da versão atual do DTS
#   2. vmlinuz: procura UUIDs dos arquivos C modificados via strings
#   3. Consistência: imagem mais nova que os .deb

DEBS_DIR="output/debs"
PASS=0
FAIL=0

ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
fail() { echo "  [!!]  $*"; FAIL=$((FAIL+1)); }

# ── Localiza artefatos mais recentes ─────────────────────────────────────────
KERNEL_DEB=$(ls -t "$DEBS_DIR"/linux-image-current-sunxi64_*.deb 2>/dev/null | head -1)
DTB_DEB=$(ls -t "$DEBS_DIR"/linux-dtb-current-sunxi64_*.deb 2>/dev/null | head -1)
IMG=$(ls -t output/images/Armbian-unofficial_*_Tomate-mcd125_*_minimal.img 2>/dev/null | head -1)

[ -z "$KERNEL_DEB" ] && { echo "ERRO: nenhum linux-image deb encontrado em $DEBS_DIR"; exit 1; }
[ -z "$DTB_DEB"    ] && { echo "ERRO: nenhum linux-dtb deb encontrado em $DEBS_DIR"; exit 1; }

echo "========================================"
echo " check_build — $(date '+%Y-%m-%d %H:%M')"
echo "========================================"
echo "  kernel : $(basename "$KERNEL_DEB")"
echo "           $(stat -c '%y' "$KERNEL_DEB" | cut -d. -f1)"
echo "  dtb    : $(basename "$DTB_DEB")"
echo "           $(stat -c '%y' "$DTB_DEB" | cut -d. -f1)"
[ -n "$IMG" ] && echo "  imagem : $(basename "$IMG")" && echo "           $(stat -c '%y' "$IMG" | cut -d. -f1)"
echo ""

# ── [1] DTB — descompila e verifica ──────────────────────────────────────────
echo "── [1] DTB: sun50i-h313-tomate-mcd125 ──"
DTB_TMP=$(mktemp /tmp/mcd125_XXXXXX.dtb)
DTB_PATH=$(dpkg-deb --fsys-tarfile "$DTB_DEB" | tar -t | grep "sun50i-h313-tomate-mcd125.dtb" | head -1)
dpkg-deb --fsys-tarfile "$DTB_DEB" \
    | tar -xO "$DTB_PATH" > "$DTB_TMP" 2>/dev/null

# UUID da versão atual do DTS
DTS_UUID="MCD125-DTS-v7-emac1-intphy"
if strings "$DTB_TMP" | grep -q "$DTS_UUID"; then
    ok "UUID DTS presente: $DTS_UUID"
else
    fail "UUID DTS ausente: $DTS_UUID  ← DTS não compilado ou desatualizado"
fi

# Propriedades funcionais (descompila se dtc disponível, senão via strings)
if command -v dtc &>/dev/null; then
    DTS_TMP=$(mktemp /tmp/mcd125_XXXXXX.dts)
    dtc -I dtb -O dts -o "$DTS_TMP" "$DTB_TMP" 2>/dev/null
    CHECK_SOURCE="$DTS_TMP"
    CHECK_CMD="grep -q"
else
    CHECK_SOURCE="$DTB_TMP"
    CHECK_CMD="strings \"$DTB_TMP\" | grep -q"
    DTS_TMP=""
fi

for KEY in "use-internal-phy" "emac-25m"; do
    if grep -q "$KEY" "$CHECK_SOURCE" 2>/dev/null || strings "$DTB_TMP" | grep -q "$KEY"; then
        ok "DTS: '$KEY' presente"
    else
        fail "DTS: '$KEY' ausente — DTS v7 não aplicado?"
    fi
done

[ -n "$DTS_TMP" ] && rm -f "$DTS_TMP"
rm -f "$DTB_TMP"
echo ""

# ── [2] vmlinuz — UUIDs dos arquivos C modificados ───────────────────────────
echo "── [2] vmlinuz: arquivos C modificados ──"
VMLINUZ_STRINGS=$(dpkg-deb --fsys-tarfile "$KERNEL_DEB" \
    | tar -xO ./boot/vmlinuz-* 2>/dev/null \
    | strings)

# sunxi-gmac.c — debug prints (userpatches/kernel/archive/sunxi-6.12/)
GMAC_UUID="MCD125-GMAC-DEBUG-a3f9"
if echo "$VMLINUZ_STRINGS" | grep -q "$GMAC_UUID"; then
    ok "sunxi-gmac.c UUID: $GMAC_UUID"
else
    fail "sunxi-gmac.c UUID ausente: $GMAC_UUID  ← patch de debug não compilado"
fi

# Placeholder para próximos arquivos C modificados:
# Adicione aqui novas entradas no formato:
#   ARQUIVO_UUID="MCD125-MODULO-TAG-xxxx"
#   if echo "$VMLINUZ_STRINGS" | grep -q "$ARQUIVO_UUID"; then
#       ok "arquivo.c UUID: $ARQUIVO_UUID"
#   else
#       fail "arquivo.c UUID ausente: $ARQUIVO_UUID"
#   fi
echo ""

# ── [3] Consistência temporal ─────────────────────────────────────────────────
echo "── [3] Consistência temporal ──"
if [ -n "$IMG" ]; then
    IMG_TIME=$(stat -c '%Y' "$IMG")
    KERN_TIME=$(stat -c '%Y' "$KERNEL_DEB")
    if [ "$IMG_TIME" -ge "$KERN_TIME" ]; then
        ok "Imagem mais nova que o kernel deb"
    else
        fail "Imagem mais antiga que o kernel deb — rode compile.sh build para atualizar"
    fi
else
    fail "Nenhuma imagem minimal encontrada"
fi
echo ""

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "========================================"
echo " Resultado: $PASS OK, $FAIL FALHA(s)"
echo "========================================"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
