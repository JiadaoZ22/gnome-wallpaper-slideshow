# Wallpaper geometry and the GNOME top panel

How contain-fit letterboxing works in this extension, why the very top of a
photo can look "cropped" even though it is not, and the two rendering bugs that
were fixed to get here. Written from the GNOME Shell 42.9 / Mutter 42.9 source
on Ubuntu 22.04 (X11, single 4K panel, HiDPI `scale-monitor-framebuffer`,
logical 1920×1080 at scale 2 = physical 3840×2160).

## TL;DR

- Images use GNOME **`scaled` (contain) fit**: the whole photo is always
  visible, aspect ratio preserved, unfilled area black. Nothing in the image is
  ever cropped by the slideshow.
- The GNOME **top panel is an opaque chrome layer painted *above* the
  wallpaper**, not a crop. The wallpaper actor fills the entire monitor and
  starts at y = 0, so its top strip runs underneath the panel. This is identical
  to stock GNOME's own background behavior.
- On a 4K panel at scale 2 the panel is **27 logical / 54 physical px** tall
  (`#panel { height: 2.2em }`). For a portrait with a white film frame, that
  hides the ~43 px white top border plus roughly ~11 px (≈0.5% of screen height)
  of actual photo.
- Do not "fix" this by offsetting the actor down: it would deviate from native
  GNOME and add a permanent black strip at the top of the screen.

## Why the top looks covered (not cropped)

The shell stacks actors in this order (bottom → top):

```
global.stage
└─ uiGroup
   ├─ window_group
   │  └─ _backgroundGroup        ← Meta.Background actors live here (y: 0 … monitor height)
   │     ├─ native shell background
   │     └─ this extension's two crossfade actors
   └─ panelBox / #panel          ← opaque top bar, painted ABOVE every background
```

A `Meta.BackgroundContent` reports its **preferred size as the full monitor
rect** (`meta_background_content_get_preferred_size` returns
`monitor_geometry.width/height`). The extension therefore builds each actor to
fill the whole monitor and positions it at `(monitor.x, monitor.y)` = `(0, 0)`.
The image is then contain-fit *inside* that full-height actor, so a
height-filling portrait legitimately begins at y = 0 — underneath where the
panel is drawn.

The panel is not transparent in the default Yaru/gnome-shell theme
(`#panel { background-color: #000; height: 2.2em }`), so the wallpaper pixels in
that strip exist but are simply hidden behind it. Hiding the extension and
pointing the **native** background at the same photo produces the exact same
overlap — proof it is shell behavior, not an extension defect.

### How to confirm a given screenshot is overlap, not crop

1. Identify the source photo and compute its contain rect:

   ```text
   scale = min(screen_w / img_w, screen_h / img_h)
   rect  = (img_w*scale) × (img_h*scale), centered
   ```

   A portrait (`img_h > img_w`) height-fills: `rect` height = screen height,
   `rect.y = 0`, with black bars only on the left/right.
2. Template-match the screenshot against the source **top-aligned** vs.
   **top-cropped**. The top-aligned match scores markedly lower (better), and
   the source's first rows (often a white film border) line up with the region
   behind the panel.
3. Remember the panel zone is ~54 physical px at scale 2; everything below it
   should match the source 1:1.

## Contain-fit (`scaled`) letterbox math

From `meta-background.c → get_texture_area`,
`G_DESKTOP_BACKGROUND_STYLE_SCALED`:

```c
monitor_x_scale = monitor_rect.width  / texture_width;
monitor_y_scale = monitor_rect.height / texture_height;

if (monitor_x_scale < monitor_y_scale) {        // width is the limiting axis
    image_area.width  = monitor_rect.width;     // fill width
    image_area.height = texture_height * monitor_x_scale;
    image_area.x = 0;
    image_area.y = monitor_rect.height/2 - image_area.height/2;   // center vertically
} else {                                         // height is the limiting axis
    image_area.height = monitor_rect.height;    // fill height
    image_area.width  = texture_width * monitor_y_scale;
    image_area.y = 0;
    image_area.x = monitor_rect.width/2  - image_area.width/2;    // center horizontally
}
```

The painter itself centers correctly. Therefore an off-center or clipped
letterbox is never a painter bug — it is the **actor's allocation**, i.e. how
the surrounding Clutter container sizes the `Meta.BackgroundActor`.

## The two bugs that were fixed

### 1. HiDPI allocation drift → letterbox shifted up-left, top frame clipped

The original actor set `x_expand: true, y_expand: true` with only a fixed
position. Inside the `Meta.BackgroundGroup`'s default `FixedLayout`, under
HiDPI `scale-monitor-framebuffer`, that let the actor's allocation drift away
from the monitor rect, so the contain-fit image was shifted up-left and its top
film frame was cut off.

**Fix — mirror the shell's native `BackgroundManager._createBackgroundActor()`
exactly** (`ui/background.js`), which letterboxes correctly in the same parent
group:

