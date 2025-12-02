# Aerofly FS4 Dynamic Weather Updater

## Overview

This script fetches live METAR weather reports for two airports, averages the conditions,
and writes the results into Aerofly FS4's "main.mcf" configuration file to simulate
dynamic real-world weather.

It processes wind, visibility, turbulence, clouds, thermals, and optionally synchronizes
the simulator's UTC time. The script runs on macOS and Linux.

## Features

- Fetches and parses real-world METARs from the NOAA server
- Handles calm and variable winds (00000KT, VRBxxKT)
- Averages weather between two ICAO airports for smoother transitions
- Nonlinear scaling for:
  - Visibility (realistic haze perception)
  - Turbulence (softer light gusts, stronger heavy ones)
- Multi-layer cloud averaging for cumulus formation
- Derived cirrus layer density and height
- Thermal activity estimation with seasonal adjustment
- Optional synchronization of Aerofly FS4's time to current UTC
- Automatic backup of your "main.mcf" before modification
- Works in interactive or automatic (no-prompt) mode

## Installation

1. Copy `aerofly_realweather.sh` to any folder.
2. Make it executable:
   ```bash
   chmod +x aerofly_realweather.sh
   ```

3. Verify the configuration path for Aerofly FS4:
   - **macOS**: `~/Library/Application Support/Aerofly FS 4/main.mcf`
   - **Linux**: `~/.config/aerofly_fs_4/main.mcf`

   Adjust the MCF variable in the script if necessary.

## Usage

### Interactive Mode

Run the script and choose your flight type:

```bash
./aerofly_realweather.sh
```

You'll be presented with a menu:
```
What type of flight?
  1. Full flight (origin → destination)
  2. Take off only
  3. Landing only
Choose [1-3]:
```

**Option 1: Full flight**
```
Start ICAO (origin): EGGW
End ICAO (destination): EGCC
Sync system UTC time? (y/n): y
```
Fetches and averages weather from both airports.

**Option 2: Take off only**
```
Airport ICAO: KJFK
Sync system UTC time? (y/n): y
```
Fetches weather for the departure airport only.

**Option 3: Landing only**
```
Airport ICAO: KLAX
Sync system UTC time? (y/n): y
```
Fetches weather for the arrival airport only.

### Non-Interactive / Automatic Mode

Use flags to run without prompts. Three flight modes available:

**Full flight** (blends two airports):
```bash
./aerofly_realweather.sh --full EGGW EGCC --sync-time
```

**Take off only** (single airport):
```bash
./aerofly_realweather.sh --takeoff KJFK --sync-time
```

**Landing only** (single airport):
```bash
./aerofly_realweather.sh --landing KLAX --sync-time
```

Omit `--sync-time` to skip UTC synchronization:
```bash
./aerofly_realweather.sh --full KJFK KLAX
./aerofly_realweather.sh --takeoff KJFK
./aerofly_realweather.sh --landing KLAX
```

**Legacy mode** (backward compatible):
```bash
./aerofly_realweather.sh EGGW EGCC
```
Running with two ICAO codes (no flag) defaults to full flight mode.

## Example Output

```
--- Final Weather Summary ---
Wind Direction: 180°
Wind Strength : 0.16
Visibility    : 0.57
Cloud Base    : 0.11
Cumulus Dens. : 0.15
Cirrus Height : 0.33
Cirrus Dens.  : 0.28
Turbulence    : 0.10
Thermals      : 0.16
UTC Time Sync : enabled
Weather successfully updated
```
