# Treadmill

macOS menu bar app for controlling a **Merach T25 treadmill** via Bluetooth (FTMS protocol).

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Menu bar controls** — start, stop, pause, adjust speed and incline from the status bar
- **Auto-connect** — scans and connects to your Merach T25 automatically on launch
- **Quick presets** — one-click speed/incline presets (Walk, Brisk, Hill, or custom)
- **Session tracking** — auto-records workouts with distance, time, calories, speed over time
- **Workout history** — browse past sessions with charts (speed/incline over time, weekly trends)
- **Interval programs** — create multi-segment workouts with speed, incline, and time/distance/calorie goals
- **Apple Health** — ready to sync workouts when HealthKit becomes available on macOS
- **Settings** — configurable speed/incline steps, session duration threshold, launch at login

## Requirements

- macOS 14 (Sonoma) or later
- Merach T25 treadmill (or compatible FTMS Bluetooth treadmill)
- Bluetooth enabled

## Install

### Download

Grab the latest `.dmg` or `.zip` from [Releases](https://github.com/Abraxis/tmill/releases).

### Build from source

```bash
# Install xcodegen (one time)
brew install xcodegen

# Clone and build
git clone https://github.com/Abraxis/tmill.git
cd tmill
xcodegen generate
xcodebuild build -project Treadmill.xcodeproj -scheme Treadmill \
  -configuration Release -destination 'platform=macOS' SYMROOT=build

# Run
open build/Release/Treadmill.app
```

Or open `Treadmill.xcodeproj` in Xcode and hit ⌘R.

## Usage

1. **Turn on your Merach T25** using its remote control
2. **Launch Treadmill** — it appears as a 🚶 icon in the menu bar
3. The app auto-connects via Bluetooth (status shown in the dropdown)
4. **Click the menu bar icon** to see live stats and controls
5. Use **Start/Stop/Pause** and **Speed ±/Incline ±** to control the treadmill
6. **Quick presets** let you switch speed/incline with one click

### Menu bar

| State | Menu bar shows |
|-------|---------------|
| Disconnected | 🚶 icon only |
| Connected, idle | 🚶 icon only |
| Running | 🚶 + current speed (e.g. `3.5`) |

### Keyboard shortcuts (when menu is open)

The treadmill must be started first using its remote control before the app can send commands.

### Settings

Access from the menu dropdown → **Settings...**

**General tab:**
- Launch at login
- Apple Health sync status
- Minimum session duration (sessions shorter than this aren't saved)
- Speed/incline step sizes for the +/- buttons

**Quick Presets tab:**
- Create named presets with specific speed and incline
- Presets appear in the menu dropdown for one-tap changes

### Workout Programs

Access from **Edit Programs...** in the menu.

Create interval programs with multiple segments. Each segment has:
- Target speed (km/h)
- Target incline (%)
- Goal: time (minutes), distance (meters), or calories

## Architecture

```
Treadmill/
├── Bluetooth/
│   ├── FTMSProtocol.swift      # BLE FTMS encode/decode (pure logic, fully tested)
│   └── TreadmillManager.swift  # CoreBluetooth scan/connect/command
├── Models/
│   ├── TreadmillState.swift    # Observable live state
│   ├── CoreDataModel.swift     # Programmatic Core Data model
│   └── *+CoreData.swift        # Managed object subclasses
├── Services/
│   ├── PersistenceController.swift  # Core Data stack
│   ├── SessionTracker.swift    # Auto-record workouts
│   ├── ProgramEngine.swift     # Run interval programs
│   ├── SettingsManager.swift   # UserDefaults + quick presets
│   └── HealthKitManager.swift  # Apple Health integration (ready)
└── Views/
    ├── MenuBarView content     # In TreadmillApp.swift
    ├── HistoryWindow.swift     # Session list + trends
    ├── SessionDetailView.swift # Per-session charts
    ├── TrendsView.swift        # Weekly/monthly charts
    ├── ProgramEditorView.swift # Create/edit programs
    └── SettingsView.swift      # General + Presets tabs
```

## FTMS Protocol

Uses the standard Bluetooth **Fitness Machine Service (FTMS)** protocol:

| Characteristic | UUID | Usage |
|---------------|------|-------|
| Treadmill Data | `0x2ACD` | Live speed, distance, incline, calories, time |
| Control Point | `0x2AD9` | Start, stop, set speed/incline |
| Machine Status | `0x2ADA` | Belt started/stopped events |
| Training Status | `0x2AD3` | Training mode changes |

**Treadmill limits:** Speed 1.0–6.5 km/h, Incline 0–12%

## Development

```bash
# Generate Xcode project
xcodegen generate

# Build
xcodebuild build -project Treadmill.xcodeproj -scheme Treadmill -destination 'platform=macOS' SYMROOT=build

# Run tests
xcodebuild test -project Treadmill.xcodeproj -scheme Treadmill -destination 'platform=macOS'

# Package DMG
./scripts/build.sh && ./scripts/create-dmg.sh

# Create GitHub release
./scripts/release.sh 1.0.0
```

## License

MIT
