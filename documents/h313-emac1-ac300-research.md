# EMAC1 DTS — Histórico de versões testadas (MCD-125)

## Contexto
- SoC: Allwinner H313 (sun50iw9p1)
- Driver kernel: `allwinner,sunxi-gmac` (BSP, aplicado globalmente via OrangePi Zero2W patch em h616.dtsi)
- h616.dtsi base fornece: `reg`, `clocks`, `pinctrl-0 = <&rmii_pins>`, `tx-delay = <7>`, `rx-delay = <31>`, `compatible`
- PMIC: AXP313A — reg_aldo1 = 1.8V always-on

---

## v1 — Hybrid INT+EXT (commits d5e7b0b, 03adb46)
**Status: FALHOU — No PHY found**

```dts
&emac1 {
    pinctrl-names = "default";
    pinctrl-0 = <&rmii_pins>;
    phy-mode = "rmii";
    phy-handle = <&rmii_phy>;
    allwinner,use-internal-phy;   /* PROBLEMA: ativa INT_PHY path no driver */
    status = "okay";
};

&mdio1 {
    rmii_phy: ethernet-phy@0 {
        compatible = "ethernet-phy-ieee802.3-c22";
        reg = <0>;
    };
};
```

**Análise:** Config híbrida inválida — `allwinner,use-internal-phy` ativa INT_PHY path que:
- Limpa bit16 (EPHY_RST) em 0x3000034 antes do scan MDIO
- Força `phy_interface = MII` em vez de RMII (modo RMII nunca configurado no registrador)
- MDIO scan falha com EPHY em estado incorreto

---

## v2 — INT_PHY puro (sessão 2026-03-20)
**Status: FALHOU — No PHY found**

```dts
&emac1 {
    allwinner,use-internal-phy;
    status = "okay";
};
```

**Análise:** Modo INT_PHY puro. Driver BSP:
- `geth_power_on`: bit15=1, bit16=0 (EPHY em reset ou estado inválido), bits17:18=1
- `geth_clk_enable`: phy_interface forçado para MII → não seta bits RMII (0x00002001) em 0x3000034
- Resultado observado em 0x3000034 pós-driver: `0x00079fe0` (bit13=0 → RMII não ativo)
- U-Boot: 0x3000034 = `0x00058000` (bits 15, 16, 18 — estado de fábrica/Android)

**Diagnósticos coletados:**
- `dmesg | grep emac` → "No PHY found!" / "geth_open failed"
- CLK emac-25m: enable_count=0, rate=200MHz (suspeito mas provavelmente irrelevante para MDIO)
- mii read no U-Boot: "NULL device name" (U-Boot não inicializa emac1 — intencional no U-Boot DTS)

---

## v3 — EXT_PHY puro, sem phy-supply (NÃO testada)
*Versão intermediária planejada mas nunca chegou a ser compilada*

---

## v4 — EXT_PHY puro, espelhando X96Q (AGUARDA BUILD — 2026-03-21)
**Status: FALHOU — No PHY found (2026-03-21)**

```dts
/* EMAC1: H313 internal RMII EPHY, accessed via EXT_PHY driver mode.
 * Using allwinner,use-internal-phy triggers INT_PHY path which:
 *   - clears bit16 (EPHY_RST) before MDIO scan, breaking MDIO
 *   - forces phy_interface=MII, preventing RMII mode config in 0x3000034
 * EXT_PHY mode (phy-handle + mdio node) keeps 0x3000034 at the U-Boot
 * reset value (bits 15,16,18 set = EPHY running) and applies phy-mode=rmii
 * correctly. This mirrors the working X96Q/mxqpro H313 DTS. */
&emac1 {
    pinctrl-names = "default";
    pinctrl-0 = <&rmii_pins>;
    phy-mode = "rmii";
    phy-handle = <&rmii_phy>;
    phy-supply = <&reg_aldo1>;
    status = "okay";
};

&mdio1 {
    rmii_phy: ethernet-phy@0 {
        compatible = "ethernet-phy-ieee802.3-c22";
        reg = <0>;
    };
};
```