```js
const actor = new Meta.BackgroundActor({
    meta_display: global.display,
    monitor: this._monitorIndex,
    request_mode: Clutter.RequestMode.CONTENT_SIZE,
    x_expand: false,            // native uses FALSE, not true
    y_expand: false,
});
actor.content.set({ background, vignette:false, vignette_sharpness:0.5, brightness:0.5 });
actor.set_position(monitor.x, monitor.y);   // plain set_position; NO constraint
```

With `CONTENT_SIZE` + `x/y_expand:false`, the actor keeps the content's
full-monitor preferred size and is never re-sized away from it, so SCALED
letterboxing stays centered with no crop — even under fractional/HiDPI scaling.

A `MonitorConstraint` was tried first and then **removed**: the native desktop
background uses none, and adding one inside this `FixedLayout` group is
unproven/unnecessary. Keep the actor byte-for-byte equivalent to the working
native path.

### 2. Rotation freeze — TDZ `ReferenceError` killed the timer chain

`_preload()` declared `const timeoutId` only on the slow (image-not-loaded)
path, but the warm-cache fast path calls `fire()` **synchronously before that
declaration**. A cached image therefore hit the JavaScript temporal-dead-zone
and threw:

```text
JS ERROR: ReferenceError: can't access lexical declaration 'timeoutId'
         before initialization
```

An uncaught exception escaping a `GLib.timeout_add` callback **destroys the
source**, so the single-chain slideshow stopped advancing and sat on one image
(typically right after a playlist/gallery update repopulated the cache).

**Fix:**

- hoist the id to `let timeoutId = 0;` *before* the synchronous `fire()`;
- route every timeout through an `_addTimeout(millis, callback, onError)`
  wrapper that `try/catch`s the callback, logs via `logError`, and re-arms via
  the `onError` hook, so any future throw degrades to a delayed retry instead of
  a permanent freeze;
- keep the 12 s "loaded event missed" safety net in `_preload`.

## Editing the extension? You must really reload the shell

The long-lived shell process **caches each extension module in its GJS
importer map**. `gnome-extensions disable/enable` (and the D-Bus
`EnableExtension`) only re-run the cached module's `enable()`/`disable()` — they
do **not** re-read `extension.js` from disk. `ReloadExtension` is unimplemented
over D-Bus and `org.gnome.Shell.Eval` is locked in Ubuntu builds.

Two gotchas when verifying a reload:

- On **X11**, `Alt+F2 → r` re-execs gnome-shell in place via `execve()`, which
  **keeps the same PID and start time** while clearing all memory. Do not use an
  unchanged PID as evidence that nothing restarted.
- The authoritative restart signal is the journal line
  **`GNOME Shell started at …`** (plus a fresh
  `Enabling experimental feature 'scale-monitor-framebuffer'` cluster). A
  plain lock/unlock or extension toggle never logs that line.

Definitive "is my new code live?" check: put a unique `log('…[BUILD-MARKER]')`
in `enable()`, do one disable→enable cycle, and grep the journal — marker absent
means stale cached code is still running. Wayland requires a full log out/in
(X11-only `r`).

Also avoid rapid repeated disable/enable cycles while testing: the in-memory
extension manager can wedge (every user extension reports state 2 and `enable`
is silently ignored), and only a real shell restart clears it.

## Measurement pitfalls (learned the hard way)

- **Maximized windows occlude almost everything.** A maximized browser/editor on
  a 4K panel commonly has geometry like `3710x2106+130+54`, covering
  x 130…3839, y 54…2159. A "first non-black column at x=130" then measures the
  **window edge**, not the wallpaper edge; it stays pinned across many different
  photos, which is the tell (a real contain-fit edge moves with each image's
  aspect ratio). Only the left ~130 px and top ~54 px bands are reliably
  wallpaper-visible. The transparent DING desktop window (`@!0,0;BDHF`,
  full-screen) is not occlusion.
- Full-screen template matching is dominated by static window content and gives
  meaningless diffs; match only the exposed bands.
- Don't threshold-detect top/bottom bars on a photo that is itself white (a
  white film frame): long white runs are image content, not frame edges. Infer
  geometry from the source aspect ratio instead.
- The cleanest correctness proof is an **A/B against the native background**:
  back up the gsettings, disable the extension, point the native
  `org.gnome.desktop.background` (option `scaled`) at the same portrait, and
  confirm the exposed left band is pure black (the contain rect starts far
  right, under the window). Re-enable and check the same signature, then restore
  the gsettings.

## If you genuinely want the full photo visible

These are deliberate trade-offs, not defaults:

1. **Transparent/floating panel** — a dynamic-panel-transparency style shell
   extension lets the wallpaper show through the top bar. Least invasive; keeps
   native geometry.
2. **Inset the actor below the panel** — add a top offset of one panel height
   (27 logical px) to the extension's actor. Not recommended: it diverges from
   native GNOME and leaves a permanent black strip at the top of the screen.
3. Leave it as-is — matches stock GNOME; on film-frame portraits the hidden
   area is mostly the white border.
