# Módulos de diagnóstico para Android k4.9 arm64 (MCD-125 / H313)

Guia completo para compilar e carregar módulos kernel no Android k4.9.170
do Allwinner H313. Documenta todos os obstáculos encontrados e suas soluções.

---

## Contexto

O dispositivo Android (MCD-125) roda kernel **4.9.170** (arm64).
`/dev/mem` não está disponível (`CONFIG_DEVMEM=n`).
A única forma de ler registradores MMIO diretamente é via módulo kernel.
`CONFIG_MODULE_FORCE_LOAD=n` → não é possível fazer force-load; o módulo
precisa combinar **exatamente** com o kernel em execução.

---

## Pré-requisitos

### 1. Toolchain aarch64

```bash
sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
```

### 2. Clone do android-k49-full (setup único, ~300MB)

```bash
cd ~
git clone --depth=1 -b experimental/android-4.9 \
    https://android.googlesource.com/kernel/common \
    android-k49-full

# Fix de build para GCC 10+ (yylloc duplicate definition)
sed -i 's/^YYLTYPE yylloc;$/extern YYLTYPE yylloc;/' \
    ~/android-k49-full/scripts/dtc/dtc-lexer.lex.c_shipped

# Corrigir SUBLEVEL para combinar com o kernel do dispositivo
# O clone tem SUBLEVEL=0; o device roda 4.9.170
sed -i 's/^SUBLEVEL = 0$/SUBLEVEL = 170/' ~/android-k49-full/Makefile

# Suprimir hash git no vermagic (gera string limpa "4.9.170")
echo "" > ~/android-k49-full/.scmversion

# Preparar headers (gera include/generated/utsrelease.h, etc.)
make -C ~/android-k49-full ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- modules_prepare
```

**Verificar resultado:**
```bash
grep UTS_RELEASE ~/android-k49-full/include/generated/utsrelease.h
# Deve mostrar: #define UTS_RELEASE "4.9.170"
```

### 3. Copiar Module.symvers

O arquivo `Module.symvers` deste diretório contém os CRCs corretos extraídos
dos módulos do próprio dispositivo. Ele é copiado automaticamente pelo `build.sh`.

**Nunca use o `Module.symvers` gerado por `modules_prepare`** — ele fica vazio
porque `modules_prepare` não compila o kernel. O arquivo deste repositório
contém os CRCs reais.

---

## Build rápido

```bash
cd documents/tools/ac300-diag-module/
chmod +x build.sh
./build.sh
```

Para limpar:
```bash
./build.sh clean
```

Build manual equivalente:
```bash
KDIR=~/android-k49-full
cp Module.symvers $KDIR/Module.symvers
make -C $KDIR M=$(pwd) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    KBUILD_MODPOST_WARN=1 modules
```

---

## Deploy e execução

```bash
# Enviar para o dispositivo
adb push ac300_diag.ko /data/local/tmp/

# Carregar (retorna "Try again" = EAGAIN = sucesso — módulo se descarrega automaticamente)
adb shell su -c 'insmod /data/local/tmp/ac300_diag.ko'

# Ler output
adb shell su -c 'dmesg | grep AC300'
```

> `insmod: failed to load ...: Try again` **é o comportamento correto**.
> O módulo retorna `-EAGAIN` no init para se descarregar automaticamente após imprimir.

---

## Obstáculos críticos e soluções

### 1. `ENOEXEC` — "Exec format error"

**Causa mais comum:** vermagic não corresponde ao kernel do dispositivo.

O vermagic do k4.9.170 arm64 é exatamente:
```
4.9.170 SMP preempt mod_unload modversions aarch64
```

Verificar o vermagic de um módulo do dispositivo:
```bash
# Puxar um módulo do dispositivo
adb shell "su -c 'cat /vendor/modules/xr819.ko'" > /tmp/xr819.ko

python3 -c "
import struct
data = open('/tmp/xr819.ko','rb').read()
# ... (ver script extract_crcs.py)
"
```

**Solução:** verificar que `SUBLEVEL=170` está no Makefile do android-k49-full
e que `.scmversion` está vazio.

### 2. `module PLT section missing` → ENOEXEC

**Causa:** k4.9 arm64 requer seção `.plt` no módulo (para branch trampolines).
GCC/ld modernos não geram essa seção automaticamente para módulos simples.

**Solução:** adicionar no início do módulo C:
```c
/* k4.9 arm64 module loader requer .plt section */
asm(".section .plt,\"ax\"\n\t.byte 0\n\t.previous\n\t");
```

Verificar:
```bash
aarch64-linux-gnu-readelf -S modulo.ko | grep plt
# Deve mostrar: [ N] .plt  PROGBITS ...
```

