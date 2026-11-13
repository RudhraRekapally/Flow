"""Flow: a full-screen carousel that sets the desktop wallpaper.

A port of the hyprquickpaper carousel (https://github.com/iamsurjog/hyprquickpaper,
as tweaked in https://github.com/43PR/dotfiles). The Quickshell / Hyprland parts are
replaced with a plain Qt Quick window, thumbnails are made with Qt instead of
ImageMagick, and the wallpaper is set through each desktop's own interface.
"""

import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import Property, QObject, QSize, QStandardPaths, Qt, QUrl, Slot
from PySide6.QtGui import QCursor, QGuiApplication, QImageReader
from PySide6.QtQml import QQmlApplicationEngine

APP_NAME = "Flow"
VERSION = "1.1.2"
# The name before Flow. Settings saved under it are carried over on first run.
LEGACY_NAME = "WallpaperSelector"

WINDOWS = sys.platform == "win32"
MACOS = sys.platform == "darwin"

# PyInstaller unpacks bundled data beside the frozen modules and points _MEIPASS at it.
RESOURCE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))

EXTENSIONS = {".png", ".jpg", ".jpeg"}
THUMB_HEIGHT = 500

DEFAULTS = {
    "wallpaper_path": "$PICTURES/Wallpapers/",
    "cache_path": "$CACHE/thumbs/",
    "number_of_pictures": 10,
    "border_color": "transparent",
    "cache_batch_size": 20,
    "show_hints": True,
    "transition": True,
}


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
    # The thumbnail cache is disposable; let it start fresh under the new name.
    saved.pop("cache_path", None)
    return saved


def load_config():
    path = config_dir() / "config.json"
    config = dict(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            config.update(json.load(f))
    except FileNotFoundError:
        saved = legacy_settings()
        config.update(saved)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({**DEFAULTS, **saved}, indent=4) + "\n", encoding="utf-8")
        except OSError:
            pass
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
    folder = expand(config["wallpaper_path"])
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return folder


def make_thumbnail(src, out):
    stamp = src.stat()
    reader = QImageReader(str(src))
    reader.setAutoTransform(True)
    size = reader.size()
    if size.isValid() and size.height() > THUMB_HEIGHT:
        width = max(1, round(size.width() * THUMB_HEIGHT / size.height()))
        reader.setScaledSize(QSize(width, THUMB_HEIGHT))
    image = reader.read()
    if image.isNull():
        return
    # Write beside the target and rename, so the picker never loads a half-written file.
    part = out.with_name(out.name + ".part")
    fmt = "PNG" if out.suffix.lower() == ".png" else "JPG"
    if image.save(str(part), fmt, 85):
        # The thumbnail carries its source's timestamp; a mismatch later means the image was replaced.
        os.utime(part, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        os.replace(part, out)


def is_stale(src, thumb):
    try:
        return thumb.stat().st_mtime_ns != src.stat().st_mtime_ns
    except OSError:
        return True


def cache_thumbnails(source_dir, thumb_dir, batch_size):
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
        pool.submit(make_thumbnail, src, out)
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
    def __init__(self, config):
        super().__init__()
        self.wallpaper_dir = wallpaper_dir(config)
        self.cache_dir = expand(config["cache_path"])
        self._pictures = int(config["number_of_pictures"])
        self._border = str(config["border_color"])
        self._hints = bool(config["show_hints"])
        self._transition = bool(config["transition"])

    @Property(QUrl, constant=True)
    def wallpaperUrl(self):
        return QUrl.fromLocalFile(str(self.wallpaper_dir))

    @Property(str, constant=True)
    def wallpaperPath(self):
        return str(self.wallpaper_dir)

    @Property(str, constant=True)
    def cacheUrl(self):
        return QUrl.fromLocalFile(str(self.cache_dir) + os.sep).toString()

    @Property(int, constant=True)
    def numberOfPictures(self):
        return self._pictures

    @Property(str, constant=True)
    def borderColor(self):
        return self._border

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
    pool = cache_thumbnails(backend.wallpaper_dir, backend.cache_dir, int(config["cache_batch_size"]))

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


def main():
    if "--open-folder" in sys.argv[1:]:
        open_folder(wallpaper_dir(load_config()))
        return 0

    app = QGuiApplication(sys.argv)
    engine, backend, pool = build(app)
    code = app.exec()
    del engine
    if pool:
        pool.shutdown(wait=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
