// Wallpaper Ease Slideshow — GNOME Shell 42 extension
//
// GNOME 42's native XML slideshow crossfades with a LINEAR opacity blend that
// is redrawn at most once per second (ANIMATION_MIN_WAKEUP_INTERVAL = 1.0 s in
// ui/background.js) and exposes no easing/curve control. This extension takes
// over the *desktop* background and crossfades two Meta.Background actors at
// the shell's full frame rate using Clutter EASE_IN_OUT_CUBIC — the iOS-style
// nonlinear S-curve: slow start, rapid mid-swap, slow settle.
//
// Design constraints honored:
//   * contain fit (GDesktopEnums.BackgroundStyle.SCALED) => aspect ratio
//     preserved, black letterbox bars, never stretched or cropped;
//   * the new image is fully decoded/preloaded before any fade, so there is no
//     fade-to-black and no missing-image flash;
//   * the native desktop background is hidden only once our first image is
//     loaded, and restored verbatim on disable (we never change gsettings, so
//     the lock screen keeps using the native slideshow as its fallback);
//   * only two of our actors exist at a time; idle cost is one GLib timeout;
//   * every timeout/signal/actor is tracked and torn down on disable/reload.
//
// Configuration is a plain JSON file written by the make-slideshow generator
// (no GSettings schema to compile). Paths below match that generator.

'use strict';

const { Clutter, GDesktopEnums, Gio, GLib, Meta } = imports.gi;
const ByteArray = imports.byteArray;
const Main = imports.ui.main;

const DEFAULT_PLAYLIST = GLib.build_filenamev(
    [GLib.get_user_data_dir(), 'backgrounds', 'gnome-wallpaper-slideshow', 'playlist.json']);
const DEFAULT_STATE_DIR = GLib.build_filenamev(
    [GLib.get_user_state_dir(), 'gnome-wallpaper-slideshow']);
const DEFAULT_INTERVAL_MS = 17500;   // image hold time
const DEFAULT_FADE_MS = 2500;        // crossfade length
// iOS-like S-curve: EASE_IN_OUT_CUBIC is a built-in Clutter animation mode,
// so no custom alpha function / schema is required.
const EASE_MODE = Clutter.AnimationMode.EASE_IN_OUT_CUBIC;
const BLACK = Clutter.Color.from_pixel(0x000000ff);
const MINE_PROP = '_wallpaperEaseOwned';

// GJS 1.72 (this shell) returns a Uint8Array from load_contents and has no
// GBytes.get_data(); decode via imports.byteArray, exactly as the shell does.
function _readJsonFile(path) {
    const f = Gio.File.new_for_path(path);
    if (!f.query_exists(null))
        return null;
    const [ok, bytes] = f.load_contents(null);
    if (!ok)
        return null;
    return JSON.parse(ByteArray.toString(bytes));
}

function _loadConfig() {
    // Config is regenerated atomically (tmp + rename) by the generator, so a
    // partial read never happens; still guard every step.
    const cfg = {
        playlistPath: DEFAULT_PLAYLIST,
        intervalMs: DEFAULT_INTERVAL_MS,
        fadeMs: DEFAULT_FADE_MS,
        style: GDesktopEnums.BackgroundStyle.SCALED,
    };
    try {
        const f = Gio.File.new_for_path(
            GLib.build_filenamev([DEFAULT_STATE_DIR, 'extension-config.json']));
        if (f.query_exists(null)) {
            const json = _readJsonFile(f.get_path());
            if (json) {
                if (typeof json.playlist_path === 'string' && json.playlist_path)
                    cfg.playlistPath = json.playlist_path;
                if (Number.isFinite(json.interval_ms) && json.interval_ms > 0)
                    cfg.intervalMs = Math.floor(json.interval_ms);
                if (Number.isFinite(json.fade_ms) && json.fade_ms >= 0)
                    cfg.fadeMs = Math.floor(json.fade_ms);
            }
        }
    } catch (e) {
        logError(e, 'wallpaper-ease: config load failed, using defaults');
    }
    return cfg;
}

function _loadPlaylist(path) {
    const f = Gio.File.new_for_path(path);
    if (!f.query_exists(null))
        return [];
    let data;
    try {
        data = _readJsonFile(path);
    } catch (e) {
        logError(e, 'wallpaper-ease: playlist parse failed');
        return [];
    }
    if (!data)
        return [];
    const items = Array.isArray(data) ? data : data.images;
    if (!Array.isArray(items))
        return [];
    // Keep only files that exist; the generator already guarantees this, but a
    // playlist can briefly outlive a gallery prune.
    return items
        .map((p) => (typeof p === 'string' ? p : (p && p.path) || ''))
        .filter((p) => {
            try {
                return p && Gio.File.new_for_path(p).query_exists(null);
            } catch (_e) {
                return false;
            }
        });
}