### 3. Kernel panic ao carregar — pgprot errado no `__ioremap`

**Causa:** `PROT_DEVICE_nGnRE` em k4.9 arm64 = `0x00e8000000000707`.
Qualquer valor errado causa fault de MMU no primeiro acesso MMIO → kernel panic → reboot.

**Solução:** incluir `<asm/pgtable-prot.h>` (não `<asm/io.h>`) e usar a constante:
```c
#include <asm/pgtable-prot.h>
#define MY_IOREMAP(addr, size) \
    __ioremap((addr), (size), __pgprot(PROT_DEVICE_nGnRE))
```

**Nunca hardcodar** um valor numérico para pgprot.

### 4. CRCs incorretos → ENOEXEC (check_version falha)

**Causa:** `__versions` com CRCs errados ou vazios.

**Verificação:** o `Module.symvers` gerado por `modules_prepare` fica **vazio**
(sem CRCs) porque o kernel não foi compilado. Usar o `Module.symvers` deste
diretório com CRCs extraídos do dispositivo real.

### 5. Símbolos do k4.9 arm64: `__ioremap` não é `ioremap`

Em k4.9 arm64, `ioremap` é uma **macro** (em `<asm/io.h>`) que chama `__ioremap`.
O símbolo exportado pelo kernel é `__ioremap`, não `ioremap`.

**Nunca incluir `<asm/io.h>` ou `<linux/io.h>`** — eles redefinem `ioremap` como
macro gerando referências a símbolos que não existem no k4.9.

Declarações corretas:
```c
/* NÃO incluir <asm/io.h> nem <linux/io.h> */
#undef ioremap
#undef iounmap
extern void __iomem *__ioremap(phys_addr_t phys_addr, size_t size, pgprot_t prot);
extern void __iounmap(volatile void __iomem *addr);
extern void __udelay(unsigned long usecs);
extern __printf(1, 2) int printk(const char *fmt, ...);
```

---

## CRCs conhecidos (Android k4.9.170 arm64 — MCD-125)

Extraídos de `mali_kbase.ko` e `bcmdhd.ko` do dispositivo.

| Símbolo | CRC | Fonte |
|---------|-----|-------|
| `module_layout` | `0x2e1445dd` | mali_kbase.ko, bcmdhd.ko, xr819.ko |
| `printk` | `0x27e1a049` | mali_kbase.ko, bcmdhd.ko, xr819.ko |
| `__ioremap` | `0xf24b3dfe` | mali_kbase.ko, bcmdhd.ko |
| `__iounmap` | `0x45a55ec8` | mali_kbase.ko, bcmdhd.ko |
| `__udelay` | `0x9e7d6bd0` | bcmdhd.ko |
| `__const_udelay` | `0xeae3dfd6` | xr819.ko, bcmdhd.ko |

---

## Adicionando novos símbolos

Para usar um símbolo não listado acima, é preciso encontrar o CRC no dispositivo.

### Método: extrair CRC de um módulo do dispositivo

```bash
# 1. Encontrar um módulo do dispositivo que use o símbolo desejado
adb shell su -c 'grep -rl "sym_name" /vendor/modules/' 2>/dev/null
# (ou procurar por módulos de hardware que usem MMIO/irq/etc.)

# 2. Puxar o módulo
adb shell "su -c 'cat /vendor/modules/bcmdhd.ko'" > /tmp/bcmdhd.ko

# 3. Extrair CRCs (arm64: entrada = 8 bytes CRC + 56 bytes nome = 64 bytes total)
python3 << 'EOF'
import struct
data = open('/tmp/bcmdhd.ko','rb').read()

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
        sh_offset = struct.unpack_from('<Q', data, sh_off + 24)[0]
        sh_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
        entry_size = 64  # 8 bytes CRC + 56 bytes name (arm64)
        n = sh_size // entry_size
        for j in range(n):
            off = sh_offset + j * entry_size
            crc = struct.unpack_from('<Q', data, off)[0]
            sym = data[off+8:off+64].split(b'\x00')[0].decode('ascii','replace')
            if sym:  # filtrar entradas vazias
                print(f'0x{crc:08x}  {sym}')
EOF
```

> **Nota sobre o tamanho da entrada:** em arm64 de 64 bits, `unsigned long` = 8 bytes,
> então `sizeof(struct modversion_info)` = 8 + 56 = **64 bytes** (não 68!).
> Em x86_64 o mesmo, mas em arm32/x86 seria 4 + 60 = 64 bytes também.
> O tamanho total é sempre 64 bytes em qualquer arquitetura.

