# Menu Bar Refactoring: SwiftUI MenuBarExtra to NSMenu

## Problem

The current SwiftUI `MenuBarExtra` implementation causes menu items to flicker when state changes. `MenuBarExtra` rebuilds the underlying `NSMenu` on every SwiftUI body re-evaluation rather than updating items in-place. Observable state from BLE frames (every ~500ms) and the 2s timer trigger these rebuilds. The user also wants live-updating stats while the menu is open.

## Solution

Replace `MenuBarExtra` with a hand-managed `NSStatusItem` + `NSMenu`. Menu items are created once and updated in-place by mutating `.title` and `.isHidden` properties. This eliminates flicker and enables live updates.

## Architecture

### New file: `Treadmill/StatusBarController.swift`

A class that owns the menu bar presence:

```
StatusBarController
  - statusItem: NSStatusItem
  - menu: NSMenu
  - references to all mutable NSMenuItems
  - appState: AppState (unowned)
  - conforms to NSMenuDelegate
```

### New property: `TreadmillState.elevationGain`

A live-accumulated `Double` computed from distance deltas and current incline on each `update(from:)` call. Reset when treadmill stops (mirrors session lifecycle). Displayed in the menu as "Elevation: X m".

### Menu item layout

Items are created once at init and stored as properties for in-place updates:

```
statusItem              "DeviceName -- 3.5 km/h" | "MyMill"
---separator---
speedItem               "Speed: 3.5 km/h"          (hidden when disconnected)
inclineItem             "Incline: 2%"               (hidden when disconnected)
distanceItem            "Distance: 1.23 km"         (hidden when disconnected)
timeItem                "Time: 12:34"               (hidden when disconnected)
caloriesItem            "Calories: 150 kcal"        (hidden when disconnected)
elevationItem           "Elevation: 45 m"           (hidden when disconnected)
---separator---                                     (hidden when disconnected)
startItem               "Start"                     (hidden when running)
stopItem                "Stop"                      (hidden when not running)
pauseItem               "Pause"                     (hidden when not running)
---separator---                                     (hidden when disconnected)
speedUpItem             "Speed + (0.5)"             (hidden when disconnected)
speedDownItem           "Speed - (0.5)"             (hidden when disconnected)
inclineUpItem           "Incline + (1%)"            (hidden when disconnected)
inclineDownItem         "Incline - (1%)"            (hidden when disconnected)
---separator---                                     (hidden when no presets or disconnected)
preset items            "Walk -- 3.0 km/h, 0%"     (rebuilt only when settings change)
---separator---
connectionStatusItem    "Scanning..." | etc         (hidden when connected)
hintItem                "Turn on treadmill..."      (hidden when connected)
---separator---
errorSeparator                                      (hidden when no error)
errorItem               "! some error"              (hidden when no error)
---separator---
historyItem             "Open History..."           Cmd+H
programsItem            "Edit Programs..."
settingsItem            "Settings..."               Cmd+,
---separator---
quitItem                "Quit MyMill"               Cmd+Q
```

### Action handling

A small `MenuAction` helper class (NSObject subclass) wraps async closures:

```swift
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func perform() { handler() }
}
```

Each button item gets its own `MenuAction` instance stored in a retained array. Actions that call `TreadmillManager` wrap in `Task.detached { await ... }`.

### Update flow

1. **Timer-driven (2s)**: The existing timer in `AppState.init` calls `statusBarController.update()` which:
   - Updates status bar button title (speed or "MyMill")
   - Updates all stat item titles from current `TreadmillState` values
   - Toggles start/stop/pause visibility based on `isRunning`
   - Toggles connected vs disconnected item sets
   - Shows/hides error item

2. **Menu-open refresh**: `NSMenuDelegate.menuNeedsUpdate(_:)` calls `update()` so menu is never stale on open.

3. **Preset sync**: Presets only change via Settings UI (rare). On update, old preset items are removed and new ones inserted. Could observe `SettingsManager.quickPresets` or just rebuild on `menuNeedsUpdate`.

### Integration changes

**`TreadmillApp.swift`**:
- Remove `MenuBarExtra` from App body (keep Window scenes)
- Remove `MenuBarContentView` struct
- Remove `MenuSnapshot` struct
- `AppState` creates and holds `StatusBarController`
- Timer calls `statusBarController.update()` alongside existing session/program logic

**`TreadmillState.swift`**:
- Add `var elevationGain: Double = 0`
- Add `private var lastDistance: Double = 0`
- In `update(from:)`: compute elevation delta from distance delta * (incline / 100), accumulate into `elevationGain`
- Reset `elevationGain` and `lastDistance` when treadmill stops (zeroSpeedCount threshold reached)

### Window opening

Menu actions for History/Programs/Settings need to open SwiftUI windows. Use `NSApplication.shared.activate(ignoringOtherApps: true)` and post a notification or call a closure that the App struct picks up via `@Environment(\.openWindow)`. Alternatively, since `AppState` can hold an `openWindow` callback set by the App body's `onAppear`, the controller calls that directly.

Simplest approach: `StatusBarController` stores closures like `onOpenHistory`, `onOpenPrograms`, `onOpenSettings` that `TreadmillApp` sets after init.

## Files changed

| File | Change |
|------|--------|
| `Treadmill/StatusBarController.swift` | New: ~150 lines |
| `Treadmill/TreadmillApp.swift` | Remove MenuBarExtra/MenuBarContentView/MenuSnapshot, wire StatusBarController |
| `Treadmill/Models/TreadmillState.swift` | Add elevationGain accumulation |

## Testing

- Existing `TreadmillTests` continue to pass (no test changes needed for menu — it's UI)
- Add unit test for `TreadmillState.elevationGain` accumulation logic
- Manual verification: open menu while treadmill running, confirm no flicker, stats update every 2s
