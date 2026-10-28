# ScreenControl

A small, free macOS menu bar app for controlling external displays. The headline
feature is **display rotation with a global keyboard shortcut**; it also sends the keyboard's
**brightness keys to the monitor under the mouse**, switches resolution and refresh rate, dims
displays in software, and toggles mirroring.

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
- **Brightness keys follow the mouse.** Press the keyboard's brightness keys (F1/F2 or the
  sun keys) while the pointer is on an external monitor and *that monitor's* brightness changes,
  with the normal macOS brightness overlay drawn on it. Move the pointer back to the MacBook
  screen and the same keys adjust the built-in display as usual. ⌥⇧ gives fine steps. There is
  also a Brightness picker per display in the menu. Needs the **Accessibility** permission
  (see below).
- **Dim to black.** A monitor's own brightness setting bottoms out at "dim", never "off", so the
  lowest four brightness steps keep dimming in software until the picture is completely black
  (BetterDisplay's "combined" brightness). Can be turned off in Settings.
- **Turn a display off and back on** from its menu or with a shortcut. On Apple Silicon this
  is a real disconnect (the monitor sleeps, windows move to the remaining displays); turning it
  back on brings it straight back, no cable fiddling. Elsewhere the monitor is put into standby
  over DDC/CI instead. Anything left off is restored when the app quits.
- **Switch the monitor's input** (HDMI 1/2, DisplayPort, USB-C…) from the menu or a shortcut,
  for monitors shared with a PC or console. Uses DDC/CI, so it works on the same monitors the
  brightness keys work on.
- **Presets**: save the current setup (rotation, resolution, refresh rate, brightness and
  dimming of every connected display) under a name and restore it from the menu or with its own
  global shortcut. Displays are matched by hardware identity, so presets survive reconnects.
- **Resolution and refresh rate** switching per display, including HiDPI variants.
- **Software dimming** (gamma-based) per display, for monitors that are too bright at their
  lowest hardware setting. Remembered per display; reset when the app quits.
- **Mirroring** toggle for secondary displays.
- **Launch at login**, no Dock icon.

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

4. For the brightness keys, grant the Accessibility permission when macOS asks (or use
   **Settings → General → Brightness keys → Request Permission…**). Everything else works
   without it.

No Apple Developer account is needed: the project signs "to run locally" (ad hoc). If you
have a team set up in Xcode you can pick it under Signing & Capabilities instead.

### Updating

Updating is the same two commands: pull the latest source and rebuild into `/Applications`.
The script quits the running copy, replaces it and relaunches it, and your settings are kept.

```bash
cd ScreenControl
git pull
scripts/build-app.sh --install
```

One caveat of ad-hoc signing: macOS ties the Accessibility permission to the exact build, so
after an update the brightness keys may stop working until you remove ScreenControl from
**System Settings → Privacy & Security → Accessibility** (select it, press −) and add it back.
Rotation, hotkeys and everything else are unaffected.

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

## How the brightness keys work

Brightness keys reach applications as `NX_SYSDEFINED` "aux control" events, which only a
CGEvent tap can see. ScreenControl installs one (this is what needs the Accessibility
permission) and, on each press, looks at which display the mouse pointer is on:

- **Built-in display** (or an Apple display such as a Studio Display): the event is passed
  through untouched and macOS handles it exactly as before.
- **External monitor**: the event is swallowed and the monitor's brightness is changed over
  **DDC/CI**, the I2C protocol monitors use for their on-screen menu settings. On Apple Silicon
  this goes through the DCP's `IOAVService` (private IOKit functions resolved at runtime, the
  same route MonitorControl, Crisp and BetterDisplay use); on Intel through the framebuffer's
  public `IOI2CInterface`. The native brightness bezel is shown on that monitor via
  `OSDUIHelper`.
- **Monitors that ignore DDC/CI** (some TVs, most displays behind USB-C docks or DisplayLink
  adapters) fall back to software dimming, so the keys still do something; the menu shows which
  mode is in use.
