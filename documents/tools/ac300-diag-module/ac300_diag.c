// SPDX-License-Identifier: GPL-2.0
/*
 * ac300_diag.c — AC300 EPHY diagnostic for H313/MCD-125 Android k4.9
 *
 * Force-loaded via finsmod (flags=3: ignore vermagic+modversions).
 * Uses only k4.9 exported symbols: ioremap, iounmap, printk, __udelay.
 * MMIO r/w via volatile pointer (no io.h, avoids 6.12 ioremap_prot dep).
 *
 * Usage:
 *   adb push ac300_diag.ko finsmod /data/local/tmp/
 *   adb shell su -c "chmod +x /data/local/tmp/finsmod"
 *   adb shell su -c "/data/local/tmp/finsmod /data/local/tmp/ac300_diag.ko"
 *   adb shell dmesg | grep AC300
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/types.h>
/* Include pgtable-prot.h for PROT_DEVICE_nGnRE — does NOT define ioremap macro */
#include <asm/pgtable-prot.h>

/* K4.9 arm64 direct symbol declarations.
 * arm64 k4.9 exports __ioremap/__iounmap (not ioremap/iounmap which are macros).
 * Do NOT include <asm/io.h> or <linux/io.h> — they'd redefine ioremap as macro. */
#undef ioremap
#undef ioremap_nocache
#undef iounmap
#undef printk
#undef udelay

/* __ioremap(phys, size, prot) */
extern void __iomem *__ioremap(phys_addr_t phys_addr, size_t size, pgprot_t prot);
extern void __iounmap(volatile void __iomem *addr);
extern void __udelay(unsigned long usecs);
extern __printf(1, 2) int printk(const char *fmt, ...);

/* Use PROT_DEVICE_nGnRE from pgtable-prot.h (= 0x00e8000000000707 on k4.9 arm64) */
#define MY_IOREMAP(addr, size) \
    __ioremap((addr), (size), __pgprot(PROT_DEVICE_nGnRE))
#define MY_IOUNMAP(addr)  __iounmap(addr)

#define LOG(fmt, ...) printk(KERN_INFO "AC300-DIAG: " fmt "\n", ##__VA_ARGS__)

/* MMIO via volatile — avoids io.h / ioremap_prot dependency */
static inline u32 r32(void __iomem *base, u32 off)
{
	return *(volatile u32 *)((u8 __force *)base + off);
}

static inline void w32(void __iomem *base, u32 off, u32 val)
{
	*(volatile u32 *)((u8 __force *)base + off) = val;
}

/* ── Physical addresses ── */
#define CCU_BASE	0x03001000UL
#define SYSCON_BASE	0x03000000UL
#define PIO_BASE	0x0300B000UL
#define PWM_BASE	0x0300A000UL
#define EMAC1_BASE	0x05030000UL
#define MAP_SIZE	0x1000UL

/* CCU offsets */
#define CCU_EMAC_25M	0x970
#define CCU_EMAC_BGR	0x97C
#define CCU_PWM_BGR	0x7AC

/* PIO PA: H313 — 4 pins per CFG register */
#define PA_CFG0		0x000	/* PA0-PA3  */
#define PA_CFG1		0x004	/* PA4-PA7  */
#define PA_CFG2		0x008	/* PA8-PA11 */
#define PA_CFG3		0x00C	/* PA12-PA15 → PA12_MUX = bits[3:0] */

/* PWM offsets */
#define PWM_PCCR45	0x028
#define PWM_PCNTR45	0x02C
#define PWM_PER		0x040

/* EMAC1 offsets */
#define EMAC_CTL0	0x000
#define EMAC_CTL1	0x004
#define EMAC_MDIO_CMD	0x048
#define EMAC_MDIO_DATA	0x04C

/* k4.9 arm64 module loader requires .plt section (module-plts.c) */
asm(".section .plt,\"ax\"\n\t.byte 0\n\t.previous\n\t");

static void __iomem *ccu;
static void __iomem *syscon;
static void __iomem *pio;
static void __iomem *pwm;
static void __iomem *emac1_base;

/* MDIO read — CSR=3, read-only diagnostic */
static int mdio_read(u8 phy, u8 reg)
{
	u32 cmd = (3U << 20) | ((phy & 0x1f) << 12) | ((reg & 0x1f) << 4) | 1;
	int i;

	w32(emac1_base, EMAC_MDIO_CMD, cmd);
	for (i = 0; i < 300; i++) {
		__udelay(500);
		if (!(r32(emac1_base, EMAC_MDIO_CMD) & 1))
			return r32(emac1_base, EMAC_MDIO_DATA) & 0xFFFF;
	}
	return -1;
}

