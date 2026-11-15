"""Flow: a full-screen carousel that sets the desktop wallpaper.

Inspired by iamsurjog's hyprquickpaper, which is where the idea of picking a
wallpaper from a row of cards came from. Flow is written from scratch: a plain
Qt Quick window, Qt for the thumbnails, and each desktop's own interface for
setting the picture.

Copyright (c) 2026 Rudhra Rekapally. All rights reserved.
Proprietary; see LICENSE. Third-party terms: THIRD-PARTY-NOTICES.txt.
"""

import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import Property, QObject, QSize, QStandardPaths, Qt, QUrl, Signal, Slot
from PySide6.QtGui import QCursor, QGuiApplication, QImageReader
from PySide6.QtQml import QQmlApplicationEngine

APP_NAME = "Flow"
VERSION = "1.3.0"
# The name before Flow. Settings saved under it are carried over on first run.
LEGACY_NAME = "WallpaperSelector"

WINDOWS = sys.platform == "win32"
MACOS = sys.platform == "darwin"

# PyInstaller unpacks bundled data beside the frozen modules and points _MEIPASS at it.
RESOURCE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))

EXTENSIONS = {".png", ".jpg", ".jpeg"}
if MACOS:
    # Photos from an iPhone arrive as HEIC, and macOS sets either of these as a wallpaper.
    # Windows takes neither.
    EXTENSIONS |= {".heic", ".heif", ".webp"}
THUMB_HEIGHT = 500

DEFAULTS = {
    "folder": "$PICTURES/Wallpapers/",
    "thumbnails": "$CACHE/thumbs/",
    "tiles": 10,
    "highlight": "transparent",
    "workers": 20,
    "show_hints": True,
    "transition": True,
    # macOS only: keep the Control-Option-W helper running. Windows uses its Start menu entry.
    "shortcut": True,
}

# Settings written by Flow 1.1 and earlier, which used other names for these.
RENAMED = {
    "wallpaper_path": "folder",
    "cache_path": "thumbnails",
    "number_of_pictures": "tiles",
    "border_color": "highlight",
    "cache_batch_size": "workers",
}


def rename_keys(saved):
    """Return saved settings under the current names, dropping anything unknown."""
    out = {}
    for key, value in saved.items():
        key = RENAMED.get(key, key)
        if key in DEFAULTS:
            out[key] = value
    return out


def config_dir(name=APP_NAME):
    home = Path.home()
    if WINDOWS:
        return Path(os.environ.get("APPDATA", home / "AppData/Roaming")) / name
    if MACOS:
        return home / "Library/Application Support" / name
    return Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / name


def cache_dir():
    home = Path.home()
    if WINDOWS:
        return Path(os.environ.get("LOCALAPPDATA", home / "AppData/Local")) / APP_NAME
    if MACOS:
        return home / "Library/Caches" / APP_NAME
    return Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache") / APP_NAME


