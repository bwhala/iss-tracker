# Display performance assessment — measured 2026-08-09

Measured on the live device with `bench/display_bench.py` (service stopped
during SPI tests). Device state at time of test: `throttled=0x50005`
(under-voltage, actively throttled), core clock 250 MHz, ARM 600 MHz.

## Root causes found (in order of impact)

1. **Chronic under-voltage** (`throttled=0x50005` since boot). ARM capped at
   600 MHz (rated 1200), turbo disabled. Fix: proper 5.1 V / 2.5 A supply and
   a thick cable. Under-voltage overrides every config.txt turbo setting.
2. **`enable_uart=1` pins the core clock to 250 MHz** on a Pi 3 (mini-UART is
   primary because Bluetooth holds the PL011). Documented behavior; the
   configured `core_freq=400` is silently ignored. Exception: with
   `force_turbo=1` the core is fixed at 400 instead and the serial console
   keeps working.
3. **The kernel computes SPI divisors against the nominal 400 MHz core** (by
   design — commit b76c8d5 "Read max core clock from firmware") while the
   real core runs 250 MHz. Requested 48 MHz → cdiv 10 → **actual SCLK 25 MHz**.

## Measured numbers (throttled state, actual clocks in parens)

| Requested | Actual SCLK | Full frame (307 KB) | Disc loop (100 KB end-to-end) |
|-----------|------------|--------------------:|------------------------------:|
| 32 MHz    | 17.9 MHz   | 139.9 ms (7.1 fps)  | 47.0 ms (21.3 fps) |
| 48 MHz    | 25.0 MHz   | 100.4 ms (10.0 fps) | 33.9 ms (29.5 fps) |
| 62.5 MHz  | 31.25 MHz  | 80.5 ms (12.4 fps)  | 27.4 ms (36.5 fps) |
| 80 MHz    | 41.7 MHz   | 60.5 ms (16.5 fps)  | 20.9 ms (47.8 fps) |
| 100 MHz   | 62.5 MHz   | 41.6 ms (24.0 fps)  | 14.5 ms (**68.9 fps**) |

Actual SCLK = 250 MHz / cdiv, where cdiv = even-round-up(400 MHz / requested).
All transfers electrically succeeded up to 62.5 MHz actual; **pixel integrity
above ~40 MHz not yet visually verified** (`--hold` mode exists for that).

CPU-side costs (at throttled 600 MHz ARM — halve them after the PSU fix):
full-frame numpy copy 0.45 ms, disc copy 0.20 ms, region extract 0.20 ms,
marker composite 0.23 ms, GPIO.output via rpi-lgpio 65 µs, set_window ~0.5 ms.
**Python/numpy is not the bottleneck; the wire is.** spidev `writebytes2`
releases the GIL and the kernel uses DMA for transfers ≥ 96 bytes; with
bufsiz=307200 a full frame is a single ioctl.

## Validated ceiling after fixes (core locked at 400 MHz)

Achievable SCLKs: 40 (cdiv 10), 50 (cdiv 8), 66.7 (cdiv 6), 100 (cdiv 4) MHz.
ST7796S datasheet rates 15 MHz; Waveshare themselves ship this panel at
48 MHz; community reports 40–80 MHz reliable on short wiring. 50 MHz is a
safe bet; 66.7 MHz likely fine (verify visually); 100 MHz is a lottery.

| SCLK | Full frame | Globe disc (100 KB) | Disc fps ceiling |
|------|-----------:|--------------------:|-----------------:|
| 40 MHz  | 61 ms  | 20 ms + ~1 ms ovh | ~45 fps |
| 50 MHz  | 49 ms  | 16 ms             | ~55 fps |
| 66.7 MHz| 37 ms  | 12 ms             | ~70 fps |

Full-screen 60 fps needs ~148 Mbit/s — physically impossible on this bus.
Globe-disc-only 60 fps is within budget at ≥ 50 MHz.

## Recommended sequence

1. Replace PSU/cable → `vcgencmd get_throttled` must read `0x0`.
2. Add `force_turbo=1` to config.txt (keeps serial console, fixes core at
   400 MHz, stabilizes SPI clock; no warranty bit without over_voltage).
3. Re-run `bench/display_bench.py spi --speeds 50,66.7 --hold 10` and
   visually verify panel integrity at each speed.
4. Set `SPI_SPEED_HZ=50000000` (or 66.7 M if step 3 clean) in `.env`.
5. Raise `num_frames` in theme.toml to lift the globe update rate
   (frame rate = num_frames / rotation_period_sec; 480/14 s ≈ 34 fps).
   RAM: full-frame cache is 307 KB/frame — 480 frames = 147 MB, still under
   the service's 450 MB cap, but consider storing only the 224×224 disc
   region per frame (100 KB/frame) if going higher.

## Dead ends (validated, do not pursue)

- **fbcp-ili9341** and all ST7796S forks: built on DispmanX, removed in
  Bookworm+, "era has come to an end" per its own README. The one 2026
  KMS-based revival gets 8–10 fps. Also architecturally irrelevant here
  (it mirrors a GPU screen; this app renders its own frames).
- **C/Rust rewrite**: C reaches the same wire ceiling Python already reaches
  (69 fps sustained measured from Python). No gain.
- **Vsync/tearing elimination**: the (F) board does not route the ST7796S TE
  pin. Tearing can be shaped (FRMCTR1 panel refresh tuning, write in scan
  order) but not eliminated on SPI.

## Future option (bigger lift, kernel-supported)

The `panel-mipi-dbi` DRM driver is Waveshare's official modern path for this
exact panel (`dtoverlay=mipi-dbi-spi,speed=...` + `st7796s.bin` firmware,
kernel ≥ 6.6.51). Kernel-side damage rects, swab16, and DMA; the app would
blit into a dumb buffer and commit damage rectangles. Same wire ceiling —
worth it mainly if userspace overhead ever becomes the limit (it currently
is not).