---

## Template para novo módulo

Estrutura mínima para um novo módulo de diagnóstico:

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/init.h>
#include <linux/types.h>
#include <asm/pgtable-prot.h>   /* PROT_DEVICE_nGnRE — não usar <asm/io.h> */

/* k4.9 arm64: .plt section obrigatória */
asm(".section .plt,\"ax\"\n\t.byte 0\n\t.previous\n\t");

/* Símbolos k4.9 arm64 — declarar diretamente, não via <asm/io.h> */
#undef ioremap
#undef iounmap
#undef printk
extern void __iomem *__ioremap(phys_addr_t phys_addr, size_t size, pgprot_t prot);
extern void __iounmap(volatile void __iomem *addr);
extern void __udelay(unsigned long usecs);
extern __printf(1, 2) int printk(const char *fmt, ...);

#define MY_IOREMAP(pa, sz) __ioremap((pa), (sz), __pgprot(PROT_DEVICE_nGnRE))
#define MY_IOUNMAP(va)     __iounmap(va)
#define LOG(fmt, ...) printk(KERN_INFO "MYMOD: " fmt "\n", ##__VA_ARGS__)

/* MMIO via volatile — sem depender de ioread32/iowrite32 */
static inline u32 r32(void __iomem *base, u32 off) {
    return *(volatile u32 *)((u8 __force *)base + off);
}
static inline void w32(void __iomem *base, u32 off, u32 val) {
    *(volatile u32 *)((u8 __force *)base + off) = val;
}

static int __init mymod_init(void)
{
    void __iomem *base;
    LOG("==== início ====");

    base = MY_IOREMAP(0x03001000UL, 0x1000UL);  /* exemplo: CCU */
    if (!base) { LOG("ioremap falhou"); return -EAGAIN; }

    LOG("CCU+0x97c = 0x%08x", r32(base, 0x97c));

    MY_IOUNMAP(base);
    LOG("==== fim ====");
    return -EAGAIN;  /* auto-descarrega após init */
}

static void __exit mymod_exit(void) {}

module_init(mymod_init);
module_exit(mymod_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Módulo diagnóstico H313 Android k4.9");
```

**Makefile correspondente:**
```makefile
obj-m := mymod.o
KDIR  ?= $(HOME)/android-k49-full
ARCH  := arm64
CROSS := aarch64-linux-gnu-
all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) \
	    KBUILD_MODPOST_WARN=1 modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) clean
```

---

## Checklist de verificação antes do deploy

```bash
# 1. vermagic correto?
python3 -c "
data=open('modulo.ko','rb').read()
idx=data.find(b'vermagic=')
print(data[idx:idx+60].split(b'\x00')[0].decode())
"
# Esperado: vermagic=4.9.170 SMP preempt mod_unload modversions aarch64

# 2. .plt section presente?
aarch64-linux-gnu-readelf -S modulo.ko | grep plt
# Deve ter uma linha com .plt

# 3. __versions com entradas?
aarch64-linux-gnu-readelf -S modulo.ko | grep versions
# Size deve ser > 0

# 4. gnu.linkonce.this_module size = 0x300?
aarch64-linux-gnu-readelf -S modulo.ko | grep "linkonce"
# Size deve ser 0x000300 (768 bytes = sizeof(struct module) no k4.9 arm64)
```

---

## Diagnóstico de erros

| Erro | Causa | Solução |
|------|-------|---------|
| `Exec format error` | vermagic/CRC errado | Verificar SUBLEVEL=170 e Module.symvers |
| `module PLT section missing` | seção `.plt` ausente | Adicionar `asm(".section .plt...")` |
| Kernel panic / reboot | pgprot errado | Usar `PROT_DEVICE_nGnRE` de `<asm/pgtable-prot.h>` |
| `Try again` (rc=1) | **Normal** — EAGAIN do init | É o comportamento esperado; ver dmesg |
| `Operation not permitted` | SELinux / permissão | Usar `su -c 'insmod ...'` com root |
| `Invalid module format` | struct module size errado | Compilar com android-k49-full, não 6.x |

---

## Arquivos neste diretório

| Arquivo | Descrição |
|---------|-----------|
| `ac300_diag.c` | Módulo de diagnóstico EMAC1/AC300 (exemplo completo) |
| `finsmod.c` | Loader alternativo via `finit_module()` syscall (não necessário com vermagic correto) |
| `Makefile` | Build para android-k49-full |
| `Module.symvers` | CRCs dos símbolos kernel extraídos do dispositivo |
| `build.sh` | Script de build com verificações automáticas |
| `README.md` | Este arquivo |
