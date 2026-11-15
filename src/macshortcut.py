"""Control-Option-W on a Mac.

A Windows Start menu entry can carry a shortcut key; a Mac app cannot. So Flow
keeps a small helper running for it: this same app, started with --shortcut by
a LaunchAgent at login. The helper holds a Carbon hot key, which needs no
Accessibility permission, and opens a fresh picker each time the keys are pressed.

Copyright (c) 2026 Rudhra Rekapally. All rights reserved.
Proprietary; see LICENSE.
"""

import ctypes
import ctypes.util
import os
import plistlib
import subprocess
import sys
from pathlib import Path

LABEL = "app.flow.wallpapers.shortcut"
AGENT = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
LOG = Path.home() / "Library/Logs/Flow-shortcut.log"

KEY_W = 13                      # kVK_ANSI_W
CONTROL, OPTION = 0x1000, 0x0800
KEYBOARD_CLASS = int.from_bytes(b"keyb", "big")
HOT_KEY_PRESSED = 5
SIGNATURE = int.from_bytes(b"FLOW", "big")


def log(message):
    print(message, flush=True)


# ------------------------------------------------------------------ installing the helper


def executable():
    return Path(sys.executable).resolve()


def bundle():
    app = executable().parents[2]
    return app if app.suffix == ".app" else None


def installable():
    if not getattr(sys, "frozen", False) or bundle() is None:
        return False
    where = str(bundle())
    # Run straight from the disk image, or from the copy macOS makes of a quarantined
    # app: either path disappears, and the helper would point at nothing.
    return not (where.startswith("/Volumes/") or "/AppTranslocation/" in where)


def agent_settings():
    return {
        "Label": LABEL,
        "ProgramArguments": [str(executable()), "--shortcut"],
        "RunAtLoad": True,
        # Start it again if it crashes; a clean exit (keys already taken) stays stopped.
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Interactive",
        "StandardOutPath": str(LOG),
        "StandardErrorPath": str(LOG),
    }


def launchctl(*args):
    try:
        return subprocess.run(["launchctl", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None


def service():
    return f"gui/{os.getuid()}/{LABEL}"


def ensure():
    """Install the helper, or point it at this copy of Flow if the app has moved."""
    if not installable():
        return False
    wanted = agent_settings()
    try:
        current = plistlib.loads(AGENT.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        current = None

    if current == wanted:
        # Starts the helper if it is not running; leaves it alone if it is.
        done = launchctl("kickstart", service())
        if done is not None and done.returncode == 0:
            return True
    elif current is not None:
        launchctl("bootout", service())

    try:
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        LOG.parent.mkdir(parents=True, exist_ok=True)
        AGENT.write_bytes(plistlib.dumps(wanted))
    except OSError:
        return False
    done = launchctl("bootstrap", f"gui/{os.getuid()}", str(AGENT))
    return done is not None and done.returncode == 0


def remove():
    launchctl("bootout", service())
    try:
        AGENT.unlink()
    except FileNotFoundError:
        pass


# ------------------------------------------------------------------ the helper itself


class EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


class EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


HANDLER = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)


def hide_from_dock():
    """Run as an accessory: no Dock icon and no menu bar for the helper."""
    objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    address = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value
    get = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(address)
    put = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long)(address)
    app = get(objc.objc_getClass(b"NSApplication"), objc.sel_registerName(b"sharedApplication"))
    put(app, objc.sel_registerName(b"setActivationPolicy:"), 1)  # Accessory


def serve():
    from PySide6.QtGui import QGuiApplication

    app = QGuiApplication(sys.argv[:1])
    hide_from_dock()

    carbon = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Carbon.framework/Carbon")
    carbon.GetApplicationEventTarget.restype = ctypes.c_void_p
    carbon.InstallEventHandler.restype = ctypes.c_int32
    carbon.InstallEventHandler.argtypes = [
        ctypes.c_void_p, HANDLER, ctypes.c_ulong, ctypes.POINTER(EventTypeSpec),
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
    ]
    carbon.RegisterEventHotKey.restype = ctypes.c_int32
    carbon.RegisterEventHotKey.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, EventHotKeyID, ctypes.c_void_p,
        ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p),
    ]

    picker = None

    def pressed(_call, _event, _data):
        nonlocal picker
        try:
            if picker is not None and picker.poll() is None:
                return 0  # a picker is already open
            # Through Launch Services, so the new window comes to the front with focus.
            # -W keeps `open` alive until that picker quits, which is what poll() watches.
            picker = subprocess.Popen(["open", "-n", "-W", "-a", str(bundle())])
            log("shortcut pressed, opening the picker")
        except Exception as error:  # noqa: BLE001 - a bad press must not kill the helper
            log(f"could not open the picker: {error}")
        return 0

    handler = HANDLER(pressed)  # kept referenced for the life of the loop
    target = carbon.GetApplicationEventTarget()
    spec = EventTypeSpec(KEYBOARD_CLASS, HOT_KEY_PRESSED)
    status = carbon.InstallEventHandler(target, handler, 1, ctypes.byref(spec), None, None)
    if status:
        log(f"could not listen for the shortcut (InstallEventHandler {status})")
        return 0

    ref = ctypes.c_void_p()
    status = carbon.RegisterEventHotKey(
        KEY_W, CONTROL | OPTION, EventHotKeyID(SIGNATURE, 1), target, 0, ctypes.byref(ref)
    )
    if status:
        # Another app owns Control-Option-W. Exit cleanly so launchd does not keep retrying.
        log(f"Control-Option-W is taken by another app (RegisterEventHotKey {status})")
        return 0

    log(f"listening for Control-Option-W, opening {bundle()}")
    code = app.exec()
    del handler
    return code
