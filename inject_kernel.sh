#!/bin/bash
# inject_kernel.sh — Injeta o kernel e DTB mais recentes na imagem SD existente.
# Execute a partir do diretório armbian-build/:
#   bash inject_kernel.sh
set -e

IMG=$(ls -t output/images/Armbian-unofficial_*_Tomate-mcd125_*_minimal.img 2>/dev/null | head -1)
KERNEL_DEB=$(ls -t output/debs/linux-image-current-sunxi64_*.deb 2>/dev/null | head -1)
DTB_DEB=$(ls -t output/debs/linux-dtb-current-sunxi64_*.deb 2>/dev/null | head -1)

[ -z "$IMG" ]        && { echo "ERRO: nenhuma imagem encontrada em output/images/"; exit 1; }
[ -z "$KERNEL_DEB" ] && { echo "ERRO: nenhum linux-image deb encontrado"; exit 1; }
[ -z "$DTB_DEB" ]    && { echo "ERRO: nenhum linux-dtb deb encontrado"; exit 1; }

# Extrai versão do kernel a partir do nome do deb (ex: linux-image-current-sunxi64_6.12.77-S...)
VER=$(dpkg-deb --fsys-tarfile "$KERNEL_DEB" | tar -t | grep "^./boot/vmlinuz-" | head -1 | sed 's|./boot/vmlinuz-||')

echo "[inject] Imagem : $(basename "$IMG")"
echo "[inject] Kernel : $(basename "$KERNEL_DEB")"
echo "[inject] DTB    : $(basename "$DTB_DEB")"
echo "[inject] VER    : $VER"
[ -z "$VER" ] && { echo "ERRO: nao foi possivel detectar versao do kernel no deb"; exit 1; }

MNT=$(mktemp -d)
EXTRACT_DIR=/tmp/inject_extract
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

echo "[inject] Montando $IMG em $MNT..."
sudo mount -o loop,offset=$((8192*512)) "$IMG" "$MNT"

echo "[inject] Extraindo vmlinuz do kernel deb..."
dpkg-deb --fsys-tarfile "$KERNEL_DEB" | tar -xv \
    -C "$EXTRACT_DIR" \
    "./boot/vmlinuz-${VER}"
echo "[inject] Conteudo de EXTRACT_DIR/boot:"
ls -la "$EXTRACT_DIR/boot/" 2>/dev/null || echo "  VAZIO"
sudo cp -v "$EXTRACT_DIR/boot/vmlinuz-${VER}" "$MNT/boot/"

echo "[inject] Instalando DTBs..."
dpkg-deb --fsys-tarfile "$DTB_DEB" | sudo tar -x \
    --wildcards './boot/dtb*' \
    -C "$MNT"

rm -rf "$EXTRACT_DIR"

echo "[inject] Verificando arquivos instalados:"
ls -la "$MNT/boot/vmlinuz"* 2>/dev/null || echo "  AVISO: vmlinuz nao encontrado"
find "$MNT/boot" -name "sun50i-h313-tomate-mcd125.dtb" 2>/dev/null | head -1 | xargs ls -la 2>/dev/null || echo "  AVISO: DTB nao encontrado"

sudo umount "$MNT"
rmdir "$MNT"
echo "[inject] Concluido. Grave o .img no SD e reinicie."
