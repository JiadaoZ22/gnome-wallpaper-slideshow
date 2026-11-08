# gnome-wallpaper-slideshow

A lightweight, daemon-free GNOME wallpaper **and lock-screen** slideshow driven
by a folder of images, with an iOS-style 60 fps eased crossfade delivered by a
small GNOME Shell extension. Built and verified on **Ubuntu 22.04 (GNOME 42)**,
single 4K monitor.

GPU super-resolution for small photos is a separate, optional repo —
[`image-quality-toolkit`](https://github.com/JiadaoZ22/image-quality-toolkit).
This repo works fully on its own; the toolkit only enhances sub-screen images
that the slideshow then picks up through a shared manifest.

## Why this design

GNOME already rotates wallpapers on a timer from a *slideshow XML* — the
desktop shell does the work, so no third-party app and no resident process is
needed. This repo provides:

1. `bin/make-slideshow` — a stdlib-only Python **oneshot** that scans a folder,
   substitutes any super-resolved versions listed in the toolkit's manifest,
   writes an atomically versioned slideshow XML plus the extension's
   `playlist.json` / `extension-config.json`, and points GNOME at it (desktop
   **and** lock screen, light + dark). It runs in milliseconds and exits.
2. A systemd **path unit** (kernel `inotify`, essentially free, no polling)
   that re-runs the generator whenever the gallery changes, plus a **timer** as
   a daily/boot backstop.
3. Burst coalescing via `flock` plus a debounce, so a bulk download can't
   trigger hundreds of regenerations.
4. A GNOME Shell **extension** that replaces the shell's choppy native 1 Hz
   linear fade with a smooth, eased crossfade (see below).

Idle cost: **0 wallpaper processes, ~0 CPU/RAM** — only the inotify watch,
timer entries, and one timeout inside the shell process.

## Fit, aspect ratio and black bars

- `picture-options` is set to **`scaled`** (GNOME contain fit): the whole image
  is visible, its **aspect ratio is always preserved** (never stretched), and
  any unfilled area is black. Vertical and ultrawide photos get side/top bars;
  nothing is cropped (unlike `zoom`).
- **Never upscale past the enhanced size.** Images at/above the screen in one
  dimension are only downscaled. If the optional image-quality-toolkit is
  installed, images smaller than the screen in **both** dimensions are
  Real-ESRGAN-enhanced (×4) first; if a photo is so small that even ×4 does not
  reach the screen, it is centered at its true enhanced size on a black canvas
  rather than being enlarged further.

## Smooth iOS-style crossfade (the Wallpaper Ease extension)

GNOME 42's **native** slideshow crossfade cannot do an iOS-style nonlinear
transition — verified against the shell source on this machine:

- `ui/background.js` drives the XML slideshow with a **linear** opacity blend
  redrawn at most **once per second** (`ANIMATION_MIN_WAKEUP_INTERVAL = 1.0`).
- The slideshow parser (`libgnome-desktop-3`) has no transition `<type>` or
  easing/curve element — `<duration>` is the only knob. A 2.5 s native fade
  therefore steps through ~2–3 visible jumps and, on contain-fit images with
  black letterbox, reads as a fade-through-dark.

This repo ships a small **in-process GNOME Shell extension**
(`extension/gnome-wallpaper-ease@…`) that takes over the *desktop* background
and renders the swap at the shell's full frame rate:

- two `Meta.Background` actors (contain-fit, identical black-letterbox rendering
  to the native shell) crossfaded with
  `Clutter.AnimationMode.EASE_IN_OUT_CUBIC` — the iOS-style S-curve: slow start,
  fast mid-swap, slow settle;
- the **new image is fully decoded before the fade starts** and the old actor
  stays fully opaque underneath, so the screen is never under-filled (no black
  dip, no missing-image flash);
- it also retargets the **Activities overview** and the
  **Ctrl+Alt+arrow workspace-switch** backgrounds — separate shell
  `BackgroundManager`s that otherwise keep showing the native slideshow and
  drift to a different image (a different wallpaper flashing when you press
  **Win** or switch desktops). No restore happens mid-animation, so there is no
  flash when the overview closes or a switch completes;
- reads a JSON `playlist.json` + `extension-config.json` written by
  `make-slideshow` and hot-reloads them via `GFileMonitor` — change
  `DURATION`/`TRANSITION`, regenerate, and the new timing applies **without a
  shell reload**;
- idle cost is one `GLib.timeout` inside the shell process — no extra daemon;
- it only **hides** the native desktop background while active and restores it
  on disable; gsettings are never modified, so the **lock screen keeps using
  the native XML slideshow** and everything keeps working if the extension is
  absent, disabled, or errors out (defensive try/catch retains the native bg).

### Install / enable the extension

`./install.sh` runs `scripts/install-extension.sh`, which **copies** the
extension into `~/.local/share/gnome-shell/extensions/` (a copy, not a symlink —
the loader does not reliably follow symlinks onto FUSE/NTFS), flips
`disable-user-extensions=false`, and adds the UUID to `enabled-extensions`.

A brand-new extension is only scanned at shell startup, and GNOME 42 provides
no live rescan over D-Bus (`ReloadExtension` is unimplemented; `Eval` is
locked). So after the first install, reload the shell **once**:

- **X11:** `Alt+F2` → type `r` → Enter (windows stay open; ~1–2 s blink).
- **Wayland:** log out and back in.

Then verify:

```bash
gnome-extensions info gnome-wallpaper-ease@jiadaoz22.github.com
./scripts/healthcheck.sh
journalctl --user -b | grep wallpaper-ease
```

Editing `extension.js` requires re-running `scripts/install-extension.sh` and
reloading the shell; editing only timing/playlist does not (the extension
monitors its JSON inputs).

### Numeric knobs

`DURATION` = image hold (s), `TRANSITION` = fade length (s). Defaults:
**17.5 s hold / 2.5 s crossfade.** The same values feed the extension
(`interval_ms`/`fade_ms`) and the native XML used by the lock screen.

### Random order

Switching is randomized at two layers:

- `make-slideshow` writes a Fisher–Yates-shuffled playlist (`RANDOM=1`), which
  also sets the order of the native XML slideshow used on the lock screen.
- The shell extension then plays its own **deck of cards**: it walks a shuffled
  index deck so every image appears exactly once per cycle with no repeats, and
  when the deck is exhausted it reshuffles — guaranteeing the new cycle opens
  on a different image than the previous one ended on. So the order stays random
  indefinitely rather than replaying one fixed permutation every ~5 h. Set
  `RANDOM=0` in the config for deterministic sorted order on regeneration (the
  extension's deck still shuffles; the config governs the generated XML/playlist
  baseline).

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
./install.sh
```

The installer deploys the generator and the three slideshow user units, syncs
any new config keys into an existing config (your values are never
overwritten), starts the watcher/timer, and installs + enables the extension.
If the image-quality-toolkit is also present it kicks off its SR batch;
otherwise it simply notes that SR is optional.

Custom gallery or timings:

```bash
GALLERY_DIR=/some/other/folder ./install.sh          # at install time
# or afterwards, edit:
nano ~/.config/gnome-wallpaper-slideshow/config
systemctl --user start wallpaper-slideshow.service
```

`config` keys: `GALLERY_DIR`, `DURATION` (seconds per image), `TRANSITION`
(cross-fade seconds), `PICTURE_OPTIONS`, `SET_LOCKSCREEN`, `RANDOM` (1/0),
`EXTENSIONS`, `KEEP`, `DEBOUNCE`.

## Optional GPU super-resolution (image-quality-toolkit)

Small photos are enhanced by the separate, self-contained
[**image-quality-toolkit**](https://github.com/JiadaoZ22/image-quality-toolkit)
repo (portable Real-ESRGAN ncnn-Vulkan engine vendored; no CUDA/PyTorch). Its
`wallpaper-upscale.service` runs `prune-lowres` → `upscale-wallpapers` →
`make-slideshow --force` on a timer and writes its manifest to the exact path
this repo's generator reads
(`~/.local/state/gnome-wallpaper-slideshow/upscale-manifest.json`), so SR images
go live automatically. The two integrate through:

- `~/.config/image-quality-toolkit/wallpaper-integration.env` (installed by the
  toolkit) which points its neutral defaults at this repo's gallery/cache/state;
- the shared config file `~/.config/gnome-wallpaper-slideshow/config`.

Without the toolkit, the slideshow simply uses original images with contain
fit and black bars — nothing breaks. See the toolkit's README for
`prune-lowres` (recoverable quarantine of sub-`MIN_DIMENSION` images), the SR
cache layout, GPU device selection, and its own troubleshooting.

## Verify

```bash
systemctl --user status wallpaper-slideshow.path wallpaper-slideshow.timer
systemctl --user list-timers | grep wallpaper
gsettings get org.gnome.desktop.background picture-uri
gsettings get org.gnome.desktop.screensaver picture-uri
tail -f ~/.local/state/gnome-wallpaper-slideshow/run.log
```

Trigger actions manually:

```bash
systemctl --user start wallpaper-slideshow.service   # rebuild slideshow now
~/.local/bin/make-slideshow --force --verbose         # direct, bypass debounce
~/.local/bin/make-slideshow --no-apply                # write XML, don't touch gsettings
```

Test the watcher: add/remove an image in the gallery and watch the log within
a couple of seconds (the service adds a 2 s settle delay to merge bursts).

## Uninstall

```bash
# Remove the shell extension first (restores the native desktop background):
gnome-extensions disable gnome-wallpaper-ease@jiadaoz22.github.com
rm -rf ~/.local/share/gnome-shell/extensions/gnome-wallpaper-ease@jiadaoz22.github.com
./uninstall.sh           # remove units, restore a static wallpaper
./uninstall.sh --purge   # also delete config, generator, logs and generated XML
```

The image-quality-toolkit and its SR cache are left intact; remove them with
that repo's own uninstaller.

## Layout

```
bin/make-slideshow            oneshot slideshow + playlist/config generator
extension/<uuid>/             GNOME Shell extension: 60fps EASE_IN_OUT_CUBIC fade
  extension.js                  two Meta.Background actors; overview + switch sync
  metadata.json / stylesheet.css
scripts/
  install-extension.sh        copy + enable the extension (idempotent)
  healthcheck.sh              read-only end-to-end verification
config/config.example         user config template
systemd/
  wallpaper-slideshow.service oneshot regeneration job
  wallpaper-slideshow.path    inotify watcher on the gallery
  wallpaper-slideshow.timer   daily/boot backstop
install.sh / uninstall.sh     user-level (no root except optional linger)
```

The `wallpaper-upscale.{service,timer}` units and the `upscale-wallpapers` /
`prune-lowres` binaries live in **image-quality-toolkit**, not here.

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

### Different image flashes when opening Activities (Win) or switching desktops

Those surfaces use separate shell `BackgroundManager`s. The extension retargets
both the overview (`Main.overview` `showing`/`shown`) and the workspace-switch
groups (`global.window_manager` `switch-workspace`) to the current image. If a
mismatch returns, confirm the extension is `ENABLED` and was reloaded after the
last `extension.js` edit, then check `journalctl --user -b | grep wallpaper-ease`
for a retarget error.

## Limitations

- The path unit watches the gallery directory itself (non-recursive inotify);
  changes made only in nested subfolders are picked up by the daily timer or
  the next top-level event. The default gallery is flat.
- GNOME's static-wallpaper XML format doesn't play video; `.mp4` is ignored.
- This targets GNOME Shell (Ubuntu). Other desktops (KDE, Xfce) use different
  wallpaper mechanisms.
- The lock screen intentionally keeps the native XML slideshow (it must work
  before/outside the session), so it does not get the eased crossfade.