**Racional:**
- X96Q (H313, mesma EPHY interna) usa esta config exata e está **confirmado funcionando**
  (Armbian PR #7101, v24.8.1, "Desktop and Ethernet working")
- EXT_PHY path no driver NÃO toca 0x3000034 EPHY bits → mantém estado U-Boot (0x00058000)
- `phy-mode = "rmii"` → `geth_clk_enable` seta bits RMII (0x00002001) corretamente
- `phy-supply` = 1.8V para EPHY (presente no X96Q que funciona)
- `pinctrl-names = "default"` necessário para ativar pinctrl-0 (ausente em h616.dtsi base)
- Delays (tx=7, rx=31) já em h616.dtsi — `allwinner,rx-delay-ps` ignorado pelo BSP driver

**Resultado:**
- Interface `end0` criada (renomeada de eth0) mas state DOWN
- dmesg: "No PHY found!" repetido 10x (tentativas do NetworkManager)
- ip addr show eth0: "Device does not exist"
- "Network is Online" no boot log era do loopback, não ethernet

**Conclusão:** problema não é o code path INT_PHY vs EXT_PHY. O EPHY H313 não responde ao scan MDIO em nenhum endereço (0-31), independente do modo. Causa mais provável: PHY ID retornado pelo EPHY não está na allowlist do driver (só aceita EPHY_ID=0x00441400, IP101G_ID, AC300_ID), ou EPHY genuinamente não responde.

**Notas de diagnóstico:**
- 0x3000034 pré-driver (U-Boot): `0x00058000` = bits 15 (EPHY_EN), 16 (RST_n alto), 18
- U-Boot "No ethernet found" é **intencional** (sem emac1 no U-Boot DTS)

---

## v5 — EXT_PHY sem mdio1/phy-handle, espelhando Android (2026-03-21)
**Status: FALHOU — No PHY found**

```dts
&emac1 {
    pinctrl-names = "default";
    pinctrl-0 = <&rmii_pins>;
    phy-mode = "rmii";
    status = "okay";
};
/* sem phy-handle, sem &mdio1, sem allwinner,use-internal-phy */
```

**Diagnóstico que levou a v5 (via ADB no Android):**
- `dmesg`: `sunxi-gmac gmac1 eth0: PHY ID 00441400 at 0` → PHY existe, addr=0, ID correto!
- `ephy_25m` clock Android: **25 MHz** (correto) vs Armbian `emac-25m`: **200 MHz** (errado — gate em ahb3)
- Android DTS: **sem `&mdio1` e sem `phy-handle`** — driver faz scan manual

**Bug identificado no v4:**
Em kernel 6.12, `mdiobus_register()` com DT-declared `&mdio1 { rmii_phy@0 }` pré-cria um
`phy_device` placeholder com `phy_id=0x00000000` (não lido do hardware ainda).
O scan em `geth_phy_init` faz `mdiobus_get_phy(bus, 0)` → retorna placeholder com phy_id=0x00
→ não chama `mdiobus_scan_c22` → phy_id==0x00 → SKIP → "No PHY found!".
Sem DT node: `mdiobus_get_phy` retorna NULL → `mdiobus_scan_c22` lê hardware → 0x00441400 → encontra.

**Racional:**
- Android usa exatamente este padrão (sem mdio1) e funciona
- Driver BSP não usa `phy-handle` em nenhum lugar (sem `of_phy_find_device`)
- EXT_PHY mode mantém 0x3000034 sem manipular bit16
- `phy-mode = "rmii"` → geth_clk_enable configura RMII bits corretamente

---

**Análise pós-falha:**
- `emac-25m`: `enable_count=0`, `rate=200MHz` → clock NÃO habilitado pelo driver em EXT_PHY mode
- Em EXT_PHY mode, `geth_clk_enable` só habilita `ephy_clk` se `g_use_ephy_clk != 0`
- `g_use_ephy_clk` só é setado via propriedade DTS `use_ephy25m = <1>`
- Sem clock: EPHY não responde no MDIO → "No PHY found" em todos os endereços 0-31

---

## v6 — EXT_PHY + use_ephy25m=1 (testada ~2026-03-22)
**Status: FALHOU — No PHY found**

```dts
&emac1 {
    pinctrl-names = "default";
    pinctrl-0 = <&rmii_pins>;
    phy-mode = "rmii";
    clocks = <&ccu CLK_BUS_EMAC1>, <&ccu CLK_EMAC_25M>, <&ccu CLK_EMAC_25M>;
    clock-names = "bus-emac1", "emac-25m", "ephy";
    use_ephy25m = <1>;
    status = "okay";
};
```

**Análise pós-falha:**
- `use_ephy25m = <1>` → driver habilitou CLK_EMAC_25M (`emac-25m`) em EXT_PHY mode
- Mas `emac-25m` na CCU tem parent "ahb3" (~200 MHz) — o `clk_prepare_enable` escreve
  BIT(31)|BIT(30) em CCU+0x970. BIT(30) é na verdade o CLK_SRC_SEL (0=24MHz HOSC,
  1=25MHz PLL), não um segundo gate. Com BIT(30)=1 o clock EMITE 25 MHz do PLL.
- Mesmo assim MDIO ainda retorna 0xFFFF em todos os endereços.
- **Conclusão:** CLK_EMAC_25M habilitado NÃO resolve o problema MDIO.

---

## v7 → v17 — Múltiplas tentativas com dwmac-sun8i (2026-03-22/23)
**Status: Todas FALHARAM em MDIO (0xFFFF)**

Pivô estratégico: abandono do driver BSP `allwinner,sunxi-gmac` e troca para o driver mainline
`dwmac-sun8i` via `compatible = "allwinner,sun50i-h313-emac"`. Motivação:
- X96Q mainline usa `"allwinner,sunxi-gmac"` (BSP) mas sem `use-internal-phy`
- dwmac-sun8i tem suporte a `internal_ephy` que mapeia para AC200/AC300
- O novo campo `internal_ephy = true` em `emac_variant_h313` foi adicionado

Versões tentadas neste bloco (todas compiladas via hot-patch do módulo `dwmac-sun8i.ko`):

| Tag | Mudança principal | Resultado |
|-----|-------------------|-----------|
| DRV-v2 | Evitar SOFT_RST em probe para AC300 (deadlock sem RMII clock) | MDIO 0xFFFF |
| DRV-v3 | Fallback pós-probe + pre_scan_init hook em stmmac_mdio | MDIO 0xFFFF |
| DRV-v4 | PWM5 bypass enable (PA12=mux2, PCCR45 BIT(4)\|BIT(6), PER BIT(5)) | MDIO 0xFFFF |
| DRV-v5 | CLK_SEL (bit18) = 0 no set_syscon (hipótese: emac-25m @200MHz corrupta MDIO) | MDIO 0xFFFF |

**DTS evoluiu até v18:**
```dts
&emac1 {
    compatible = "allwinner,sun50i-h313-emac";
    syscon = <&syscon 1>;
    interrupt-names = "macirq";
    clocks = <&ccu CLK_BUS_EMAC1>, <&ccu CLK_EMAC_25M>;
    clock-names = "stmmaceth", "ephy-25m";
    phy-mode = "rmii";
    phy-handle = <&rmii_phy>;
    phy-supply = <&reg_aldo1>;
    allwinner,rx-delay-ps = <3100>;
    allwinner,tx-delay-ps = <700>;
    status = "okay";
};

&mdio1 {
    compatible = "snps,dwmac-mdio";
    rmii_phy: ethernet-phy@0 {
        reg = <0>;
    };
};
```

**Fontes de referência consultadas neste período:**
- Android BSP DTS extraído de boot.img do X96Q: `eth@05030000` tem apenas `clock-names = "gmac"`,
  sem `ephy-25m`. Confirma que emac-25m pode não existir funcionalmente no H313.
- BSP `ac200` node no X96Q DTS: `tv_twi_id=3, tv_twi_addr=0x10, tv_pwm_ch=5` — usa PWM canal 5
  via driver ac200 para fornecer clock de referência ao AC300.
- Mainline X96Q DTS usa `compatible = "allwinner,sunxi-gmac"` (BSP), sem `use-internal-phy`.

---

## v18 — dwmac-sun8i + AC300 init + PWM5 bypass (estado atual, 2026-03-25)
**Status: EM INVESTIGAÇÃO — MDIO retorna 0xFFFF durante init de driver**

### DTS (atual no worktree)
```dts
/* emac1: compatible = "allwinner,sun50i-h313-emac", syscon = <&syscon 1>,
   clocks stmmaceth/ephy-25m, phy-handle=rmii_phy, rx-delay=3100, tx-delay=700 */
```

### Driver dwmac-sun8i — tag DRV-v6 (atual)

**Mudanças acumuladas vs mainline:**

1. **`emac_variant_h313`** — nova variante para H313/AC300:
   ```c
   .default_syscon_value = 0x58000,  /* bit15=INT_PHY_EN, bit16=EPHY_SHUTDOWN (default),
                                        bit18=CLK_SEL=1 (24MHz HOSC) */
   .soc_has_internal_phy = false,
   .internal_ephy = true,
   ```

2. **`sun8i_dwmac_set_syscon()` — bloco `internal_ephy`:**
   ```c
   reg &= ~H3_EPHY_SHUTDOWN;   /* bit16=0: EPHY powered */
   reg |= H3_EPHY_SELECT;       /* bit15=1: MDIO routed to AC300 */
   reg |= H3_EPHY_CLK_SEL;     /* bit18=1: 24MHz HOSC reference */
   ```

3. **`sun8i_h313_ac300_pwm5_enable()`** — fornece 24MHz via PA12 (PWM5 bypass):
   ```c
   /* CCU+0x7ac: BIT(16)|BIT(0) → CLK_BUS_PWM + RST_BUS_PWM deassert */
   /* PIO PA_CFG1 bits[19:16] = 0x2 → PA12 mux=2 (pwm5) */
   /* PCCR45 (PWM+0x28): CLK_SRC=0 (24MHz), CLK_GATING=BIT(4), BYPASS_CH5=BIT(5) */
   /* PER (PWM+0x40): BIT(5) → PWM5 output enable */
   /* msleep(50) */
   ```
   > **Nota:** BIT(5) é o bypass do canal 5 (ímpar). BIT(6) seria o do canal 4 (par).
   > Bug anterior: usávamos BIT(6) (BYPASS_CH4) em vez de BIT(5) (BYPASS_CH5).
   > Corrigido em DRV-v6.

4. **`sun8i_h313_ac300_ephy_pre_scan_init()`** — sequência MDIO de init do AC300:
   ```c
   mdiobus_write(bus, 0, MII_BMCR, 0x1f83);  /* release internal reset */
   mdiobus_write(bus, 0, MII_BMCR, 0x1fb7);  /* enable 24MHz clock gate */
   mdiobus_write(bus, 0, 0x05, 0xa819);       /* vendor PHY setup */
   mdiobus_write(bus, 0, 0x06, 0x0000);
   msleep(1000);
   ```
   > Registrada como `pre_scan_init` em `stmmac_mdio_bus_data` (campo adicionado ao `stmmac.h`).
   > **LIMITAÇÃO:** `stmmac_mdio.c` precisaria ser recompilado para chamar esse callback.
   > Com hot-patch só do `dwmac-sun8i.ko`, o callback nunca é chamado antes do MDIO scan.
   > O fallback pós-probe (dwmac-sun8i.c linha 1440) executa a init igualmente, depois do scan.

5. **`sun8i_dwmac_reset()` bloqueado para `internal_ephy`:**
   - SOFT_RST (EMAC_BASIC_CTL1 bit0) trava sem clock RMII 50MHz do AC300.
   - AC300 só gera 50MHz após init MDIO → deadlock → bloqueado em probe.

### Estado dos registradores confirmado no dispositivo (2026-03-25)

```
PCCR45: 0x00000030  bit4=1 (CLK_GATING), bit5=1 (BYPASS_CH5) ✓, bit6=0 ✓
PER:    0x00000020  bit5=1 (PWM5 enabled) ✓
PA12 mux: 2 (pwm5) ✓
CCU PWM BGR (0x7ac): 0x00010001  CLK=1, RST deasserted=1 ✓
SYSCON (0x34): 0x0004bfe1  bit15=1 (INT_PHY_EN), bit16=0 (powered), bit18=1 (CLK_SEL=24MHz) ✓
CCU EMAC_25M (0x970): 0xc0000000  bit31=1 (gate), bit30=1 (25MHz PLL src) — habilitado pelo driver ✓
CCU EMAC1 BGR (0x97c): 0x00020000  bit17=1 (RST deasserted), bit1=0 (clock OFF) ← lido em PM suspend
EMAC1 BASIC_CTL1 (0x04): 0x0000ffff  ← lido sem clock EMAC1 (PM suspend) — valor inválido
```

> **Leitura durante runtime PM suspend:** quando o módulo está carregado mas a interface está DOWN
> e o dispositivo entrou em runtime suspend, o clock CLK_BUS_EMAC1 é desligado pelo framework PM.
> Leituras do EMAC1 (incluindo MDIO_CMD/MDIO_DATA) sem clock retornam 0xFFFF — isso explica os
> resultados 0xFFFF do script Python de diagnóstico `test_ac300_clk_enable.py` feito com o módulo
> carregado.

### Resultado de boot com DRV-v6

```
dwmac-sun8i 5030000.ethernet: Current syscon value is not the default 18000 (expect 58000)
mdio_bus stmmac-0: MDIO device at address 0 is missing.
dwmac-sun8i 5030000.ethernet: AC300: PWM5 bypass enabled (24MHz ref to EPHY)
dwmac-sun8i 5030000.ethernet: AC300 pre-init: reg2=0xffff reg3=0xffff
dwmac-sun8i 5030000.ethernet: AC300: PWM5 bypass enabled (24MHz ref to EPHY)
dwmac-sun8i 5030000.ethernet: AC300 post-init: reg2=0xffff reg3=0xffff
dwmac-sun8i 5030000.ethernet: AC300 EPHY not responding after init
```

> "Current syscon value is not the default 18000 (expect 58000)": módulo antigo havia deixado
> SYSCON em 0x18000 (sem CLK_SEL). Novo default é 0x58000 (com CLK_SEL=1). O driver lê o valor
> antes de escrever e avisa quando difere do default — não é erro crítico.

### Hipóteses em aberto para MDIO 0xFFFF

| # | Hipótese | Evidência | Descartada? |
|---|----------|-----------|-------------|
| 1 | CLK_SEL=1 corrompe MDIO (200MHz para AC300) | CLK_EMAC_25M é 25MHz do PLL (não 200MHz) | **Sim** |
| 2 | CLK_SEL=0 → sem ref clock no AC300 | Com CLK_SEL=0 também retorna 0xFFFF | **Sim** |
| 3 | BYPASS_CH4 em vez de BYPASS_CH5 (bug BIT(6)) | Corrigido em DRV-v6 — ainda 0xFFFF no fallback | Parcialmente |
| 4 | AC300 precisa de PWM5 para responder no MDIO | Fallback pós-bug com BIT(5) ainda 0xFFFF | Parcialmente |
| 5 | Leituras Python conflitam com PM suspend (falso 0xFFFF) | EMAC1_CTL1=0xffff sem clock confirma | **Provável** |
| 6 | stmmac_mdio.c não recompilado → pre_scan_init não chamado | Confirmado: callback nunca executado antes do scan | **Confirmado** |
| 7 | SOFT_RST stuck (0x08000001) bloqueia MDIO controller | MDIO BUSY auto-clears → hardware executa transação | Provavelmente não |

### Próximos passos

1. **Teste isolado definitivo:** descarregar módulo, rodar script Python que:
   - Habilita CLK_BUS_EMAC1 (CCU+0x97c BIT(1)|BIT(17))
   - Configura SYSCON corretamente
   - Configura PWM5 com **BIT(5)** correto (não BIT(6))
   - Faz MDIO scan — elimina ambiguidade PM suspend

2. **Rebuild completo do kernel** (não hot-patch) para que `stmmac_mdio.c` chame `pre_scan_init`
   antes do scan, e AC300 seja inicializado antes do `of_mdiobus_register()`.

3. **Investigar se AC300 responde como 0xc0000000** (ID inicial antes de ac300_ephy_enable)
   quando tudo está em ordem — confirmar com scan completo dos 32 endereços.

---

## Testes isolados MDIO (2026-03-25) — módulo descarregado
**Status: AC300 não responde em NENHUMA combinação — causa raiz ainda desconhecida**

### Metodologia

Eliminação total de ambiguidade de PM suspend:
1. `modprobe -r dwmac-sun8i stmmac_platform stmmac` — módulo descarregado
2. Scripts Python (`/tmp/test_isolated_mdio.py`, `/tmp/test_ac300_clk_enable.py`, `/tmp/test_pwm5_fix.py`)
   acessam registradores via `/dev/mem` diretamente
3. CLK_BUS_EMAC1 habilitado manualmente antes de qualquer leitura MDIO

### Confirmação do layout MDIO correto

**Registradores EMAC1 Allwinner (dwmac-sun8i):**
- `MDIO_CMD = 0x48` (EMAC1+0x48) — NÃO é 0x10 como em STMMAC GMAC1000 padrão
- `MDIO_DATA = 0x4c` (EMAC1+0x4c) — NÃO é 0x14
- Formato do comando: `bits[22:20]=CSR | bits[16:12]=PHY_ADDR | bits[8:4]=REG | bit1=WRITE | bit0=BUSY`
- Confirmado pela leitura de EMAC1+0x48 = `0x00300030` após transação concluída (BUSY=0 auto-clear)

Teste com offsets STMMAC padrão (0x10/0x14): retornou 0x0000 em todos os endereços — prova que
esses offsets são inválidos para Allwinner EMAC. Os scripts com 0x48/0x4c estavam corretos.

### Confirmação: bit18 (CLK_SEL) É limpável

Afirmação anterior ("hardware-fixed=1") estava incorreta. Teste de escrita/leitura:
- Escrita com bit18=0 → readback = 0 (bit limpo com sucesso)
- bit18=1 → 24MHz HOSC para AC300, bit18=0 → caminho CLK_EMAC_25M

### Matriz de combinações testadas — todas retornaram 0xFFFF

| CLK_SEL (bit18) | CLK_EMAC_25M | PWM5 | CSR | INT_PHY_EN (bit15) | Resultado |
|-----------------|--------------|------|-----|---------------------|-----------|
| 1 (24MHz HOSC) | desligado | desligado | 3 | 1 | 0xFFFF |
| 1 (24MHz HOSC) | desligado | BIT(5) correto | 1-7 | 1 | 0xFFFF |
| 1 (24MHz HOSC) | ligado (25MHz PLL) | BIT(5) correto | 3 | 1 | 0xFFFF |
| 0 (CLK_EMAC_25M path) | ligado (25MHz PLL) | desligado | 3 | 1 | 0xFFFF |
| 0 (CLK_EMAC_25M path) | ligado (25MHz PLL) | BIT(5) correto | 3 | 1 | 0xFFFF |
| qualquer | qualquer | qualquer | qualquer | **0 (INT_PHY_EN=0)** | **0x0000** |

> `INT_PHY_EN=0` retorna 0x0000 (pads externos puxados para GND) → prova que o hardware MDIO
> **executa as transações** (BUSY auto-limpa, dados chegam do pad). O problema é que
> `INT_PHY_EN=1` (rotear MDIO para AC300 interno) retorna 0xFFFF — AC300 genuinamente não responde.

Scan completo dos 32 endereços MDIO com CLK_BUS_EMAC1 habilitado, SYSCON correto (bit15=1, bit16=0,
bit17=1, bit18=1), PWM5 BIT(5) ativo: **todos os 32 endereços retornam 0xFFFF**.

### SOFT_RST — comportamento confirmado

Escrita de 0x01 em EMAC_BASIC_CTL1 (EMAC1+0x04) via Python → reset fica preso (não auto-limpa).
EMAC1+0x48 retornou 0x00000000 após o SOFT_RST — MDIO controller quebrado até reload do módulo.
Confirmação: sem clock RMII 50MHz do AC300, SOFT_RST não completa — exatamente o deadlock descrito
no driver (DRV-v6 bloqueia SOFT_RST para `internal_ephy`).

### Estado do registrador EMAC_BASIC_CTL1 durante probe ativo

Quando o módulo está carregado e a probe está ativa (interface ainda DOWN, sem PM suspend):
- `EMAC_BASIC_CTL1 = 0x08000001` — bits[27:24]=0x8 (burst_len=8, setado por `sun8i_dwmac_core_init`)
  + bit0=1 (SOFT_RST ou boot default)
- MDIO ainda executa transações com bit0=1 — o SOFT_RST state não bloqueia o controller MDIO

### Análise do DTS Android (documents/adb/hardware_config.dts.txt)

**EMAC0 (0x05020000) — desabilitado:**
- `status = "disable"`
- Clocks: `gmac0` (CLK_BUS_EMAC0) + `ephy_25m` (CLK_EMAC_25M, phandle 0xcc)
- Pinos: PI0-PI16 (GMAC0/MII)

**EMAC1 (0x05030000) — habilitado:**
- `status = "okay"`
- Clocks: **apenas `gmac1`** (phandle 0xcf = CLK_BUS_EMAC1) — **SEM ephy_25m**
- Pinos: PA0-PA9 (RMII, confirmado mux=2 no nosso setup)
- Sem `phy-handle`, sem `&mdio1`, sem `use_ephy25m`

**PA12 / PWM5:**
- PA12 com mux=2 (PWM5) está definido nos pinctrl do Android
- Mas **não é referenciado pelo nó EMAC1** no Android DTS
- PWM5 é para driver `ac200` separado (TV codec), não diretamente para EMAC1

**Conclusão crítica:** O BSP Android usa APENAS CLK_BUS_EMAC1 para EMAC1 — sem CLK_EMAC_25M,
sem PWM5. O BSP `sunxi-gmac` tem código `ac300_ephy_enable()` mas o path de inicialização
difere do nosso driver `dwmac-sun8i`. O BSP pode ter sequência diferente de SYSCON + MDIO.

### Hipóteses atualizadas

| # | Hipótese | Status |
|---|----------|--------|
| 1 | CLK_SEL corrupto | **Descartado** — ambos 0/1 testados → 0xFFFF |
| 2 | PWM5 BIT(6) vs BIT(5) | **Descartado** — BIT(5) correto testado → 0xFFFF |
| 3 | PM suspend interfere com leituras Python | **Descartado** — módulo descarregado, sem PM |
| 4 | CLK_EMAC_25M ausente | **Descartado** — habilitado e desabilitado → 0xFFFF ambos |
| 5 | pre_scan_init não executado (stmmac_mdio não recompilado) | **Aberto** — mas MDIO 0xFFFF já antes de qualquer probe |
| 6 | AC300 não funcional neste lote H313 (L6020BA) | **Aberto** — hipótese forte |
| 7 | Sequência BSP diferente (SYSCON → MDIO) necessária | **Aberto** — Android usa sunxi-gmac, não dwmac-sun8i |
| 8 | Android Ethernet funciona no MCD-125? | **Não confirmado** — questão diagnóstica fundamental |
| 9 | U-Boot pré-inicializa AC300 antes do kernel | **Aberto** — U-Boot tem emac0 (não emac1) |

### Próximos passos revisados

1. **Verificar se Android Ethernet funciona no MCD-125** — se não funciona, AC300 pode estar
   inativo/danificado neste lote de hardware. Se funciona, a sequência BSP tem algo diferente.

2. **Comparar sequência de init BSP (sunxi-gmac.c) com dwmac-sun8i:**
   - BSP: `geth_power_on` → `geth_clk_enable` → `geth_open` → scan MDIO automático
   - O BSP pode ter timing diferente ou ordem diferente de bits em 0x3000034
   - BSP usa `clk_rate=26000000` (26MHz do AHB), CSR=0 (div/26 → 1MHz MDC) — vs nosso CSR=3

3. **Rebuild completo do kernel** (não hot-patch) para que `stmmac_mdio.c` recompilado chame
   `pre_scan_init` antes do scan, executando `ac300_ephy_enable()` no momento correto.

4. **Testar driver BSP `allwinner,sunxi-gmac`** com DTS sem `&mdio1` e sem `use_ephy25m`
   (igual ao Android) mas adicionando `allwinner,use-internal-phy` para ativar path AC300.

---

---

## Diagnóstico via módulo kernel Android k4.9 (2026-03-27)
**Status: BREAKTHROUGH — Configuração real do Android confirmada com sucesso**

### Método

Módulo kernel `ac300_diag.ko` compilado para o Android k4.9.170 e carregado via `insmod` com ADB
root. O módulo lê MMIO direto dos registradores relevantes enquanto o Android e o driver BSP
`sunxi-gmac` estão funcionando normalmente. Fonte: `documents/tools/ac300-diag-module/`.

**Build:** android-k49-full (clone shallow de `android.googlesource.com/kernel/common@experimental/android-4.9`),
vermagic `4.9.170 SMP preempt mod_unload modversions aarch64`, CRCs extraídos de
`mali_kbase.ko` e `bcmdhd.ko` do próprio dispositivo.

**Obstáculos técnicos superados:**
- `module PLT section missing`: k4.9 arm64 exige seção `.plt` → adicionada via `asm(".section .plt,...")`
- pgprot errado (`0x00400000`): substituído por `PROT_DEVICE_nGnRE` real do `<asm/pgtable-prot.h>`
  (`0x00e8000000000707` em k4.9 arm64) — o valor errado causava kernel panic
- Vermagic: SUBLEVEL corrigido para 170 no Makefile do android-k49-full
- CRCs: `__ioremap=0xf24b3dfe`, `__iounmap=0x45a55ec8`, `__udelay=0x9e7d6bd0`,
  `module_layout=0x2e1445dd`, `printk=0x27e1a049`

### Saída completa do dmesg

```
AC300-DIAG: ==== AC300/EMAC1 Diagnostic (Android k4.9 force-load) ====
AC300-DIAG: CCU BGR(0x97c)=0x00020002  E0_CLK=0 RST=0  E1_CLK=1 RST=1
AC300-DIAG: CLK_25M(0x970)=0x00000000  GATE=0 SRC=0 DIV=0
AC300-DIAG: PWM BGR(0x7ac)=0x00010001  CLK=1 RST=1
AC300-DIAG: SYSCON+34=0x00053fe1  INT_PHY=0 PWRDN=1 LED=0 CLK_SEL=1 RMII=1
AC300-DIAG: PA_CFG0(PA0-3) =0x22222222
AC300-DIAG: PA_CFG1(PA4-7) =0x00027722
AC300-DIAG: PA_CFG2(PA8-11)=0x00000000
AC300-DIAG: PA_CFG3(PA12-15)=0x00000000  PA12_MUX=0  (2=pwm5)
AC300-DIAG: PWM PCCR45(+28)=0x00000050  SRC=0 GATE=1 BYPASS5=0 PRESCALE=0
AC300-DIAG: PWM PER  (+40) =0x00000020  CH5=1 CH4=0
AC300-DIAG: PWM PCNTR(+2c) =0x00000000  period=0 duty=0
AC300-DIAG: EMAC1_CTL0=0x0000000d
AC300-DIAG: EMAC1_CTL1=0x08000000  SOFT_RST=0
AC300-DIAG: EMAC1_MDIO_CMD =0x00300040
AC300-DIAG: MDIO scan addr=0-7:
AC300-DIAG:   PHY@0: r0=0x3000 r2=0x0044 r3=0x1400 ID=0x00441400  <-- AC300!
AC300-DIAG: AC300 addr=0 detailed:
AC300-DIAG:   reg=0x00: 0x3000   (SYS_CONTROL — pós-init)
AC300-DIAG:   reg=0x01: 0x79ed   (BMSR — link up, full duplex)
AC300-DIAG:   reg=0x02: 0x0044   (PHY_ID1)
AC300-DIAG:   reg=0x03: 0x1400   (PHY_ID2)
AC300-DIAG:   reg=0x04: 0x01e1   (ANAR)
AC300-DIAG:   reg=0x05: 0x4de1   (ANLPAR)
AC300-DIAG:   reg=0x06: 0x0067   (ANER)
AC300-DIAG:   reg=0x07: 0x2801
AC300-DIAG: ==== Done ====
```

### Análise: diferenças críticas vs Armbian DRV-v6

| Parâmetro | Android (funciona) | Armbian DRV-v6 | Impacto |
|-----------|-------------------|----------------|---------|
| `INT_PHY_EN` bit15 | **0** | 1 | Possível causa raiz |
| `PWRDN` bit16 | **1** | 0 | Possivelmente invertido em H313 |
| `CLK_SEL` bit18 | 1 (24MHz HOSC) | 1 (24MHz HOSC) | ✓ correto |
| RMII bit13 | 1 | 1 | ✓ correto |
| `CLK_EMAC_25M` | **GATE=0 (desligado)** | habilitado (0xc0000000) | Irrelevante ou prejudicial |
| `PA12_MUX` | **0 (GPIO)** | 2 (PWM5) | PWM5 **não é necessário**! |
| `BYPASS_CH5` | 0 | 1 | Consequência: sem bypass pois PA12 não é PWM5 |
| `EMAC1_CTL1` | 0x08000000 (SOFT_RST=0) | travado (sem clock) | OK após fix |

### Revelação sobre PA12/PWM5

**PA12_MUX=0 (GPIO) no Android** — a hipótese de que o AC300 precisa de sinal PWM5 em PA12
como clock de referência é **incorreta**.

O AC300 recebe 24MHz via path **interno do SoC**: quando `CLK_SEL=1` (bit18 do SYSCON+0x34),
o HOSC 24MHz é roteado internamente para o bloco AC300 sem passar pelo pino PA12. O sinal PWM5
que vemos no DTS do Android (`tv_pwm_ch=5`) é para outro propósito (driver `ac200` — codec de
vídeo — em outras plataformas), não para o EMAC.

**Conclusão:** todo o código de `sun8i_h313_ac300_pwm5_enable()` no DRV-v6 é desnecessário e
pode causar interferência. Deve ser removido do driver.

### Revelação sobre SYSCON bits 15/16

O Android funciona com `INT_PHY_EN=0` e `PWRDN=1`. Duas interpretações possíveis:

1. **Os bits têm significado diferente no H313 vs H3:** bit16=1 pode significar "EPHY ativo"
   (não "powered down") no H313 — nomenclatura invertida no manual vs implementação real.

2. **Os bits não são necessários para o EMAC1 do H313:** o AC300 está wired diretamente ao
   barramento RMII/MDIO do EMAC1 independentemente desses bits de controle do SYSCON.

Em ambos os casos, a implicação é: a função `sun8i_dwmac_set_syscon()` deve **não tocar nos
bits 15 e 16** para H313, deixando o hardware no estado padrão.

### EMAC1_CTL1 = 0x08000000

`bits[31:24] = 0x08` → `burst_len = 8` (configurado pelo BSP driver como campo DMA standard).
`SOFT_RST (bit0) = 0` — sem soft reset pendente — confirma que o AC300 fornece o clock RMII 50MHz
necessário para o reset completar normalmente.

### Implicações para o próximo driver (DRV-v7)

1. **Remover `sun8i_h313_ac300_pwm5_enable()`** — desnecessário e potencialmente prejudicial
2. **SYSCON: não setar bits 15 e 16** — deixar no valor de boot/padrão
3. **Não habilitar `CLK_EMAC_25M`** — ou ao menos não torná-lo obrigatório
4. **Manter `CLK_SEL=1` (bit18)** — confirmado correto pelo Android
5. **`pre_scan_init` ainda necessário** — Android funciona porque o BSP `sunxi-gmac` tem
   `ac300_ephy_enable()` integrado na sequência de init. Nosso `dwmac-sun8i` precisa disso
   antes do `of_mdiobus_register()` → requer rebuild completo (não hot-patch)

---

## Referências técnicas consolidadas

### Registradores chave
| Endereço | Nome | Bits relevantes |
|----------|------|----------------|
| 0x03000034 | SYSCON EMAC1 | bit15=INT_PHY_EN, bit16=EPHY_SHUTDOWN, bit17=LED_POL, bit18=CLK_SEL (1=24MHz HOSC) |
| 0x0300197c | CCU EMAC1 BGR | bit1=CLK_BUS_EMAC1, bit17=RST_BUS_EMAC1 |
| 0x03001970 | CCU EMAC_25M | bit31=gate, bit30=src_sel (0=HOSC 24MHz, 1=25MHz PLL) |
| 0x030017ac | CCU PWM BGR | bit0=CLK_BUS_PWM, bit16=RST_BUS_PWM |
| 0x0300a028 | PWM PCCR45 | bit4=CLK_GATING, bit5=BYPASS_CH5 (ímpar!), bit6=BYPASS_CH4 (par) |
| 0x0300a040 | PWM PER | bit5=PWM5 output enable |
| 0x0300b004 | PIO PA_CFG1 | bits[19:16]=PA12 mux (2=pwm5) |
| 0x05030048 | EMAC1 MDIO_CMD | bits[22:20]=CSR, bits[16:12]=PHY_ADDR, bits[8:4]=REG, bit1=WRITE, bit0=BUSY |
| 0x0503004c | EMAC1 MDIO_DATA | [15:0]=data |
| 0x05030004 | EMAC1 BASIC_CTL1 | bit0=SOFT_RST (trava sem RMII clock do AC300) |

### AC300 IDs esperados
- `0xc0000000` — estado inicial (antes de ac300_ephy_enable via MDIO)
- `0x00441400` — estado EPHY ativo (após ac300_ephy_enable)

### Sequência BSP ac300_ephy_enable (sunxi-gmac.c)
```c
mdio_write(dev, 0, 0x00, 0x1f83);  /* release internal reset */
mdio_write(dev, 0, 0x00, 0x1fb7);  /* enable 24MHz clock gate */
mdio_write(dev, 0, 0x05, 0xa819);  /* vendor PHY setup */
mdio_write(dev, 0, 0x06, 0x00);
msleep(1000);
/* após: PHY ID muda para 0x00441400 */
```
