#!/usr/bin/env bash
# Read-only health check for the Wallpaper Ease slideshow stack.
set -uo pipefail
UUID="gnome-wallpaper-ease@jiadaoz22.github.com"
STATE="$HOME/.local/state/gnome-wallpaper-slideshow"
BG="$HOME/.local/share/backgrounds/gnome-wallpaper-slideshow"

pass=0; fail=0
ok(){   echo "  [PASS] $1"; pass=$((pass+1)); }
bad(){  echo "  [FAIL] $1"; fail=$((fail+1)); }

echo "== shell extension =="
if gnome-extensions list 2>/dev/null | grep -q "$UUID"; then
  st=$(gnome-extensions info "$UUID" 2>/dev/null | grep -i state | head -1)
  echo "$st" | grep -qi enabled && ok "extension enabled ($st)" || bad "present but not enabled ($st)"
else
  bad "extension not loaded by the shell yet (reload GNOME Shell)"
fi
echo "  disable-user-extensions = $(gsettings get org.gnome.shell disable-user-extensions)"
echo "  enabled-extensions      = $(gsettings get org.gnome.shell enabled-extensions)"

echo "== extension inputs =="
[ -f "$BG/playlist.json" ] && ok "playlist.json present" || bad "playlist.json missing"
[ -f "$STATE/extension-config.json" ] && ok "extension-config.json present" || bad "extension-config.json missing"
if [ -f "$STATE/extension-config.json" ]; then
  python3 - "$STATE/extension-config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
print(f"  interval={c['interval_ms']}ms fade={c['fade_ms']}ms easing={c.get('easing')} style={c.get('style')}")
assert c['interval_ms']==17500 and c['fade_ms']==2500, "timing mismatch"
PY
fi
if [ -f "$BG/playlist.json" ]; then
  python3 - "$BG/playlist.json" <<'PY'
import json,os,sys
d=json.load(open(sys.argv[1]))
imgs=d["images"]; miss=[p for p in imgs if not os.path.exists(p)]
print(f"  playlist entries={len(imgs)} missing={len(miss)}")
sys.exit(1 if miss else 0)
PY
  [ $? -eq 0 ] && ok "all playlist paths exist" || bad "some playlist paths are missing"
fi

echo "== native fallback (lock screen + disabled-extension safety net) =="
for s in org.gnome.desktop.background org.gnome.desktop.screensaver; do
  echo "  $s options=$(gsettings get $s picture-options) uri=$(gsettings get $s picture-uri | sed 's#.*/##')"
done

echo "== recent shell log for the extension =="
journalctl --user -b --no-pager 2>/dev/null | grep -i 'wallpaper-ease' | tail -5 || echo "  (no log lines yet)"

echo
echo "RESULT: $pass passed, $fail failed"
exit $fail