def legacy_settings():
    try:
        saved = json.loads((config_dir(LEGACY_NAME) / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(saved, dict):
        return {}
    saved = rename_keys(saved)
    # The thumbnail cache is disposable; let it start fresh under the new name.
    saved.pop("thumbnails", None)
    return saved


def save_config(path, config):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(config, indent=4) + "\n", encoding="utf-8")
    except OSError:
        pass


def load_config():
    path = config_dir() / "config.json"
    config = dict(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            saved = json.load(f)
        config.update(rename_keys(saved))
        if set(saved) & set(RENAMED):
            # Rewrite it once, so the file on disk matches the documented names.
            save_config(path, config)
    except FileNotFoundError:
        saved = legacy_settings()
        config.update(saved)
        save_config(path, config)
    except (OSError, ValueError):
        # A config that cannot be read or parsed must not stop the picker from opening.
        pass
    return config


def expand(path):
    pictures = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.PicturesLocation)
    path = path.replace("$PICTURES", pictures or str(Path.home() / "Pictures"))
    path = path.replace("$CACHE", str(cache_dir()))
    path = path.replace("$HOME", str(Path.home()))
    return Path(os.path.expandvars(path)).expanduser()


def wallpaper_dir(config):
    folder = expand(config["folder"])
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return folder


def make_thumbnail(src, out, announce=None):
    stamp = src.stat()
    reader = QImageReader(str(src))
    reader.setAutoTransform(True)
    size = reader.size()
    if size.isValid() and size.height() > THUMB_HEIGHT:
        width = max(1, round(size.width() * THUMB_HEIGHT / size.height()))
        reader.setScaledSize(QSize(width, THUMB_HEIGHT))
    image = reader.read()
    # Write beside the target and rename, so the picker never loads a half-written file.
    part = out.with_name(out.name + ".part")
    if image.isNull():
        # Qt may have no reader for HEIC; macOS can convert it itself.
        if not (MACOS and sips_thumbnail(src, part)):
            return
    else:
        fmt = "PNG" if out.suffix.lower() == ".png" else "JPG"
        if not image.save(str(part), fmt, 85):
            return
    # The thumbnail carries its source's timestamp; a mismatch later means the image was replaced.
    os.utime(part, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    os.replace(part, out)
    if announce is not None:
        # Crosses back to the GUI thread as a queued signal.
        announce(out.name)


def sips_thumbnail(src, part):
    """Have macOS write a JPEG thumbnail. It keeps the source's name; Qt reads it by content."""
    done = run(
        "sips", "-s", "format", "jpeg", "-s", "formatOptions", "85",
        "--resampleHeight", str(THUMB_HEIGHT), str(src), "--out", str(part),
    )
    return done is not None and done.returncode == 0 and part.is_file()


def is_stale(src, thumb):
    try:
        return thumb.stat().st_mtime_ns != src.stat().st_mtime_ns
    except OSError:
        return True


def cache_thumbnails(source_dir, thumb_dir, batch_size, announce=None):
    try:
        thumb_dir.mkdir(parents=True, exist_ok=True)
        sources = sorted(
            p for p in source_dir.iterdir() if p.is_file() and p.suffix.lower() in EXTENSIONS
        )
    except OSError:
        return None
    stale = [(src, thumb_dir / src.name) for src in sources if is_stale(src, thumb_dir / src.name)]
    if not stale:
        return None
    workers = max(1, min(batch_size or 1, os.cpu_count() or 1))
    pool = ThreadPoolExecutor(max_workers=workers)
    for src, out in stale:
        pool.submit(make_thumbnail, src, out, announce)
    return pool


def run(*command):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None


def set_wallpaper_windows(image):
    import ctypes

    SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE, SPIF_SENDCHANGE = 0x0014, 0x01, 0x02
    ctypes.windll.user32.SystemParametersInfoW(
        SPI_SETDESKWALLPAPER, 0, str(image), SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    )


def set_wallpaper_macos(image):
    # The path travels as an argument, never inside the script text.
    run(
        "osascript",
        "-e", "on run argv",
        "-e", 'tell application "System Events" to tell every desktop to set picture to (item 1 of argv)',
        "-e", "end run",
        str(image),
    )


def set_wallpaper_linux(image):
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    uri = image.as_uri()

    if "kde" in desktop and shutil.which("plasma-apply-wallpaperimage"):
        run("plasma-apply-wallpaperimage", str(image))
    elif "xfce" in desktop and shutil.which("xfconf-query"):
        listing = run("xfconf-query", "-c", "xfce4-desktop", "-l")
        for prop in (listing.stdout.split() if listing else []):
            if prop.endswith("/last-image"):
                run("xfconf-query", "-c", "xfce4-desktop", "-p", prop, "-s", str(image))
    elif "mate" in desktop:
        run("gsettings", "set", "org.mate.background", "picture-filename", str(image))
    elif "cinnamon" in desktop:
        run("gsettings", "set", "org.cinnamon.desktop.background", "picture-uri", uri)
    elif any(name in desktop for name in ("gnome", "unity", "budgie", "pantheon", "pop")):
        run("gsettings", "set", "org.gnome.desktop.background", "picture-uri", uri)
        run("gsettings", "set", "org.gnome.desktop.background", "picture-uri-dark", uri)
    else:
        # Window managers without a desktop shell: use whichever wallpaper tool is installed.
        for tool in (("awww", "img"), ("swww", "img"), ("feh", "--bg-fill")):
            if shutil.which(tool[0]):
                run(*tool, str(image))
                break


def set_wallpaper(image):
    if WINDOWS:
        set_wallpaper_windows(image)
    elif MACOS:
        set_wallpaper_macos(image)
    else:
        set_wallpaper_linux(image)


def open_folder(folder):
    try:
        if WINDOWS:
            os.startfile(folder)
        else:
            subprocess.Popen(["open" if MACOS else "xdg-open", str(folder)])
    except OSError:
        pass


class Backend(QObject):
    # A thumbnail has just been written; the card showing that file can load it.
    thumbnailReady = Signal(str)

    def __init__(self, config):
        super().__init__()
        self.wallpaper_dir = wallpaper_dir(config)
        self.cache_dir = expand(config["thumbnails"])
        self._tiles = int(config["tiles"])
        self._highlight = str(config["highlight"])
        self._hints = bool(config["show_hints"])
        self._transition = bool(config["transition"])

    @Property(QUrl, constant=True)
    def folderUrl(self):
        return QUrl.fromLocalFile(str(self.wallpaper_dir))

    @Property(str, constant=True)
    def folderPath(self):
        return str(self.wallpaper_dir)

    @Property(str, constant=True)
    def thumbsUrl(self):
        return QUrl.fromLocalFile(str(self.cache_dir) + os.sep).toString()

    @Property("QVariantList", constant=True)
    def patterns(self):
        return ["*" + ext for ext in sorted(EXTENSIONS)]

    @Property(int, constant=True)
    def tiles(self):
        return self._tiles

    @Property(str, constant=True)
    def highlight(self):
        return self._highlight

    @Property(bool, constant=True)
    def showHints(self):
        return self._hints

    @Property(bool, constant=True)
    def transition(self):
        return self._transition

    @Slot(str)
    def apply(self, path):
        image = Path(path).resolve()
        if image.is_file():
            set_wallpaper(image)

    @Slot()
    def openFolder(self):
        open_folder(self.wallpaper_dir)


def build(app):
    """Create the picker window on the screen under the cursor. Returns what must stay alive."""
    config = load_config()
    backend = Backend(config)
    pool = cache_thumbnails(
        backend.wallpaper_dir, backend.cache_dir, int(config["workers"]), backend.thumbnailReady.emit
    )

    engine = QQmlApplicationEngine()
    engine.rootContext().setContextProperty("backend", backend)
    engine.load(QUrl.fromLocalFile(str(RESOURCE_DIR / "shell.qml")))
    if not engine.rootObjects():
        raise SystemExit("shell.qml failed to load")

    window = engine.rootObjects()[0]
    screen = app.screenAt(QCursor.pos()) or app.primaryScreen()
    window.setScreen(screen)
    if WINDOWS:
        # A tool window stays out of the taskbar.
        window.setFlag(Qt.WindowType.Tool, True)
    if WINDOWS or MACOS:
        window.setGeometry(screen.geometry())
        window.show()
    else:
        # Wayland does not let a window place itself; full screen is the portable way to cover it.
        window.showFullScreen()
    window.requestActivate()
    return engine, backend, pool


def keep_shortcut(config):
    """On a Mac, start (or stop) the helper behind Control-Option-W."""
    if not MACOS:
        return
    import macshortcut

    if config.get("shortcut", True):
        macshortcut.ensure()
    else:
        macshortcut.remove()


def main():
    args = sys.argv[1:]
    if "--open-folder" in args:
        open_folder(wallpaper_dir(load_config()))
        return 0
    if MACOS and "--shortcut" in args:
        import macshortcut

        return macshortcut.serve()
    if MACOS and "--setup-shortcut" in args:
        import macshortcut

        return 0 if macshortcut.ensure() else 1
    if MACOS and "--remove-shortcut" in args:
        import macshortcut

        macshortcut.remove()
        return 0

    app = QGuiApplication(sys.argv)
    engine, backend, pool = build(app)
    code = app.exec()
    del engine
    # After the picker closes, so it never waits on launchctl.
    keep_shortcut(load_config())
    if pool:
        pool.shutdown(wait=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
