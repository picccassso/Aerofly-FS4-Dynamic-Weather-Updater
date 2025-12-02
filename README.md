This Bash script retrieves current METAR weather data for two airports, averages the conditions, and writes the resulting weather parameters into Aerofly FS4’s main.mcf configuration file. It updates the following parameters:


- Wind: direction, strength, and turbulence (based on gust factors)

- Visibility: scaled from reported METAR visibility

- Clouds: cumulus density and height, cirrus density and height (derived from conditions)

- Thermal activity: estimated using wind, visibility, and cloud coverage

- Time (optional): synchronizes the simulator’s UTC time with real-world UTC time

All values are normalized to match Aerofly FS4’s internal [0–1] scale, except wind direction (degrees). The script fetches, parses, averages, and updates the configuration automatically to reflect realistic and smoothly blended weather conditions between two locations.