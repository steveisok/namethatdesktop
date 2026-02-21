# Name That Desktop

A tiny macOS menu bar app that lets you **name your virtual desktop Spaces** — because Apple won't let you.

![menu bar](https://img.shields.io/badge/menu_bar-app-blue) ![macOS](https://img.shields.io/badge/macOS-14%2B-black) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)

## What It Does

macOS gives you multiple desktops (Spaces) but labels them "Desktop 1", "Desktop 2", etc. with no way to rename them. Name That Desktop adds a menu bar indicator showing your current Space number and custom name, and lets you:

- **Name any Space** — click "Set Name…" and type whatever you want
- **Auto-name from your terminal** — if a terminal is focused, grab its working directory as the Space name (e.g. `📂 my-project`)
- **Switch Spaces** — click any Space in the dropdown to jump to it
- **Auto-detect mode** — continuously renames Spaces based on the focused terminal's working directory
- **Launch at Login** — toggle from the menu, no manual setup needed

Names persist across restarts in `~/.config/namethatdesktop/config.json`.

## Supported Terminals

Terminal.app, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm, and Hyper.

## Build & Run

Single file, no dependencies, no Xcode project needed:

```bash
# Compile
swiftc -O -framework Cocoa NameThatDesktop.swift -o namethatdesktop

# Create the .app bundle (required for menu bar visibility on modern macOS)
mkdir -p "Name That Desktop.app/Contents/MacOS"
cp namethatdesktop "Name That Desktop.app/Contents/MacOS/Name That Desktop"

# Launch
open "Name That Desktop.app"
```

The `Info.plist` is included in the repo — it marks the app as a menu-bar-only agent (`LSUIElement`) so it won't appear in the Dock.

## Rebuilding After Changes

```bash
swiftc -O -framework Cocoa NameThatDesktop.swift -o namethatdesktop
cp namethatdesktop "Name That Desktop.app/Contents/MacOS/Name That Desktop"
open "Name That Desktop.app"
```

## Tips

- **Cmd+Tab doesn't switch Spaces?** By default macOS pulls windows to your current Space instead of switching. To change this, go to **System Settings → Desktop & Dock** and enable *"When switching to an application, switch to a Space with open windows for the application"*.
- **Auto-detect** works best when a terminal is the frontmost app on the Space. It polls every 5 seconds and picks up the deepest shell's working directory.
- The CWD detection walks the process tree from the terminal PID and uses `lsof` — no special terminal integration required.

## How It Works

Name That Desktop uses private CoreGraphics SPI (`CGSCopyManagedDisplaySpaces`, `CGSManagedDisplaySetCurrentSpace`) to read and switch Spaces. These APIs have been stable across macOS releases for years. A 1-second timer polls for Space changes to keep the menu bar label up to date.

## License

MIT
