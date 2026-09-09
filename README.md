# ScreenControl

A small, free macOS menu bar app for controlling external displays, built as a personal
replacement for [BetterDisplay](https://github.com/waydabber/betterdisplay). The headline
feature is **display rotation with a global keyboard shortcut**; it also switches resolution
and refresh rate, dims displays in software, and toggles mirroring.

Requires macOS 14 (Sonoma) or later. Works on Apple Silicon and Intel Macs.

## Features

- **Rotate any external display** to 0°, 90°, 180° or 270° from the menu bar.
- **Global hotkeys** for rotation that work no matter which app is in front. Defaults:

  | Shortcut | Action |
  |---|---|
  | ⌃⌥⌘ → | Rotate +90° (clockwise) |
  | ⌃⌥⌘ ← | Rotate −90° (counterclockwise) |
  | ⌃⌥⌘ ↑ | Toggle portrait / landscape (0° ↔ 90°) |
  | ⌃⌥⌘ ↓ | Back to 0° (standard) |

  Every action is re-recordable in **Settings → Shortcuts**, and there are extra assignable
  actions for jumping straight to 90°, 180° or 270°.
- **Choose what the hotkeys act on**: the display under the mouse pointer (default), the main
  display, all external displays at once, or one specific monitor.
- **Resolution and refresh rate** switching per display, including HiDPI variants.
- **Software dimming** (gamma-based) per display, for monitors that are too bright at their
  lowest hardware setting. Remembered per display; reset when the app quits.
- **Mirroring** toggle for secondary displays.
- **Launch at login**, no Dock icon, no Accessibility permission prompts.

## Install

1. Clone the repo and open the project:

   ```bash
   git clone https://github.com/boboborenstein-collab/ScreenControl.git
   cd ScreenControl
   open ScreenControl.xcodeproj
   ```

2. In Xcode press **⌘R** to build and run. The app appears as a rotate icon in the menu bar.

3. To install it permanently, build a Release copy into `/Applications`:

   ```bash
   scripts/build-app.sh --install
   ```

   Then turn on **Settings → General → Launch ScreenControl at login**.

No Apple Developer account is needed: the project signs "to run locally" (ad hoc). If you
have a team set up in Xcode you can pick it under Signing & Capabilities instead.

### Without Xcode.app

With just the Command Line Tools installed you can build a bare executable with SwiftPM:

```bash
swift build -c release
.build/release/ScreenControl
```

That gives you the same menu bar app without a `.app` bundle (so no Launch at login).

## How rotation works

Reading a display's rotation is public API (`CGDisplayRotation`), but macOS has no public
API for **setting** it. ScreenControl resolves private entry points at runtime and tries them
in order, confirming after each attempt that the display really reports the new angle:

1. `SLSSetDisplayRotation` in `SkyLight.framework` — the call System Settings itself makes,
   and the only one that works for Apple Silicon displays driven by the DCP.
2. `-[MPDisplay setOrientation:]` in `MonitorPanel.framework` — the mechanism
   [displayplacer](https://github.com/jakehilborn/displayplacer) uses.
3. `IOServiceRequestProbe` with `kIOFBSetTransform` on the display's `IOFramebuffer` — the
   classic Intel-only route.

Nothing is linked against a private framework at build time; symbols are looked up with
`dlopen`/`dlsym` and the ObjC runtime, so the app still launches if Apple removes one of them
(that backend simply reports as unavailable in **Settings → General → Rotation mechanism**).

Because these are private APIs, a future macOS release could break rotation. If that happens,
the menu and hotkeys will show an error rather than silently doing nothing.

Global shortcuts use Carbon's `RegisterEventHotKey`, which fires system-wide without the app
needing Accessibility or Input Monitoring permission.

## Project layout

```
ScreenControl.xcodeproj/        Xcode project (file-system-synchronized source folder)
ScreenControl/
  App/            App entry point, AppDelegate, AppModel (observable state + actions)
  Displays/       DisplayInfo model and CoreGraphics wrappers (modes, mirroring, gamma)
  Rotation/       RotationService: SkyLight → MonitorPanel → IOKit rotation chain
  Hotkeys/        KeyboardShortcut model, HotkeyAction/HotkeyTarget, Carbon HotkeyManager
  Menu/           SwiftUI MenuBarExtra content
  Settings/       SettingsStore (UserDefaults), settings window + views, shortcut recorder
Package.swift                   Secondary SwiftPM build (bare executable)
scripts/build-app.sh            Release build / install helper
```

The project uses Xcode's synchronized groups, so dropping a new `.swift` file anywhere under
`ScreenControl/` adds it to the build automatically.

## Troubleshooting

- **"Couldn't rotate" alert.** Open Settings → General and check which rotation mechanisms are
  listed as available. On Apple Silicon, `SkyLight` must be present. Some displays (TVs,
  AirPlay targets, Sidecar iPads) refuse rotation at the WindowServer level.
- **The built-in display is not rotatable.** That is deliberate; enable it in Settings →
  General if you really want it.
- **A shortcut does nothing.** Another app may have registered the same combination first;
  record a different one. Shortcuts need at least one of ⌘, ⌥ or ⌃.
- **macOS says the app is damaged / from an unidentified developer.** The app is ad-hoc
  signed. Right-click → Open once, or run
  `xattr -dr com.apple.quarantine /Applications/ScreenControl.app`.

## Credits

Inspired by BetterDisplay. The rotation and hotkey techniques were informed by the open-source
[Crisp](https://github.com/didriksg/Crisp), [FreeDisplay](https://github.com/huberdf/FreeDisplay)
and [displayplacer](https://github.com/jakehilborn/displayplacer) projects.

## License

MIT — see [LICENSE](LICENSE).
