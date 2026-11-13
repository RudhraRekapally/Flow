# Flow

**Flow** is a full-screen carousel of your wallpapers. Pick one and it becomes the desktop background.

**Download:** get the installer from the [Releases page](../../releases/latest) (under **Assets**). The green **Code > Download ZIP** button gives the source code only.

Put `.jpg`, `.jpeg` or `.png` files in **Pictures/Wallpapers** and open Flow.

| Key | Action |
| --- | --- |
| Click, Space, Enter | Apply the highlighted wallpaper |
| ← → or hover | Browse |
| O | Open the wallpapers folder |
| Esc | Close |

## Windows

Run `FlowSetup.exe`. It installs for the current user only (no administrator
password), adds **Flow** to the Start Menu and binds it to **Ctrl+Alt+W**.

The installer is not code-signed, so Windows shows "Windows protected your PC" the first
time: choose **More info**, then **Run anyway**.

## macOS

Needs **macOS 12 Monterey or newer**. Pick the download for your Mac (Apple menu >
**About This Mac** shows the chip):

- `Flow-macOS-AppleSilicon.dmg` for an Apple M1, M2, M3, M4 or newer chip
- `Flow-macOS-Intel.dmg` for an Intel processor

Open the .dmg and drag **Flow** into **Applications**.

Flow is not signed with an Apple developer certificate, so the first launch is blocked:

1. Open Flow once; macOS says it cannot be verified. Click **Done**.
2. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next
   to the Flow message. Confirm with your password.

(Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Flow.app`.)

The first time you pick a wallpaper, macOS asks whether Flow may control **System Events**.
Allow it; that is how Flow sets the wallpaper. Launch Flow from Launchpad or Spotlight, or bind
it to a key with the Shortcuts app.

## Linux

There is no package yet; run it with Python 3.10 or newer:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python src/selector.py
```

Setting the wallpaper uses GNOME / Cinnamon / MATE / KDE Plasma / Xfce settings, falling back
to `awww`, `swww` or `feh`. Linux has not been tested yet.

## Downloads

Every push to `main` builds the installers in GitHub Actions (the run's **Artifacts**).
Pushing a tag such as `v1.1.0` also publishes them on the repository's **Releases** page.

## Settings

`config.json` is created on first run:

| System | Location |
| --- | --- |
| Windows | `%APPDATA%\Flow\` |
| macOS | `~/Library/Application Support/Flow/` |
| Linux | `~/.config/Flow/` |

`wallpaper_path` is the folder to read (`$PICTURES` and `$HOME` are expanded),
`number_of_pictures` is how many tiles fit across the screen, `show_hints` toggles the key
hints under the carousel, and `transition` toggles the grow-and-fade animation when a
wallpaper is picked.

## Building

PyInstaller does not cross-compile, so each system's build is made on that system.

Windows (needs [Inno Setup 6](https://jrsoftware.org/isinfo.php)):

```powershell
.\build.ps1
```

macOS / Linux, producing `dist/Flow/` (and `Flow.app` on macOS):

```bash
python3 -m venv .build-venv
.build-venv/bin/pip install PySide6-Essentials pyinstaller
.build-venv/bin/pyinstaller --noconfirm Flow.spec
```

## Credits

The carousel is a port of [hyprquickpaper](https://github.com/iamsurjog/hyprquickpaper) by
iamsurjog, as modified in [43PR/dotfiles](https://github.com/43PR/dotfiles) (MIT). Built with
Qt for Python (LGPL-3.0). See `THIRD-PARTY-NOTICES.txt`.