var WallpaperEase = class WallpaperEase {
    constructor() {
        this._monitorIndex = Main.layoutManager.primaryIndex;
        this._group = Main.layoutManager._backgroundGroup;
        this._actors = [];            // at most 2 of our actors
        this._nativeActors = [];      // shell's own background actors we hide
        this._timeouts = new Set();
        this._fileMonitor = null;
        this._monitorSignal = 0;
        this._index = 0;
        this._playlist = [];
        this._cfg = _loadConfig();
        this._crossfading = false;
        this._nativeHidden = false;
        this._running = false;
    }

    // ---- timeout bookkeeping (all removed on disable) ----
    _addTimeout(millis, callback) {
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, millis, () => {
            this._timeouts.delete(id);
            return callback();
        });
        this._timeouts.add(id);
        return id;
    }

    _clearTimeouts() {
        for (const id of this._timeouts)
            GLib.source_remove(id);
        this._timeouts.clear();
    }

    enable() {
        this._running = true;
        if (!this._group) {
            logError(new Error('layoutManager._backgroundGroup unavailable'),
                'wallpaper-ease: cannot attach; native background retained');
            this._running = false;
            return;
        }
        this._reloadPlaylist();
        this._watchPlaylist();

        if (this._playlist.length === 0) {
            log('wallpaper-ease: empty playlist; native background retained');
            this._addTimeout(5000, () => {
                this._reloadPlaylist();
                if (this._playlist.length > 0)
                    this._startFirst();
                return GLib.SOURCE_REMOVE;
            });
            return;
        }
        this._startFirst();
    }

    disable() {
        this._running = false;
        this._clearTimeouts();
        if (this._monitorSignal && this._fileMonitor) {
            this._fileMonitor.disconnect(this._monitorSignal);
            this._monitorSignal = 0;
        }
        if (this._fileMonitor) {
            this._fileMonitor.cancel();
            this._fileMonitor = null;
        }
        for (const entry of this._actors) {
            try {
                entry.actor.remove_all_transitions();
                if (entry.actor.get_parent())
                    entry.actor.get_parent().remove_child(entry.actor);
                entry.actor.destroy();
            } catch (e) {
                logError(e, 'wallpaper-ease: actor teardown');
            }
        }
        this._actors = [];
        this._crossfading = false;
        this._showNative();
    }

    // ---- native background hide/restore (gsettings untouched) ----
    _hideNative() {
        if (this._nativeHidden)
            return;
        this._nativeActors = [];
        const children = this._group.get_children();
        for (const c of children) {
            if (c[MINE_PROP])
                continue;
            if (c.visible) {
                this._nativeActors.push(c);
                c.hide();
            }
        }
        this._nativeHidden = true;
    }

    _showNative() {
        for (const c of this._nativeActors) {
            try {
                c.show();
            } catch (e) {
                logError(e, 'wallpaper-ease: restore native actor');
            }
        }
        this._nativeActors = [];
        this._nativeHidden = false;
    }

    _watchPlaylist() {
        try {
            const f = Gio.File.new_for_path(this._cfg.playlistPath);
            this._fileMonitor = f.monitor_file(Gio.FileMonitorFlags.NONE, null);
            this._monitorSignal = this._fileMonitor.connect('changed',
                (_m, _child, _other, event) => {
                    if (event === Gio.FileMonitorEvent.CHANGES_DONE_HINT ||
                        event === Gio.FileMonitorEvent.CREATED ||
                        event === Gio.FileMonitorEvent.CHANGED)
                        this._onPlaylistChanged();
                });
        } catch (e) {
            logError(e, 'wallpaper-ease: cannot monitor playlist');
        }
    }

    _onPlaylistChanged() {
        // Coalesce the monitor-event burst around an atomic replace.
        if (this._timeouts.has(this._reloadIdle))
            return;
        this._reloadIdle = this._addTimeout(250, () => {
            this._reloadIdle = 0;
            this._reloadPlaylist();
            return GLib.SOURCE_REMOVE;
        });
    }

    _reloadPlaylist() {
        this._cfg = _loadConfig();
        const next = _loadPlaylist(this._cfg.playlistPath);
        if (next.length === 0)
            return;
        this._playlist = next;
        const current = this._currentPath();
        const pos = current ? next.indexOf(current) : -1;
        this._index = pos >= 0 ? pos : 0;
    }

    _currentPath() {
        return this._playlist.length ? this._playlist[this._index] : null;
    }

    // Preload a texture through the SAME cache the shell uses (background.js).
    // Meta.BackgroundImage has the 'loaded' signal and is_loaded(); raw
    // Meta.Background only has 'changed', so we wait on the image, not the bg.
    // Calls onReady exactly once, via load or a bounded timeout safety net.
    _preload(path, onReady) {
        let done = false;
        const fire = () => {
            if (done)
                return;
            done = true;
            if (signalId)
                image.disconnect(signalId);
            if (timeoutId)
                GLib.source_remove(timeoutId);
            onReady();
        };
        const file = Gio.File.new_for_path(path);
        const image = Meta.BackgroundImageCache.get_default().load(file);
        let signalId = 0;
        if (image.is_loaded()) {
            fire();
            return;
        }
        signalId = image.connect('loaded', fire);
        // Safety net: never wedge the slideshow if 'loaded' is missed.
        const timeoutId = this._addTimeout(4000, () => {
            fire();
            return GLib.SOURCE_REMOVE;
        });
    }

    _startFirst() {
        this._index = 0;
        const path = this._playlist[0];
        const entry = this._makeEntry(path);
        this._actors.push(entry);
        this._group.add_child(entry.actor);
        this._group.set_child_below_sibling(entry.actor, null);

        const reveal = () => {
            if (!this._running)
                return;
            this._hideNative();          // only hide shell bg once texture is ready
            entry.actor.opacity = 255;
            this._scheduleNext();
        };
        this._preload(path, reveal);
    }

    _scheduleNext() {
        this._addTimeout(this._cfg.intervalMs, () => {
            this._advance();
            return GLib.SOURCE_REMOVE;
        });
    }

    _advance() {
        if (!this._running || this._playlist.length === 0)
            return GLib.SOURCE_REMOVE;
        if (this._playlist.length === 1) {
            this._scheduleNext();
            return GLib.SOURCE_REMOVE;
        }
        this._index = (this._index + 1) % this._playlist.length;
        this._crossfadeTo(this._playlist[this._index]);
        return GLib.SOURCE_REMOVE;
    }

    _makeEntry(path) {
        const monitor = Main.layoutManager.monitors[this._monitorIndex];
        const background = new Meta.Background({ meta_display: global.display });
        // Solid black base => letterbox bars are black, identical to native.
        background.set_color(BLACK);
        const file = Gio.File.new_for_path(path);
        // SCALED = contain: whole image, aspect preserved, black bars, no crop.
        background.set_file(file, this._cfg.style);

        const actor = new Meta.BackgroundActor({
            meta_display: global.display,
            monitor: this._monitorIndex,
            request_mode: Clutter.RequestMode.CONTENT_SIZE,
            x_expand: true,
            y_expand: true,
        });
        actor.content.set({
            background,
            vignette: false,
            vignette_sharpness: 0.5,
            brightness: 0.5,
        });
        actor.set_position(monitor.x, monitor.y);
        actor.opacity = 0;
        actor[MINE_PROP] = true;
        return { actor, background, path };
    }

    _crossfadeTo(path) {
        if (this._crossfading) {
            this._scheduleNext();      // never stack overlapping fades
            return;
        }
        this._crossfading = true;
        const entry = this._makeEntry(path);

        const beginFade = () => {
            if (!this._running)
                return;
            this._hideNative();
            this._group.add_child(entry.actor);
            this._group.set_child_below_sibling(entry.actor, null);
            this._actors.push(entry);

            // The OLD actor stays fully opaque underneath for the whole fade,
            // so the screen is never under-filled (no black dip). Only the NEW
            // actor ramps 0 -> 255 on the cubic S-curve at full frame rate.
            entry.actor.opacity = 0;
            entry.actor.ease({
                opacity: 255,
                duration: this._cfg.fadeMs,
                mode: EASE_MODE,
                onComplete: () => this._finishFade(entry),
            });
        };

        // Wait until the new texture is decoded (Meta.BackgroundImage 'loaded'),
        // never on the raw Meta.Background (which only emits 'changed').
        this._preload(path, beginFade);
    }

    _finishFade(keep) {
        const stale = this._actors.filter((a) => a !== keep);
        this._actors = [keep];
        for (const s of stale) {
            try {
                s.actor.remove_all_transitions();
                if (s.actor.get_parent())
                    s.actor.get_parent().remove_child(s.actor);
                s.actor.destroy();
            } catch (e) {
                logError(e, 'wallpaper-ease: stale actor teardown');
            }
        }
        this._crossfading = false;
        if (this._running)
            this._scheduleNext();
    }
};

let _engine = null;

function enable() {
    try {
        if (_engine)
            return;
        _engine = new WallpaperEase();
        _engine.enable();
        log('wallpaper-ease: enabled');
    } catch (e) {
        logError(e, 'wallpaper-ease: enable failed (native background retained)');
        _engine = null;
    }
}

function disable() {
    if (!_engine)
        return;
    try {
        _engine.disable();
    } catch (e) {
        logError(e, 'wallpaper-ease: disable error');
    }
    _engine = null;
    log('wallpaper-ease: disabled; native background restored');
}
