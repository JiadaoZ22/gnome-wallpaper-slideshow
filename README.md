# gnome-wallpaper-slideshow

A lightweight, daemon-free GNOME wallpaper slideshow driven by a folder of
images. Built and verified on **Ubuntu 22.04 (GNOME 42, Wayland)**.

## Why this design

GNOME already rotates wallpapers on a timer from a *slideshow XML* — the
desktop shell does the work, so no third-party app and no resident process is
needed. This repo only provides:

1. `bin/make-slideshow` — a stdlib-only Python **oneshot** that scans a folder,
   writes an atomically-versioned slideshow XML, and points GNOME at it
   (light + dark mode). It runs in milliseconds and exits.
2. A systemd **path unit** (kernel `inotify`, essentially free, no polling)
   that re-runs the generator whenever the gallery changes.
3. A systemd **timer** as a daily/boot backstop (covers nested-subdirectory
   changes and any missed event).
4. A **service** (oneshot) that ties them together, with burst coalescing via
   `flock` so a bulk download can't trigger hundreds of regenerations.

Resource cost when idle: **0 processes, ~0 CPU/RAM** — only the kernel inotify
watch and a timer entry. Contrast with Shotwell/Variety, which install a large
dependency tree and/or keep a GUI/daemon running and don't auto-refresh a
folder as cleanly.

## What it does

- Recursively includes `jpg jpeg png webp bmp gif`; skips hidden files and
  partial downloads (`.aliyunpan-downloading`, `.part`, `.tmp`, `.crdownload`, …).
- Handles spaces / non-ASCII paths (percent-encoded URIs, XML-escaped).
- Shuffles order on each regeneration (or sorted mode via `RANDOM=0`).
- Coalesces bulk-download bursts: an inotify debounce (`DEBOUNCE=20`s) plus a
  `flock` means hundreds of simultaneous file events produce a single
  regeneration; `make-slideshow --force` bypasses it, and the daily timer runs
  far outside the window so scheduled builds always proceed.
- Writes `~/.local/share/backgrounds/gnome-wallpaper-slideshow/slideshow-<ts>.xml`
  atomically, keeps a `current.xml` symlink, and prunes old versions.
- Sets both `picture-uri` and `picture-uri-dark`, plus `picture-options`.
- Survives logout/reboot: user units + `loginctl enable-linger`.
- If the folder is empty/missing or no graphical bus is present, it logs and
  exits 0 — it never enters a failed-restart loop.

## Install

```bash
git clone https://github.com/JiadaoZ22/gnome-wallpaper-slideshow.git
cd gnome-wallpaper-slideshow
./install.sh
```

Custom gallery or timings:

```bash
GALLERY_DIR=/some/other/folder ./install.sh          # at install time
# or afterwards, edit:
nano ~/.config/gnome-wallpaper-slideshow/config
systemctl --user start wallpaper-slideshow.service
```

`config` keys: `GALLERY_DIR`, `DURATION` (seconds per image), `TRANSITION`
(cross-fade seconds), `PICTURE_OPTIONS`, `RANDOM` (1/0), `EXTENSIONS`, `KEEP`,
`DEBOUNCE` (inotify quiet window in seconds, 0 to disable).

## Verify

```bash
systemctl --user status wallpaper-slideshow.path wallpaper-slideshow.timer
systemctl --user list-timers | grep wallpaper
gsettings get org.gnome.desktop.background picture-uri
tail -f ~/.local/state/gnome-wallpaper-slideshow/run.log
```

Trigger a regeneration manually:

```bash
systemctl --user start wallpaper-slideshow.service
# or run the generator directly (--no-apply writes XML without touching gsettings):
~/.local/bin/make-slideshow --verbose
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
bin/make-slideshow            oneshot generator (Python 3 stdlib)
config/config.example         user config template
systemd/
  wallpaper-slideshow.service oneshot regeneration job
  wallpaper-slideshow.path    inotify watcher on the gallery
  wallpaper-slideshow.timer   daily/boot backstop
install.sh / uninstall.sh     user-level (no root except optional linger)
```

## Limitations

- The path unit watches the gallery directory itself (non-recursive inotify);
  changes made only in nested subfolders are picked up by the daily timer or
  the next top-level event. The default gallery is flat.
- GNOME's static-wallpaper XML format doesn't play video; `.mp4` is ignored.
- This targets GNOME Shell (Ubuntu). Other desktops (KDE, Xfce) use different
  wallpaper mechanisms.
