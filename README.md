# gnome-wallpaper-slideshow

A lightweight, daemon-free GNOME wallpaper **and lock-screen** slideshow driven
by a folder of images, with optional GPU super-resolution for small photos.
Built and verified on **Ubuntu 22.04 (GNOME 42, Wayland)**, RTX 5090 D.

## Why this design

GNOME already rotates wallpapers on a timer from a *slideshow XML* — the
desktop shell does the work, so no third-party app and no resident process is
needed. This repo provides:

1. `bin/make-slideshow` — a stdlib-only Python **oneshot** that scans a folder,
   substitutes super-resolved versions of small images, writes an atomically
   versioned slideshow XML, and points GNOME at it (desktop **and** lock screen,
   light + dark). It runs in milliseconds and exits.
2. `bin/upscale-wallpapers` — a **batch** tool that super-resolves images
   smaller than the screen with [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
   (ncnn Vulkan, GPU), with a Pillow letterbox fallback when the engine is absent.
3. A systemd **path unit** (kernel `inotify`, essentially free, no polling)
   that re-runs the generator whenever the gallery changes, plus **timers** as
   daily/boot backstops, and a separate SR service+timer.
4. Burst coalescing via `flock` plus a debounce, so a bulk download can't
   trigger hundreds of regenerations.

Idle cost: **0 wallpaper processes, ~0 CPU/RAM** — only the inotify watch,
timer entries, and an occasional GPU batch. Contrast with Shotwell/Variety,
which install a large dependency tree and/or keep a GUI/daemon running and
don't auto-refresh a folder as cleanly.

## Fit, aspect ratio and black bars

- `picture-options` is set to **`scaled`** (GNOME contain fit): the whole image
  is visible, its **aspect ratio is always preserved** (never stretched), and
  any unfilled area is black. Vertical and ultrawide photos get side/top bars;
  nothing is cropped (unlike `zoom`).
- **Never upscale past the enhanced size.** Images at/above the screen in one
  dimension are only downscaled. Images smaller than the screen in **both**
  dimensions are Real-ESRGAN-enhanced (×4) first; if a photo is so small that
  even ×4 does not reach the screen, it is centered at its true SR size on a
  black 4K canvas instead of being enlarged further.

## Crossfade tuning (avoid the fade-to-black)

GNOME 42's slideshow parser supports exactly one transition — an `overlay`
crossfade — and exposes **no `<type>` element** (adding one can fail the whole
parse and black out the background); its only knob is `<duration>`. Each mutter
background is composited as a solid `primary-color` layer (black here) with the
image texture on top; in contain fit the letterbox reveals that black. During a
crossfade the *new* background actor ramps opacity over the old one, so with a
**long** duration its black regions (and a texture still decoding) dominate for
most of the fade — it reads as "fades out to dark, then the new image appears".

Keep `TRANSITION` short so it is a quick, smooth dissolve rather than a
fade-through-black:

- `0.6` (default) — quick smooth dissolve; good for 15 s rotation.
- `0.3–0.5` — snappier; use if any dark dip is still noticeable.
- `0` — instant hard cut, no blending at all.
- Avoid `≥1.5` on contain-fit/letterboxed wallpapers: that is where the
  fade-to-black effect returns. (Stock GNOME only uses 5 s fades because each
  image holds for ~30 min and they are full-bleed, not letterboxed.)

Change it in `~/.config/gnome-wallpaper-slideshow/config` then
`systemctl --user start wallpaper-slideshow.service`.

## What it does

- Recursively includes `jpg jpeg png webp bmp gif`; skips hidden files and
  partial downloads (`.aliyunpan-downloading`, `.part`, `.tmp`, `.crdownload`, …).
- Handles spaces / parentheses / non-ASCII paths. The slideshow XML uses
  **raw absolute filesystem paths** (what GNOME Shell expects) with only XML
  special-char escaping — GNOME does its own percent-encoding; a `file://` URI
  inside `<file>` breaks loading (see Troubleshooting). The `gsettings` value
  itself is still a proper `file://` URI pointing at the XML document.
- Shuffles order on each regeneration (or sorted mode via `RANDOM=0`).
- Coalesces bulk-download bursts: an inotify debounce (`DEBOUNCE=20`s) plus a
  `flock` means hundreds of simultaneous file events produce a single
  regeneration; `make-slideshow --force` bypasses it, and the daily timer runs
  far outside the window so scheduled builds always proceed.
- Writes `~/.local/share/backgrounds/gnome-wallpaper-slideshow/slideshow-<ts>.xml`
  atomically, keeps a `current.xml` symlink, and prunes old versions.
- Sets both `org.gnome.desktop.background` (light+dark) **and**
  `org.gnome.desktop.screensaver` (lock screen) to the same slideshow
  (`SET_LOCKSCREEN=1`).
- Survives logout/reboot: user units + `loginctl enable-linger`.
- If the folder is empty/missing or no graphical bus is present, it logs and
  exits 0 — it never enters a failed-restart loop.

## Install

```bash
git clone https://github.com/JiadaoZ22/gnome-wallpaper-slideshow.git
cd gnome-wallpaper-slideshow
# Optional GPU engine (portable; no CUDA/PyTorch), expected at:
#   ~/.local/opt/realesrgan-ncnn-vulkan/realesrgan-ncnn-vulkan
# Without it, small images use the Pillow letterbox fallback instead.
./install.sh
```

The installer deploys both binaries and all five user units, syncs any new
config keys into an existing config (your values are never overwritten),
starts the slideshow watcher/timers, and launches the SR batch with
`--no-block` (it does not wait for the GPU job to finish).

Custom gallery or timings:

```bash
GALLERY_DIR=/some/other/folder ./install.sh          # at install time
# or afterwards, edit:
nano ~/.config/gnome-wallpaper-slideshow/config
systemctl --user start wallpaper-slideshow.service
```

`config` keys: `GALLERY_DIR`, `DURATION` (seconds per image), `TRANSITION`
(cross-fade seconds), `PICTURE_OPTIONS`, `SET_LOCKSCREEN`, `RANDOM` (1/0),
`EXTENSIONS`, `KEEP`, `DEBOUNCE`, `SCREEN_W/H`, `MIN_DIMENSION`, `SR_MODEL`,
`TILE_SIZE`, `JPEG_QUALITY`.

## Low-resolution pruning

`bin/prune-lowres` enforces a quality floor: any image whose **width or height**
is below `MIN_DIMENSION` (default 1080 px) is too low-res for the 4K display and
is moved out of the gallery. It runs automatically as the `ExecStartPre` of the
SR service, so a prune happens before every batch and on the daily timer.

- It **moves, never hard-deletes**. Offenders go to a dated sibling folder
  `../_lowres_quarantine_<timestamp>/` (outside the watched gallery), preserving
  relative paths, with a `manifest.json`/`manifest.txt` recording original and
  new paths plus dimensions — fully reversible by moving files back.
- It also removes the moved images' SR-manifest entries and cached outputs so no
  stale reference can reach the slideshow.
- Set `MIN_DIMENSION=0` to disable. Inspect without touching anything:
  `~/.local/bin/prune-lowres --dry-run`.

## Super-resolution details

- Engine: Real-ESRGAN ncnn Vulkan, model `realesrgan-x4plus` (general photos),
  GPU device 0. A photo is processed only when it is below the screen in both
  dimensions; results are cached under
  `~/.local/share/gnome-wallpaper-slideshow/upscaled/<hash>/prepared.jpg` and
  keyed by source mtime, so re-runs only process new/changed images.
- Run on demand: `~/.local/bin/upscale-wallpapers [--rebuild] [--limit N]`.
- `wallpaper-upscale.timer` runs it daily (04:05) and 30 min after boot. Each
  run is `prune-lowres` → `upscale-wallpapers` → `make-slideshow --force`.
- The upscale service's `ExecStartPost` rebuilds the slideshow so new SR images
  go live automatically. `make-slideshow` degrades gracefully: if a prepared
  file is missing, it references the original image instead.

## Verify

```bash
systemctl --user status wallpaper-slideshow.path wallpaper-upscale.timer
systemctl --user list-timers | grep wallpaper
gsettings get org.gnome.desktop.background picture-uri
gsettings get org.gnome.desktop.screensaver picture-uri
tail -f ~/.local/state/gnome-wallpaper-slideshow/run.log
tail -f ~/.local/state/gnome-wallpaper-slideshow/upscale.log
```

Trigger actions manually:

```bash
systemctl --user start wallpaper-slideshow.service   # rebuild slideshow now
systemctl --user start wallpaper-upscale.service      # prune + SR batch + rebuild
~/.local/bin/prune-lowres --dry-run                   # list sub-MIN_DIMENSION images
~/.local/bin/prune-lowres                             # quarantine them now
~/.local/bin/make-slideshow --force --verbose         # direct, bypass debounce
~/.local/bin/make-slideshow --no-apply                # write XML, don't touch gsettings
```

Test the watcher: add/remove an image in the gallery and watch the log within
a couple of seconds (the service adds a 2 s settle delay to merge bursts).

## Uninstall

```bash
./uninstall.sh           # remove units, restore a static wallpaper
./uninstall.sh --purge   # also delete config, generator, logs and generated XML
```

## Layout

```
bin/make-slideshow            oneshot slideshow generator (Python stdlib)
bin/upscale-wallpapers        batch Real-ESRGAN + letterbox (Pillow + ncnn)
bin/prune-lowres              move sub-MIN_DIMENSION images to a quarantine
config/config.example         user config template
systemd/
  wallpaper-slideshow.service oneshot regeneration job
  wallpaper-slideshow.path    inotify watcher on the gallery
  wallpaper-slideshow.timer   daily/boot backstop
  wallpaper-upscale.service   prune (ExecStartPre) + GPU SR + slideshow rebuild
  wallpaper-upscale.timer     daily/boot SR re-scan
install.sh / uninstall.sh     user-level (no root except optional linger)
```

## Troubleshooting

### Desktop background is solid black/dark and never changes

Check the shell log:

```bash
journalctl --user -b | grep -i 'Failed to load background'
```

If you see a path like `.../file:/home/.../photo.jpg: No such file`, the
slideshow XML was written with `file://` URIs inside `<file>/<from>/<to>`.
GNOME Shell resolves those as **relative to `$HOME`**, so every image fails and
it falls back to the solid theme color. The correct content is a raw absolute
path: `<file>/home/you/Pictures/x.jpg</file>` (this generator already does).
Note the two layers differ on purpose:

- *inside the slideshow XML* → raw absolute path
- *the `gsettings picture-uri` value* → `file:///…/slideshow-….xml` (a URI)

After editing the generator, **re-run `./install.sh`** — the service runs the
deployed `~/.local/bin/make-slideshow`, so a source-only fix has no effect.

### Real-ESRGAN reports an invalid GPU device

Valid `-g` ids are integers (`0`, `1`, …), not `-1`. Here device `0` is the
NVIDIA RTX 5090 D; other ids can be an llvmpipe CPU adapter. The scripts pin
`-g 0`. Check which GPUs the engine sees:

```bash
~/.local/opt/realesrgan-ncnn-vulkan/realesrgan-ncnn-vulkan 2>&1 | grep -i gpu
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

If the binary is missing entirely, `upscale-wallpapers` still succeeds via its
Pillow letterbox fallback (correct fit, just not AI-enhanced), so the pipeline
never blocks.

## Limitations

- The path unit watches the gallery directory itself (non-recursive inotify);
  changes made only in nested subfolders are picked up by the daily timer or
  the next top-level event. The default gallery is flat.
- GNOME's static-wallpaper XML format doesn't play video; `.mp4` is ignored.
- This targets GNOME Shell (Ubuntu). Other desktops (KDE, Xfce) use different
  wallpaper mechanisms.