- **Below the hardware minimum** the top 12 of the 16 key steps drive the monitor's backlight
  and the bottom 4 scale the gamma table (`CGSetDisplayTransferByFormula`) from the monitor's
  dimmest setting down to black. The extra dimming is transient: it is undone when the app
  quits, and never persisted, so a display cannot come back black after a restart.

## Display off/on, inputs and presets

- **Turn off** uses `SLSConfigureDisplayEnabled` (SkyLight, resolved at runtime) inside a
  `CGBeginDisplayConfiguration` transaction, which is what BetterDisplay's *Disconnect* does.
  The display vanishes from `CGGetOnlineDisplayList`, so ScreenControl remembers it (by its
  persistent ID) and finds it again through `SLSGetDisplayList` to re-enable it. It refuses to
  turn off the last active display. On Intel the SkyLight call is a no-op, so the monitor is
  sent DDC/CI power-mode standby (VCP `0xD6`) instead.
- **Input switching** writes DDC/CI VCP `0x60`. Standard codes are used (HDMI 1 = `0x11`,
  HDMI 2 = `0x12`, DisplayPort = `0x0F`, USB-C = `0x1B`; LG uses `0x19` for USB-C). If you switch
  the monitor to another device, macOS loses the display, so the way back is the monitor's own
  buttons (or the other device switching it back).
- **Presets** are stored as JSON in the app's preferences. Applying one rotates first (the slow,
  asynchronous step), then picks the saved resolution/refresh rate (matching either orientation,
  since rotated displays report swapped dimensions), then brightness and dimming.

## Project layout

```
ScreenControl.xcodeproj/        Xcode project (file-system-synchronized source folder)
ScreenControl/
  App/            App entry point, AppDelegate, AppModel (observable state + actions)
  Displays/       DisplayInfo model and CoreGraphics wrappers (modes, mirroring, gamma)
  Rotation/       RotationService: SkyLight → MonitorPanel → IOKit rotation chain
  Brightness/     DDCService (I2C transport), BrightnessService (levels, fallback), key tap, OSD
  Power/          DisplayPowerService: SkyLight disconnect / DDC standby, remembers what is off
  Inputs/         DisplayInput codes and InputService (DDC/CI VCP 0x60)
  Presets/        DisplayPreset model (capture/apply live in AppModel)
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
- **Brightness keys still change the MacBook screen while the mouse is on the monitor.** Open
  Settings → General → Brightness keys: the permission line must say "Granted". If it doesn't,
  click *Open Accessibility Settings* and enable ScreenControl; if it is already enabled there,
  remove it and add it again (see *Updating*). Also make sure no other display utility
  (BetterDisplay, MonitorControl, Lunar) is grabbing the keys at the same time.
- **"Turn Off Display" is greyed out.** Either it is the only active display, or (on Intel) the
  monitor does not answer DDC/CI so there is no standby command to send.
- **A turned-off display did not come back.** Use the menu's *Turned Off → Turn On …* item
  again; if macOS has lost track of it, unplug and reconnect the cable. Quitting ScreenControl
  also re-enables every display it turned off.
- **The monitor ignores the input switch.** Not all monitors implement VCP 0x60, and some use
  non-standard codes for USB-C (try both USB-C entries). The monitor's on-screen menu may also
  need "DDC/CI" enabled.
- **The menu says "Software dimming (monitor ignores DDC/CI)".** The monitor did not answer the
  brightness query. Check the monitor's own menu for a "DDC/CI" setting and turn it on; monitors
  behind docks or DisplayLink adapters usually cannot be reached at all.
- **macOS says the app is damaged / from an unidentified developer.** The app is ad-hoc
  signed. Right-click → Open once, or run
  `xattr -dr com.apple.quarantine /Applications/ScreenControl.app`.

## Credits

Inspired by BetterDisplay. The rotation, DDC/CI, brightness-key and hotkey techniques were
informed by the open-source [Crisp](https://github.com/didriksg/Crisp),
[FreeDisplay](https://github.com/huberdf/FreeDisplay),
[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
[displayplacer](https://github.com/jakehilborn/displayplacer) projects.

## License

MIT — see [LICENSE](LICENSE).
