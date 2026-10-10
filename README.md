# FinderHover

A native macOS utility that shows open Finder windows when the pointer rests on the Finder icon in the Dock.

## Release

Version `0.0.1` is released from the `v0.0.1` tag. GitHub Actions runs on a macOS runner, builds the signed app bundle used by the workflow, creates `FinderHover-0.0.1.dmg`, and attaches it to the GitHub Release.

## Icon direction

The app icon uses a custom stacked-window mark: a focused Finder-like front window with offset translucent frames behind it. The concept communicates open-window selection and hover focus without copying Apple's Finder artwork.

Source assets are in `Assets/AppIcon.iconset/`; the macOS bundle asset is `Assets/AppIcon.icns`.

## Build

Build locally on macOS with Xcode command-line tools:

```bash
./build.sh
```

Package a DMG locally on macOS:

```bash
./package-dmg.sh
```

The GitHub release workflow runs automatically for tags matching `v*.*.*`.

## Permissions

The app uses macOS Accessibility APIs to read Finder windows and the Dock Finder item. Grant permission in **System Settings → Privacy & Security → Accessibility**. It does not read file contents, capture screenshots, or require Screen Recording permission.
