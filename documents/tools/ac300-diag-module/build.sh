#!/bin/bash
# build.sh — Compila módulo kernel para Android k4.9.170 arm64 (MCD-125/H313)
#
# Pré-requisito: android-k49-full em KDIR (ver README.md para setup inicial)
# Uso: ./build.sh [clean]

set -e

KDIR="${KDIR:-/home/$(logname)/android-k49-full}"
CROSS="aarch64-linux-gnu-"
MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="$(basename "$MODULE_DIR")"

# Verifica pré-requisitos
if [ ! -f "$KDIR/include/generated/utsrelease.h" ]; then
    echo "ERRO: KDIR=$KDIR não tem headers preparados."
    echo "Execute primeiro: (ver README.md — Setup do android-k49-full)"
    exit 1
fi

# Verifica vermagic esperado
UTS=$(grep UTS_RELEASE "$KDIR/include/generated/utsrelease.h" | cut -d'"' -f2)
EXPECTED="4.9.170"
if [ "$UTS" != "$EXPECTED" ]; then
    echo "AVISO: UTS_RELEASE='$UTS' esperado '$EXPECTED'"
    echo "       Verifique SUBLEVEL no $KDIR/Makefile (deve ser 170)"
fi

# Copia Module.symvers local para o KDIR (CRCs corretos do dispositivo)
cp "$MODULE_DIR/Module.symvers" "$KDIR/Module.symvers"

if [ "$1" = "clean" ]; then
    make -C "$KDIR" M="$MODULE_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" clean
    echo "Limpo."
    exit 0
fi

# Compila
make -C "$KDIR" M="$MODULE_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" \
    KBUILD_MODPOST_WARN=1 modules

# Verifica resultado
KO="$MODULE_DIR/$(ls "$MODULE_DIR"/*.ko 2>/dev/null | head -1 | xargs basename 2>/dev/null)"
if [ ! -f "$KO" ]; then
    echo "ERRO: nenhum .ko gerado."
    exit 1
fi

echo ""
echo "=== Build OK: $(basename $KO) ==="

# Verifica vermagic no módulo gerado
VMAGIC=$(python3 -c "
import struct, sys
data = open('$KO','rb').read()
idx = data.find(b'vermagic=')
if idx >= 0:
    print(data[idx:idx+80].split(b'\x00')[0].decode())
")
echo "  $VMAGIC"

# Verifica seção .plt
HAS_PLT=$(aarch64-linux-gnu-readelf -S "$KO" 2>/dev/null | grep -c "\.plt" || true)
if [ "$HAS_PLT" -eq 0 ]; then
    echo "  AVISO: .plt section ausente — módulo FALHARÁ com 'module PLT section missing'"
else
    echo "  .plt section: OK"
fi

# Verifica __versions
N_VERS=$(python3 -c "
import struct
data = open('$KO','rb').read()
e_shoff = struct.unpack_from('<Q', data, 40)[0]
e_shentsize = struct.unpack_from('<H', data, 58)[0]
e_shnum = struct.unpack_from('<H', data, 60)[0]
e_shstrndx = struct.unpack_from('<H', data, 62)[0]
sh_off_str = e_shoff + e_shstrndx * e_shentsize
sh_offset_str = struct.unpack_from('<Q', data, sh_off_str + 24)[0]
sh_size_str = struct.unpack_from('<Q', data, sh_off_str + 32)[0]
strtab = data[sh_offset_str:sh_offset_str + sh_size_str]
for i in range(e_shnum):
    sh_off = e_shoff + i * e_shentsize
    sh_name = struct.unpack_from('<I', data, sh_off)[0]
    name = strtab[sh_name:sh_name+32].split(b'\x00')[0].decode('ascii','replace')
    if name == '__versions':
        sh_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
        print(sh_size // 64)
        break
")
echo "  __versions: $N_VERS entradas"

echo ""
echo "=== Deploy para dispositivo Android ==="
echo "  adb push $KO /data/local/tmp/"
echo "  adb shell su -c 'insmod /data/local/tmp/$(basename $KO)'"
echo "  adb shell su -c 'dmesg | grep <SEU_PREFIX>'"
