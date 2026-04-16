# DKMS — WM8960 Patched Kernel Module

This directory contains everything needed to build the WM8960 codec kernel module via [DKMS](https://github.com/dell/dkms) (Dynamic Kernel Module Support). The module is built from mainline kernel source with patches applied to fix PLL clocking issues on boards with an onboard 24MHz crystal and no Linux clock driver.

## Why DKMS?

The mainline `snd-soc-wm8960` kernel module has bugs that affect boards like the WM8960 Audio HAT on the Orange Pi Zero 2W. Rather than shipping pre-compiled `.ko` files (which break on kernel updates), DKMS builds the patched module from source against the running kernel's headers. This means:

- Survives kernel upgrades (DKMS rebuilds automatically)
- No version/vermagic mismatches

## Patches Applied

Changes vs mainline `sound/soc/codecs/wm8960.c` (kernel.org):

| # | Location | Change | Why |
|---|----------|--------|-----|
| 1 | `wm8960_set_dai_sysclk()` | Force `clk_id = WM8960_SYSCLK_PLL` and `freq_in = 24000000` | Board has 24MHz onboard crystal with no Linux clock driver — force PLL mode so the codec generates correct internal clocks |
| 2 | `wm8960_configure_clocking()` | Comment out `return 0` in slave mode check | Mainline skips ALL clock programming in slave mode — this lets PLL configuration proceed |
| 3 | `wm8960_configure_clocking()` | Add `WM8960_SYSCLK_PLL` fallback in sysclk switch | When the machine driver never calls `set_dai_sysclk` (Allwinner AHUB), `sysclk` is 0 — allow PLL mode to auto-calculate output frequency via `configure_pll()` |
| 4 | `wm8960_i2c_probe()` | Set `clk_id = WM8960_SYSCLK_PLL` and `freq_in = 24000000` at probe | Ensures PLL mode is active from boot, even if `set_dai_sysclk` is never called |
| 5 | DAPM routes | Add `MICB` supply routes to Boost Mixers | Ensures mic bias voltage powers on automatically during capture |

Patches 1-4 fix the "slave mode, but proceeding with no clock configuration" issue and make the codec generate correct internal clocks for any requested rate. The codec itself supports 8kHz-48kHz, but on the Allwinner AHUB platform the I2S bus is configured for a fixed rate per session — applications should use the `default` ALSA device (or `plughw`) so dmix/dsnoop handles rate conversion. See [Sample Rates](../README.md#sample-rates) in the main README for usage details.

Patch 5 is from Waveshare/Seeed's driver forks and improves microphone reliability.

### Additional Compatibility

| Feature | Details |
|---------|---------|
| DAIFMT compat | `#ifndef` defines for kernel 6.18+ master/slave → provider/consumer rename |
| CCU PLL workaround | `wm8960_check_soc_pll()` detects and fixes Allwinner CCU PLL lock regression on kernel 6.13+ |
| H616/H618 SoC guard | `of_machine_is_compatible()` check ensures PLL workaround only runs on Allwinner H616/H618 |
| Rate-aware fallback | PLL values for both 48kHz family (98.304 MHz) and 44.1kHz family (90.317 MHz) |

## Files

| File | Purpose |
|------|---------|
| `wm8960.c` | Patched WM8960 codec driver source |
| `wm8960.h` | WM8960 register definitions header |
| `Makefile` | Out-of-tree kernel module build rules |
| `dkms.conf` | DKMS build configuration |

## Kernel Headers

DKMS requires kernel headers at `/lib/modules/$(uname -r)/build` to compile modules.

Install via apt:
```bash
apt install linux-headers-current-sunxi64
```

The installer handles this automatically.

## References

- [Mainline wm8960.c (kernel.org)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/sound/soc/codecs/wm8960.c)
- [Waveshare WM8960 driver fork](https://github.com/waveshareteam/WM8960-Audio-HAT)
- [Seeed/HinTak WM8960 driver fork](https://github.com/HinTak/seeed-voicecard)
- [DKMS documentation](https://github.com/dell/dkms)
