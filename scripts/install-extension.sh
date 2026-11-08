#!/usr/bin/env bash
# Install (or update) the Wallpaper Ease shell extension into the user's
# GNOME Shell extension directory and enable it. The extension is COPIED (not
# symlinked): gnome-shell's loader does not reliably follow symlinks onto FUSE
# or NTFS mounts. Re-run after editing extension.js, then reload the shell.
set -euo pipefail

UUID="gnome-wallpaper-ease@jiadaoz22.github.com"
# Repo root = parent of this script's directory (scripts live in scripts/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)/extension/$UUID"
DST="$HOME/.local/share/gnome-shell/extensions/$UUID"

[ -f "$SRC/extension.js" ] || { echo "FATAL: $SRC/extension.js not found"; exit 1; }

mkdir -p "$(dirname "$DST")"
rm -rf "$DST"
cp -r "$SRC" "$DST"
chmod 0755 "$DST" "$DST"/*.js "$DST"/*.json "$DST"/*.css

# Allow user extensions and add the UUID to the enabled list (idempotent).
gsettings set org.gnome.shell disable-user-extensions false
python3 - "$UUID" <<'PY'
import subprocess, sys
uuid = sys.argv[1]
raw = subprocess.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                     capture_output=True, text=True).stdout.strip()
vals = []
if raw and raw not in ("@as []", "[]"):
    vals = [v.strip().strip("'") for v in raw.strip("[]").split(",") if v.strip()]
if uuid not in vals:
    vals.append(uuid)
arr = "[" + ", ".join("'%s'" % v for v in vals) + "]"
subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", arr], check=True)
print("enabled-extensions:", arr)
PY

# Validate JSON metadata.
python3 -m json.tool "$DST/metadata.json" >/dev/null
if command -v node >/dev/null 2>&1; then
  node --check "$DST/extension.js" && echo "extension.js syntax OK"
fi

echo
echo "Installed to $DST"
if gnome-extensions list 2>/dev/null | grep -q "$UUID"; then
  echo "Shell already knows the extension; enabling now."
  gnome-extensions enable "$UUID" || true
else
  cat <<'MSG'

The running GNOME Shell has not scanned the new extension yet. Reload it once:
  * X11  : press Alt+F2, type  r  , press Enter  (windows stay open; ~1-2 s)
  * Wayland: log out and back in
Then verify:
  gnome-extensions info gnome-wallpaper-ease@jiadaoz22.github.com
  gnome-extensions show gnome-wallpaper-ease@jiadaoz22.github.com
MSG
fi
