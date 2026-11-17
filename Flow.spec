# PyInstaller spec: freezes src/selector.py into dist/Flow/ (a folder, not one file,
# so the Qt libraries stay separate and replaceable, which the LGPL asks for).
# Run it on the system you are building for: PyInstaller does not cross-compile.
import sys

WINDOWS = sys.platform == "win32"

# QML modules the picker imports. PyInstaller would otherwise ship every module Qt has.
KEEP_QML = (
    "pyside6/qml/qtqml/",
    "pyside6/qml/qtquick/window/",
    "pyside6/qml/qtquick/effects/",
    "pyside6/qml/qt/labs/folderlistmodel/",
)

# Libraries only the dropped QML modules needed, plus the 20 MB software OpenGL fallback
# (Qt Quick renders through Direct3D 11 on Windows).
DROP_FILES = (
    "opengl32sw.dll",
    "qt6quickcontrols2", "qt6quicktemplates2", "qt6quickdialogs2", "qt6quicklayouts",
    "qt6quickparticles", "qt6quickshapes", "qt6quicktimeline", "qt6quicktest",
    "qt6quickvectorimage", "qt6quickwidgets", "qt6labsanimation", "qt6labsqmlmodels",
    "qt6labssettings", "qt6labssharedimage", "qt6labswavefrontmesh", "qt6labsplatform",
    "qt6qmllocalstorage", "qt6qmlxmllistmodel", "qt6qmlcompiler", "qt6qmlcore",
    "qt6sql", "qt6test", "qt6widgets", "qt6pdf", "qt6virtualkeyboard",
)


def wanted(entry):
    low = entry[0].replace("\\", "/").lower()
    if low.startswith("pyside6/translations/"):
        return False
    if low.startswith("pyside6/qml/"):
        in_quick_root = low.startswith("pyside6/qml/qtquick/") and low.count("/") == 3
        return in_quick_root or any(low.startswith(k) for k in KEEP_QML)
    name = low.rsplit("/", 1)[-1]
    return not any(name.startswith(d) for d in DROP_FILES)


a = Analysis(
    ["src/selector.py"],
    datas=[("src/shell.qml", ".")],
    excludes=["tkinter", "unittest", "pydoc", "PySide6.QtWidgets", "PySide6.QtSql", "PySide6.QtTest"],
)
if WINDOWS:
    # The pruning lists are written against the Windows file layout; other systems ship the full set.
    a.binaries = [b for b in a.binaries if wanted(b)]
    a.datas = [d for d in a.datas if wanted(d)]

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    exclude_binaries=True,
    name="Flow",
    console=False,
    icon="assets/icon.ico" if WINDOWS else None,
    upx=False,
)

coll = COLLECT(exe, a.binaries, a.datas, name="Flow", upx=False)

if sys.platform == "darwin":
    BUNDLE(
        coll,
        name="Flow.app",
        bundle_identifier="app.flow.wallpapers",
        icon="assets/icon.ico",  # converted to .icns by PyInstaller; needs Pillow installed
        info_plist={
            "CFBundleShortVersionString": "1.3.2",
            # Matches Qt 6.8, pinned in requirements.txt; older Macs get a clear message instead of a crash.
            "LSMinimumSystemVersion": "12.0",
            "NSHighResolutionCapable": True,
            # Setting the wallpaper goes through System Events. Without this line macOS
            # refuses the request silently instead of asking the user for permission.
            "NSAppleEventsUsageDescription": "Flow sets your desktop wallpaper through System Events.",
        },
    )