static int __init ac300_diag_init(void)
{
	u32 bgr, clk25, sc, pa3, pccr45, per, ctl0, ctl1, v;
	int r0, r2, r3, addr;

	LOG("==== AC300/EMAC1 Diagnostic (Android k4.9 force-load) ====");

	ccu        = MY_IOREMAP(CCU_BASE,    MAP_SIZE);
	syscon     = MY_IOREMAP(SYSCON_BASE, MAP_SIZE);
	pio        = MY_IOREMAP(PIO_BASE,    MAP_SIZE);
	pwm        = MY_IOREMAP(PWM_BASE,    MAP_SIZE);
	emac1_base = MY_IOREMAP(EMAC1_BASE,  MAP_SIZE);

	if (!ccu || !syscon || !pio || !pwm || !emac1_base) {
		LOG("ioremap failed!");
		goto out;
	}

	/* CCU */
	bgr   = r32(ccu, CCU_EMAC_BGR);
	clk25 = r32(ccu, CCU_EMAC_25M);
	LOG("CCU BGR(0x97c)=0x%08x  E0_CLK=%d RST=%d  E1_CLK=%d RST=%d",
	    bgr, bgr&1, (bgr>>16)&1, (bgr>>1)&1, (bgr>>17)&1);
	LOG("CLK_25M(0x970)=0x%08x  GATE=%d SRC=%d DIV=%d",
	    clk25, (clk25>>31)&1, (clk25>>24)&7, clk25&0xf);
	v = r32(ccu, CCU_PWM_BGR);
	LOG("PWM BGR(0x7ac)=0x%08x  CLK=%d RST=%d", v, v&1, (v>>16)&1);

	/* SYSCON+0x34 */
	sc = r32(syscon, 0x034);
	LOG("SYSCON+34=0x%08x  INT_PHY=%d PWRDN=%d LED=%d CLK_SEL=%d RMII=%d",
	    sc, (sc>>15)&1, (sc>>16)&1, (sc>>17)&1, (sc>>18)&1, (sc>>13)&1);

	/* PIO PA */
	LOG("PA_CFG0(PA0-3) =0x%08x", r32(pio, PA_CFG0));
	LOG("PA_CFG1(PA4-7) =0x%08x", r32(pio, PA_CFG1));
	LOG("PA_CFG2(PA8-11)=0x%08x", r32(pio, PA_CFG2));
	pa3 = r32(pio, PA_CFG3);
	LOG("PA_CFG3(PA12-15)=0x%08x  PA12_MUX=%d  (2=pwm5)", pa3, pa3&0xf);

	/* PWM */
	pccr45 = r32(pwm, PWM_PCCR45);
	per    = r32(pwm, PWM_PER);
	LOG("PWM PCCR45(+28)=0x%08x  SRC=%d GATE=%d BYPASS5=%d PRESCALE=%d",
	    pccr45, (pccr45>>7)&3, (pccr45>>4)&1, (pccr45>>5)&1, pccr45&0xf);
	LOG("PWM PER  (+40) =0x%08x  CH5=%d CH4=%d", per, (per>>5)&1, (per>>4)&1);
	v = r32(pwm, PWM_PCNTR45);
	LOG("PWM PCNTR(+2c) =0x%08x  period=%d duty=%d", v, (v>>16)&0xffff, v&0xffff);

	/* EMAC1 */
	ctl0 = r32(emac1_base, EMAC_CTL0);
	ctl1 = r32(emac1_base, EMAC_CTL1);
	LOG("EMAC1_CTL0=0x%08x", ctl0);
	LOG("EMAC1_CTL1=0x%08x  SOFT_RST=%d", ctl1, ctl1&1);
	LOG("EMAC1_MDIO_CMD =0x%08x", r32(emac1_base, EMAC_MDIO_CMD));

	/* MDIO scan — read-only */
	LOG("MDIO scan addr=0-7 (read-only, may race but safe):");
	for (addr = 0; addr < 8; addr++) {
		r0 = mdio_read(addr, 0);
		r2 = mdio_read(addr, 2);
		r3 = mdio_read(addr, 3);
		if (r0 < 0 || (u16)r0 == 0xffff)
			continue;
		LOG("  PHY@%d: r0=0x%04x r2=0x%04x r3=0x%04x ID=0x%08x%s",
		    addr, (u16)r0, (u16)r2, (u16)r3,
		    ((u32)(u16)r2 << 16) | (u16)r3,
		    (((u32)(u16)r2 << 16) | (u16)r3) == 0x00441400 ?
		        "  <-- AC300!" : "");
	}
	/* AC300 detailed read */
	LOG("AC300 addr=0 detailed:");
	for (v = 0; v <= 10; v++) {
		int rv = mdio_read(0, v);
		LOG("  reg=0x%02x: 0x%04x", v, (u16)rv);
	}

	LOG("==== Done ====");
out:
	if (ccu)        MY_IOUNMAP(ccu);
	if (syscon)     MY_IOUNMAP(syscon);
	if (pio)        MY_IOUNMAP(pio);
	if (pwm)        MY_IOUNMAP(pwm);
	if (emac1_base) MY_IOUNMAP(emac1_base);

	return -EAGAIN;  /* auto-unload after init */
}

static void __exit ac300_diag_exit(void) {}

module_init(ac300_diag_init);
module_exit(ac300_diag_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("AC300 EPHY diag H313 Android k4.9");
