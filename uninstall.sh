#!/usr/bin/env bash
# Remove the wallpaper slideshow user units and restore a static wallpaper.
# Does NOT delete your images or the generated XML unless --purge is given.
set -euo pipefail

echo "==> Stopping and disabling user units"
systemctl --user disable --now wallpaper-slideshow.path 2>/dev/null || true
systemctl --user disable --now wallpaper-slideshow.timer 2>/dev/null || true
systemctl --user stop wallpaper-slideshow.service 2>/dev/null || true

UNIT_DIR="$HOME/.config/systemd/user"
echo "==> Removing unit files"
rm -f "$UNIT_DIR/wallpaper-slideshow.service" \
      "$UNIT_DIR/wallpaper-slideshow.path" \
      "$UNIT_DIR/wallpaper-slideshow.timer"
systemctl --user daemon-reload

echo "==> Pointing the background back to a single static image"
FALLBACK="$HOME/.local/share/eog-wallpaper.jpeg"
if [ -f "$FALLBACK" ]; then
  gsettings set org.gnome.desktop.background picture-uri      "file://$FALLBACK" 2>/dev/null || true
  gsettings set org.gnome.desktop.background picture-uri-dark "file://$FALLBACK" 2>/dev/null || true
  echo "    restored $FALLBACK"
else
  echo "    no fallback image found; choose a new wallpaper in Settings -> Background"
fi

if [ "${1:-}" = "--purge" ]; then
  echo "==> Purging config, generator, logs and generated XML"
  rm -f "$HOME/.local/bin/make-slideshow"
  rm -rf "$HOME/.config/gnome-wallpaper-slideshow"
  rm -rf "$HOME/.local/state/gnome-wallpaper-slideshow"
  rm -rf "$HOME/.local/share/backgrounds/gnome-wallpaper-slideshow"
  echo "    purged"
else
  echo "==> Kept config/XML (use '$0 --purge' to remove them too)"
fi
echo "Uninstall complete."
