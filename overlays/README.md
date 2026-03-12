# Device Tree Overlay Source

WM8960 device tree overlay source for Armbian on Orange Pi Zero 2W (Allwinner H618).

## How It Works

The overlay DTS file is **compiled and merged into the base device tree at install time** using `fdtoverlay`. This approach is used because U-Boot does not reliably apply complex overlays at runtime.

At install time, `install.sh`:
1. Backs up the original DTB (only on first install)
2. Compiles the DTS source into a `.dtbo` using `dtc -@`
3. Applies it to the **backup** DTB using `fdtoverlay` (never the current DTB, to prevent double-patching)
4. Creates a symlink from the original DTB name to the patched version
5. Verifies the WM8960 node exists with `fdtget`

## File

| File | Description |
|------|-------------|
| `sun50i-h618-wm8960-armbian.dts` | Armbian overlay for H618 (tested, working) |

## What the Overlay Adds

1. **I2S0 pin configuration** — PI1/PI2 (BCLK/LRCK), PI3 (DOUT), PI4 (DIN) with 3 separate pin groups
2. **AHUB0 platform device** (`ahub0_plat`) — External I2S interface with DMA channels for the WM8960
3. **AHUB0 machine driver** (`ahub0_mach`) — Binds the WM8960 codec to the AHUB audio subsystem, creates `ahub0wm8960` sound card
4. **I2C1 WM8960 node** — Enables I2C1 (`i2c@5002400`) and declares the WM8960 codec at address 0x1a
5. **AHUB DAM enable** (`ahub_dam_plat@5097000`) — The shared AHUB register space is disabled by default in Armbian's DTB. Without this, the AHUB platform probe fails with `"no match device"`.
6. **I2C1 pinctrl** (`pinctrl-0 = <&i2c1_pi_pins>`) — Armbian's mainline kernel requires explicit pin muxing for I2C1 (PI7/PI8). The `i2c1_pi_pins` label already exists in the Armbian base DTB.

## Manual Overlay Installation

If you want to apply an overlay manually (for experimentation or debugging), here are the steps that `install.sh` automates. **All commands require root** (`sudo -i` or `sudo` prefix):

### 1. Find Your Base DTB

```bash
DTB_DIR=$(find /boot -type d -name "allwinner" -path "*/dtb*" | head -1)
echo "DTB directory: $DTB_DIR"
ls "$DTB_DIR"/sun50i-h61*-orangepi-zero2w.dtb
```

### 2. Back Up the Original DTB

```bash
BASE_DTB="$DTB_DIR/sun50i-h618-orangepi-zero2w.dtb"
cp "$BASE_DTB" "${BASE_DTB}.backup"
```

### 3. Compile the Overlay

```bash
# The -@ flag enables phandle references (required for overlays)
dtc -@ -I dts -O dtb -o /tmp/wm8960.dtbo overlays/sun50i-h618-wm8960-armbian.dts
```

You'll see warnings about missing phandle references — these are normal for overlays and can be ignored.

### 4. Apply the Overlay

```bash
# Always apply to the BACKUP, not the current DTB (prevents double-patching)
fdtoverlay -i "${BASE_DTB}.backup" -o "$DTB_DIR/sun50i-h618-orangepi-zero2w-wm8960.dtb" /tmp/wm8960.dtbo
```

### 5. Symlink the Patched DTB

```bash
ln -sf "sun50i-h618-orangepi-zero2w-wm8960.dtb" "$BASE_DTB"
```

### 6. Verify and Reboot

```bash
fdtget "$DTB_DIR/sun50i-h618-orangepi-zero2w-wm8960.dtb" /soc/i2c@5002400/wm8960@1a compatible
# Should output: wlf,wm8960
sudo reboot
```

After reboot:
```bash
i2cdetect -y 3    # Should show "UU" at 0x1a (driver bound)
aplay -l | grep wm8960
```

### Reverting to Original DTB

```bash
rm -f "$DTB_DIR/sun50i-h618-orangepi-zero2w.dtb"
cp "${DTB_DIR}/sun50i-h618-orangepi-zero2w.dtb.backup" "$DTB_DIR/sun50i-h618-orangepi-zero2w.dtb"
rm -f "$DTB_DIR/sun50i-h618-orangepi-zero2w-wm8960.dtb"
sudo reboot
```

## Technical Notes

- The overlay uses `target-path` (string paths) instead of `target = <&phandle>` references, which is required for `fdtoverlay` compatibility
- I2S0 pins are split into 3 separate groups with different pin functions (`i2s0`, `i2s0_dout0`, `i2s0_din0`)
- The WM8960 uses its onboard 24MHz crystal — no external MCLK clock reference is needed (no `clocks` property)
- The `wlf,shared-lrclk` property enables shared LRCLK mode on the WM8960
- The AHUB machine driver uses `soundcard-mach,slot-width = <32>` for 32-bit I2S frames
