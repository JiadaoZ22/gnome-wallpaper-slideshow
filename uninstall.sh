#!/usr/bin/env bash
# Remove the wallpaper slideshow user units and restore a static wallpaper.
# Does NOT delete your gallery images or the generated XML unless --purge is given.
set -euo pipefail

echo "==> Stopping and disabling user units"
systemctl --user disable --now wallpaper-slideshow.path   2>/dev/null || true
systemctl --user disable --now wallpaper-slideshow.timer  2>/dev/null || true
systemctl --user disable --now wallpaper-upscale.timer    2>/dev/null || true
systemctl --user stop wallpaper-slideshow.service         2>/dev/null || true
systemctl --user stop wallpaper-upscale.service           2>/dev/null || true

UNIT_DIR="$HOME/.config/systemd/user"
echo "==> Removing unit files"
rm -f "$UNIT_DIR/wallpaper-slideshow.service" \
      "$UNIT_DIR/wallpaper-slideshow.path" \
      "$UNIT_DIR/wallpaper-slideshow.timer" \
      "$UNIT_DIR/wallpaper-upscale.service" \
      "$UNIT_DIR/wallpaper-upscale.timer"
systemctl --user daemon-reload

echo "==> Pointing the desktop and lock screen back to a single static image"
FALLBACK="$HOME/.local/share/eog-wallpaper.jpeg"
if [ -f "$FALLBACK" ]; then
  gsettings set org.gnome.desktop.background picture-uri      "file://$FALLBACK" 2>/dev/null || true
  gsettings set org.gnome.desktop.background picture-uri-dark "file://$FALLBACK" 2>/dev/null || true
  gsettings set org.gnome.desktop.background picture-options  "zoom"              2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver picture-uri      "file://$FALLBACK" 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver picture-options  "zoom"            2>/dev/null || true
  echo "    restored $FALLBACK on desktop and lock screen"
else
  echo "    no fallback image found; choose a new wallpaper in Settings -> Background"
fi

if [ "${1:-}" = "--purge" ]; then
  echo "==> Purging config, generators, logs, XML and SR cache"
  rm -f "$HOME/.local/bin/make-slideshow" "$HOME/.local/bin/upscale-wallpapers" \
        "$HOME/.local/bin/prune-lowres"
  rm -rf "$HOME/.config/gnome-wallpaper-slideshow"
  rm -rf "$HOME/.local/state/gnome-wallpaper-slideshow"
  rm -rf "$HOME/.local/share/backgrounds/gnome-wallpaper-slideshow"
  echo "    purged (the Real-ESRGAN binary under ~/.local/opt is left intact)"
else
  echo "==> Kept config/XML/SR cache (use '$0 --purge' to remove them too)"
fi
echo "Uninstall complete."
