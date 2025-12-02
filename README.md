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

Run the script and enter ICAO codes when prompted:

```bash
./aerofly_realweather.sh
```

Example:
```
Start ICAO: EGGW
End ICAO:   EGCC
Sync system UTC time? (y/n): y
```

### Automatic / Non-Interactive Mode

Run the script with both ICAO codes and optionally `--sync-time`:

```bash
./aerofly_realweather.sh EGGW EGCC --sync-time
```

To skip UTC sync:
```bash
./aerofly_realweather.sh KJFK KLAX
```

This version runs without user input — ideal for automation.

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
