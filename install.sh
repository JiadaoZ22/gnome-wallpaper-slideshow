#!/usr/bin/env bash
# Idempotent user-level installer for the GNOME wallpaper slideshow.
# No sudo: everything lives under $HOME and in the user systemd manager.
#
# Scope: this repo only installs the slideshow generator, its path/timer units,
# and the Wallpaper Ease shell extension. GPU super-resolution and low-res
# pruning live in the separate image-quality-toolkit repo (install that too if
# you want small photos enhanced); this installer does not depend on it.
set -euo pipefail

# install.sh lives at the REPO ROOT, so SRC is the script's own directory.
# Resolve robustly (readlink -f can be unreliable on FUSE mounts).
_self="${BASH_SOURCE[0]:-$0}"
case "$_self" in
  /*) SRC="$(dirname "$_self")" ;;
  *)  SRC="$(cd "$(dirname "$_self")" && pwd)" ;;
esac
[ -f "$SRC/bin/make-slideshow" ] || SRC="$(dirname "$(readlink -f "$_self")")"
[ -f "$SRC/bin/make-slideshow" ] || { echo "FATAL: cannot locate repo root (bin/make-slideshow)"; exit 1; }
CONFIG_DIR="$HOME/.config/gnome-wallpaper-slideshow"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
DEFAULT_GALLERY="$HOME/Documents/1_Gallery/b_Processed"

# Allow overriding the gallery at install time:
#   GALLERY_DIR=/path/to/pics ./install.sh
GALLERY_DIR="${GALLERY_DIR:-$DEFAULT_GALLERY}"

echo "==> Installing generator to $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC/bin/make-slideshow" "$BIN_DIR/make-slideshow"

echo "==> Writing config to $CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
  sed "s#^GALLERY_DIR=.*#GALLERY_DIR=$GALLERY_DIR#" \
      "$SRC/config/config.example" > "$CONFIG_DIR/config"
else
  echo "    existing config found; adding any newly introduced keys (values kept)"
  # Idempotent key sync: append template keys the live config lacks, so user
  # customizations to existing keys (DURATION, paths, ...) are never overwritten.
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
      *=*) key="${line%%=*}"
           grep -q "^${key}=" "$CONFIG_DIR/config" || printf '%s\n' "$line" >> "$CONFIG_DIR/config" ;;
    esac
  done < "$SRC/config/config.example"
fi
chmod 0644 "$CONFIG_DIR/config"

echo "==> Installing slideshow user units to $UNIT_DIR"
mkdir -p "$UNIT_DIR"
for unit in wallpaper-slideshow.service wallpaper-slideshow.path \
            wallpaper-slideshow.timer; do
  src_unit="$SRC/systemd/$unit"
  dst_unit="$UNIT_DIR/$unit"
  if [ "$GALLERY_DIR" != "$DEFAULT_GALLERY" ]; then
    sed -e "s#$DEFAULT_GALLERY#$GALLERY_DIR#g" "$src_unit" > "$dst_unit"
  else
    install -m 0644 "$src_unit" "$dst_unit"
  fi
done

echo "==> Reloading user systemd"
systemctl --user daemon-reload

echo "==> Enabling slideshow path watcher + timer (persistent across reboots)"
systemctl --user enable --now wallpaper-slideshow.path
systemctl --user enable --now wallpaper-slideshow.timer

echo "==> First slideshow regeneration now"
systemctl --user start wallpaper-slideshow.service || true

# The image-quality-toolkit owns wallpaper-upscale.{service,timer}. If it has
# been installed alongside, nudge its batch once (non-fatal if absent).
if [ -x "$BIN_DIR/upscale-wallpapers" ] && systemctl --user list-unit-files wallpaper-upscale.service >/dev/null 2>&1; then
  echo "==> image-quality-toolkit detected; starting its SR batch (detached)"
  systemctl --user start --no-block wallpaper-upscale.service || true
else
  echo "==> (optional) install image-quality-toolkit for GPU super-resolution"
fi

# Install the in-process shell extension that renders the smooth 60fps
# ease-in-out crossfade on the desktop. Copied (not symlinked) because the
# shell loader does not follow symlinks onto FUSE/NTFS mounts.
if [ -d "$SRC/extension" ]; then
  echo "==> Installing Wallpaper Ease shell extension"
  "$SRC/scripts/install-extension.sh" || echo "    WARN extension install step failed; native slideshow remains active"
fi

# Linger makes user services start at boot and survive logout (no-op if already on).
if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q '=no'; then
  echo "==> Enabling linger (may prompt for sudo)"
  sudo loginctl enable-linger "$USER" || echo "    WARN could not enable linger; enable manually: sudo loginctl enable-linger $USER"
else
  echo "==> Linger already enabled"
fi

echo
echo "Done. Verify with:"
echo "  systemctl --user status wallpaper-slideshow.path wallpaper-slideshow.service"
echo "  systemctl --user list-timers | grep wallpaper"
echo "  gsettings get org.gnome.desktop.background picture-uri"
echo "  gsettings get org.gnome.desktop.screensaver picture-uri"
echo "  tail -f \$HOME/.local/state/gnome-wallpaper-slideshow/run.log"
