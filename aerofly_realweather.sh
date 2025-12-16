#!/bin/bash
# =======================================================
# Aerofly FS4 Dynamic Weather Updater
# =======================================================
# Fetches METAR weather for two ICAO stations,
# averages conditions, and updates Aerofly FS4's main.mcf
# with realistic blended weather including:
#   - wind (direction, strength, turbulence)
#   - visibility (nonlinear perception curve)
#   - cumulus clouds (multi-layer avg density & height)
#   - cirrus clouds (derived density & height)
#   - thermal activity and seasonal bias
#   - optional UTC time synchronization
#   - current position weather (cruise)
# Works on macOS and Linux.
# =======================================================

MCF="$HOME/Library/Application Support/Aerofly FS 4/main.mcf"

# ------------ Cross-platform SED Command ---------------
if [[ "$(uname)" == "Darwin" ]]; then
  SED_CMD="sed -i ''"
else
  SED_CMD="sed -i"
fi

# ------------ Color Codes ------------------------------
BOLD="\033[1m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ------------ Utility: Safe Numbers ---------------------
safe_number() {
  if [[ -z "$1" ]] || ! [[ "$1" =~ ^[0-9.]+$ ]]; then
    echo "$2"
  else
    echo "$1"
  fi
}

# ------------ Convert ECEF to Lat/Lon -------------------
ecef_to_latlon() {
  local X="$1" Y="$2" Z="$3"
  
  # WGS84 ellipsoid constants
  local A=6378137.0  # Semi-major axis
  local E2=0.00669437999014  # First eccentricity squared
  
  # Calculate using awk for floating point math
  awk -v x="$X" -v y="$Y" -v z="$Z" -v a="$A" -v e2="$E2" '
  BEGIN {
    pi = 3.14159265358979323846
    
    # Longitude
    lon = atan2(y, x) * 180 / pi
    
    # Latitude (iterative method)
    p = sqrt(x*x + y*y)
    lat = atan2(z, p * (1 - e2))
    
    for (i = 0; i < 5; i++) {
      sin_lat = sin(lat)
      N = a / sqrt(1 - e2 * sin_lat * sin_lat)
      lat = atan2(z + e2 * N * sin_lat, p)
    }
    
    lat = lat * 180 / pi
    
    printf "%.6f;%.6f", lat, lon
  }'
}

# ------------ Get Full Position with Altitude -----------
get_current_position_full() {
  if [[ ! -f "$MCF" ]]; then
    echo "Error: MCF file not found at $MCF" >&2
    return 1
  fi
  
  local POSITION VELOCITY X Y Z VX VY VZ
  
  # Extract position and velocity
  POSITION=$(awk '
    /<\[tmsettings_flight\]\[flight_setting\]/ { in_flight=1 }
    in_flight && /<\[vector3_float64\]\[position\]/ {
      match($0, /\[[-0-9. ]+\]/)
      print substr($0, RSTART+1, RLENGTH-2)
      exit
    }
  ' "$MCF")
  
  VELOCITY=$(awk '
    /<\[tmsettings_flight\]\[flight_setting\]/ { in_flight=1 }
    in_flight && /<\[vector3_float64\]\[velocity\]/ {
      match($0, /\[[-0-9. ]+\]/)
      print substr($0, RSTART+1, RLENGTH-2)
      exit
    }
  ' "$MCF")
  
  if [[ -z "$POSITION" ]]; then
    echo "Error: Could not extract aircraft position" >&2
    return 1
  fi
  
  # Parse coordinates
  X=$(echo "$POSITION" | awk '{print $1}')
  Y=$(echo "$POSITION" | awk '{print $2}')
  Z=$(echo "$POSITION" | awk '{print $3}')
  
  VX=$(echo "$VELOCITY" | awk '{print $1}')
  VY=$(echo "$VELOCITY" | awk '{print $2}')
  VZ=$(echo "$VELOCITY" | awk '{print $3}')
  
  # Convert to lat/lon
  local LATLON LAT LON
  LATLON=$(ecef_to_latlon "$X" "$Y" "$Z")
  IFS=';' read -r LAT LON <<< "$LATLON"
  
  # Calculate altitude MSL
  local ALT_M
  ALT_M=$(awk -v x="$X" -v y="$Y" -v z="$Z" '
  BEGIN {
    r = sqrt(x*x + y*y + z*z)
    alt = r - 6378137.0
    printf "%.0f", alt
  }')
  
  # Calculate ground speed
  local GS_MS GS_KTS
  GS_MS=$(awk -v vx="$VX" -v vy="$VY" -v vz="$VZ" '
  BEGIN {
    speed = sqrt(vx*vx + vy*vy + vz*vz)
    printf "%.1f", speed
  }')
  
  GS_KTS=$(echo "scale=1; $GS_MS * 1.94384" | bc)
  
  echo "$LAT;$LON;$ALT_M;$GS_KTS"
}

# ------------ Find Nearest Airport to Coordinates ------
find_nearest_airport() {
  local LAT="$1"
  local LON="$2"
  
  # Download and cache the airports CSV
  local AIRPORTS_CSV="/tmp/ourairports_cache.csv"
  
  if [[ ! -f "$AIRPORTS_CSV" ]] || \
     [[ $(find "$AIRPORTS_CSV" -mtime +7 2>/dev/null) ]]; then
    curl -s -o "$AIRPORTS_CSV" \
      "https://davidmegginson.github.io/ourairports-data/airports.csv" \
      2>/dev/null
    
    if [[ ! -s "$AIRPORTS_CSV" ]]; then
      echo "Error: Failed to download airports database" >&2
      return 1
    fi
  fi
  
  # Query nearest airport
  local NEAREST_ICAO
  NEAREST_ICAO=$(awk -F',' -v lat="$LAT" -v lon="$LON" '
    NR>1 && ($3=="\"large_airport\"" || $3=="\"medium_airport\"" || $3=="\"small_airport\"") {
      gsub(/"/, "", $5)
      gsub(/"/, "", $6)
      gsub(/"/, "", $2)
      alat=$5
      alon=$6
      icao=$2
      
      if (alat != "" && alon != "" && icao != "") {
        dist = sqrt((alat-lat)^2 + (alon-lon)^2)
        if (min=="" || dist<min) {
          min=dist
          best_icao=icao
        }
      }
    }
    END {
      if (best_icao != "") print best_icao
    }' "$AIRPORTS_CSV")
  
  echo "$NEAREST_ICAO"
}

# ------------ Fetch METAR -------------------------------
fetch_metar() {
  # Normalize station code to uppercase to prevent 301/empty fetch
  local ICAO=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  local METAR_LINE
  METAR_LINE=$(curl -fs \
    "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${ICAO}.TXT" \
    2>/dev/null | tail -n 1 | tr -d '\r\n')
  if [[ -z "$METAR_LINE" ]]; then
    echo "Warning: No METAR data returned for ${ICAO}" >&2
  fi
  echo "$METAR_LINE"
}

# ------------ Parse METAR -------------------------------
parse_metar() {
  local METAR="$1"

  # WIND PARSING (handles VRB and calm)
  local WIND DIR SPD GUST
  WIND=$(echo "$METAR" | \
    grep -oE '\b([0-9]{3}|VRB)[0-9]{2}(G[0-9]{2})?KT\b' | head -n1)

  if [[ -z "$WIND" ]]; then
    if echo "$METAR" | grep -q "VRB"; then
      DIR=180
      SPD=$(echo "$METAR" | grep -oE 'VRB[0-9]{2}' | \
        grep -oE '[0-9]{2}' | head -n1)
      GUST=$(echo "$METAR" | grep -oE 'G[0-9]{2}' | tr -d G)
    else
      DIR=0; SPD=0; GUST=0
    fi
  else
    if [[ "$WIND" == VRB* ]]; then
      DIR=180
      SPD=$(echo "$WIND" | grep -oE '[0-9]{2}' | head -n1)
    else
      DIR=$(echo "$WIND" | cut -c1-3)
      SPD=$(echo "$WIND" | cut -c4-5)
    fi
    GUST=$(echo "$WIND" | grep -oE 'G[0-9]{2}' | tr -d G)
  fi

  [[ -z "$GUST" ]] && GUST="$SPD"
  DIR=$(safe_number "$DIR" 0)
  SPD=$(safe_number "$SPD" 0)
  GUST=$(safe_number "$GUST" "$SPD")

  # VISIBILITY
  local VIS
  VIS=$(echo "$METAR" | grep -oE ' [0-9]{4} ' | tr -d ' ')
  VIS=$(safe_number "$VIS" 9999)

  # CLOUDS (multi-layer average)
  local CLOUDS COUNT SUM_DEN SUM_HT
  CLOUDS=$(echo "$METAR" | grep -oE '(FEW|SCT|BKN|OVC)[0-9]{3}')
  SUM_DEN=0; SUM_HT=0; COUNT=0

  while read -r L; do
    [[ -z "$L" ]] && continue
    local CODE HT_FT DEN
    CODE=$(echo "$L" | cut -c1-3)
    HT_FT=$(echo "$L" | cut -c4-6)
    local HT_M
    HT_M=$(echo "$HT_FT * 30.48" | bc | awk '{printf "%.0f",$0}')
    case $CODE in
      FEW) DEN=0.3 ;;
      SCT) DEN=0.5 ;;
      BKN) DEN=0.7 ;;
      OVC) DEN=1.0 ;;
      *) DEN=0.0 ;;
    esac
    SUM_DEN=$(echo "$SUM_DEN + $DEN" | bc)
    SUM_HT=$(echo "$SUM_HT + $HT_M" | bc)
    COUNT=$((COUNT + 1))
  done <<< "$CLOUDS"

  local CLOUD_DENS CLOUD_HT_M
  if (( COUNT > 0 )); then
    CLOUD_DENS=$(echo "scale=3; $SUM_DEN / $COUNT" | bc)
    CLOUD_HT_M=$(echo "scale=3; $SUM_HT / $COUNT" | bc)
  else
    CLOUD_DENS=0
    CLOUD_HT_M=0
  fi

  # NORMALIZATION
  local WN VN HN DIFF TBN
  WN=$(echo "scale=3; $SPD/40" | bc)
  (( $(echo "$WN > 1" | bc -l) )) && WN=1.0

  # Nonlinear visibility scaling
  VN=$(awk -v vis="$VIS" '
  BEGIN {
      max_vis = 50000
      scale = vis / max_vis
      if (scale > 1) scale = 1
      if (scale < 0) scale = 0
      val = 1 - exp(-5 * scale)
      print (val > 1 ? 1 : val)
  }')

  HN=$(echo "scale=3; $CLOUD_HT_M/3000" | bc)
  (( $(echo "$HN > 1" | bc -l) )) && HN=1.0

  # Nonlinear turbulence mapping
  DIFF=$(echo "$GUST - $SPD" | bc)
  (( $(echo "$DIFF < 0" | bc -l) )) && DIFF=0
  TBN=$(awk -v diff="$DIFF" 'BEGIN {
      val = diff / 20
      if (val < 0.05) val = 0.05
      if (val > 1) val = 1
      adj = val^1.6
      print adj
  }')
  if (( $(echo "$TBN < 0.1" | bc -l) )); then TBN=0.1; fi

  echo "$DIR;$WN;$VN;$HN;$CLOUD_DENS;$TBN"
}

# ------------ Compute derived values --------------------
compute_derived() {
  local VN="$1" HN="$2" DN="$3" WN="$4" TN="$5"

  local CDN CHN THM MONTH
  CDN=$(echo "scale=3; (1 - $VN) * 0.6 + ($DN * 0.4)" | bc)
  (( $(echo "$CDN > 1" | bc -l) )) && CDN=1.0
  (( $(echo "$CDN < 0.05" | bc -l) )) && CDN=0.05

  CHN=$(echo "scale=3; $HN * 3" | bc)
  (( $(echo "$CHN > 1" | bc -l) )) && CHN=1.0

  THM=$(echo "scale=3; $DN * 0.5 + $WN * 0.3 + (1 - $VN) * 0.2" | bc)
  (( $(echo "$THM > 1" | bc -l) )) && THM=1.0

  MONTH=$(date +%m)
  if (( MONTH < 3 || MONTH > 10 )); then
    THM=$(echo "$THM * 0.8" | bc)
    VN=$(echo "$VN * 0.9" | bc)
  fi

  echo "$CDN;$CHN;$THM;$VN"
}

# ------------ Get Airport Runways from OurAirports ------
get_airport_runways() {
  local ICAO="$1"
  local WIND_DIR="$2"

  # Fetch runway data for this airport from OurAirports
  local RUNWAYS
  RUNWAYS=$(curl -s \
    "https://davidmegginson.github.io/ourairports-data/runways.csv" \
    2>/dev/null | grep "\"$ICAO\"" | cut -d',' -f9,15)

  if [[ -z "$RUNWAYS" ]]; then
    # Fallback to generic suggestion if lookup fails
    suggest_runway "$WIND_DIR"
    return
  fi

  # Parse runway data and find matches for the wind direction
  local SUGGESTED_RWY
  SUGGESTED_RWY=$(suggest_runway "$WIND_DIR")

  # Extract the base runway number (without L/R/C suffix)
  local SUGGESTED_BASE=${SUGGESTED_RWY:0:2}
  local SUGGESTED_HDG=$((SUGGESTED_BASE * 10))

  # Get all runway designations for this airport
  local RWY_LIST
  RWY_LIST=$(echo "$RUNWAYS" | tr ',' '\n' | tr -d '"' | \
    grep -v '^$' | sort -u)

  # Find runways matching the suggested direction
  local MATCHING_RWYS
  MATCHING_RWYS=$(echo "$RWY_LIST" | grep "^$SUGGESTED_BASE" | \
    tr '\n' '/' | sed 's/\/$//')

  if [[ -n "$MATCHING_RWYS" ]]; then
    echo "$MATCHING_RWYS"
  else
    # If no exact match, find the closest runway heading
    local BEST_RWY=""
    local BEST_DIFF=9999

    while read -r RWY; do
      [[ -z "$RWY" ]] && continue
      # Extract runway number (first 2 chars), use base 10 to avoid octal
      local RWY_NUM=${RWY:0:2}
      local RWY_HDG=$((10#$RWY_NUM * 10))

      # Calculate angular distance (shortest path around 360°)
      local DIFF=$((WIND_DIR - RWY_HDG))
      [[ $DIFF -lt 0 ]] && DIFF=$((DIFF + 360))
      [[ $DIFF -gt 180 ]] && DIFF=$((360 - DIFF))

      # Keep track of closest runway
      if [[ $DIFF -lt $BEST_DIFF ]]; then
        BEST_DIFF=$DIFF
        BEST_RWY="$RWY"
      fi
    done <<< "$RWY_LIST"

    # Show recommended runway followed by all others
    if [[ -n "$BEST_RWY" ]]; then
      echo "$BEST_RWY (recommended) / $(echo "$RWY_LIST" | \
        grep -v "^$BEST_RWY" | tr '\n' '/' | sed 's/\/$//')"
    else
      echo "$RWY_LIST" | tr '\n' '/' | sed 's/\/$//'
    fi
  fi
}

# ------------ Suggest Runway Based on Wind --------------
suggest_runway() {
  local WIND_DIR="$1"
  local RUNWAY

  # Round wind direction to nearest 10 for runway number
  RUNWAY=$(( (WIND_DIR + 5) / 10 ))

  # Handle wraparound (36 wraps to 01)
  if (( RUNWAY > 35 )); then
    RUNWAY=1
  elif (( RUNWAY == 0 )); then
    RUNWAY=36
  fi

  # Format as two digits
  printf "%02d" "$RUNWAY"
}

# ------------ MCF Utilities -----------------------------
update_mcf() {
  local KEY="$1" VALUE="$2"
  $SED_CMD "s|<\[float64\]\[$KEY\].*|<[float64][$KEY][$VALUE]>|g" "$MCF"
}

apply_weather() {
  local DIR WN VN HN DN TN CDN CHN THM
  DIR="$1"; WN="$2"; VN="$3"; HN="$4"; DN="$5"
  TN="$6"; CDN="$7"; CHN="$8"; THM="$9"

  update_mcf "direction_in_degree" "$DIR"
  update_mcf "strength" "$WN"
  update_mcf "turbulence" "$TN"
  update_mcf "visibility" "$VN"
  update_mcf "cumulus_density" "$DN"
  update_mcf "cumulus_height" "$HN"
  update_mcf "cirrus_density" "$CDN"
  update_mcf "cirrus_height" "$CHN"
  update_mcf "thermal_activity" "$THM"
}

sync_time() {
  local YEAR MON DAY HOUR_DEC
  YEAR=$(date -u +"%Y")
  MON=$(date -u +"%m")
  DAY=$(date -u +"%d")
  HOUR_DEC=$(echo "scale=6; $(date -u +%H) + ($(date -u +%M)/60)" | bc)

  $SED_CMD \
    "s|<\[int32\]\[time_year\].*|<[int32][time_year][$YEAR]>|g" "$MCF"
  $SED_CMD \
    "s|<\[int32\]\[time_month\].*|<[int32][time_month][$MON]>|g" "$MCF"
  $SED_CMD \
    "s|<\[int32\]\[time_day\].*|<[int32][time_day][$DAY]>|g" "$MCF"
  $SED_CMD \
    "s|<\[float64\]\[time_hours\].*|<[float64][time_hours][$HOUR_DEC]>|g" \
    "$MCF"
}

# ------------ Flight Type Menu --------------------------
flight_type_menu() {
  echo "" >&2
  echo -e "${BOLD}${BLUE}What type of flight?${RESET}" >&2
  echo "  1. Full flight (origin → destination)" >&2
  echo "  2. Take off only" >&2
  echo "  3. Landing only" >&2
  echo "  4. Current position (cruise weather)" >&2
  echo "" >&2
  echo -n -e "${BOLD}Choose [1-4]: ${RESET}" >&2
  read -r CHOICE
  # Only output the choice, not the menu
  printf "%s" "$CHOICE"
}

# ------------ Single Airport Processing -----------------
process_single_airport() {
  local ICAO="$1"
  local SYNC_TIME_FLAG="$2"

  echo -e "${BOLD}${BLUE}Fetching METAR for $ICAO...${RESET}"

  local METAR
  METAR=$(fetch_metar "$ICAO")

  if [[ -z "$METAR" ]]; then
    echo -e "${YELLOW}METAR fetch failed. Using clear weather.${RESET}"
    apply_weather 0 0 1 1 0 0.1 0.05 1 0.2
    exit 0
  fi

  IFS=';' read D W VN HN CN TN <<< "$(parse_metar "$METAR")"

  IFS=';' read CDN CHN THM VN <<< \
    "$(compute_derived "$VN" "$HN" "$CN" "$W" "$TN")"

  cp "$MCF" "$MCF.bak"

  apply_weather "$D" "$W" "$VN" "$HN" "$CN" "$TN" "$CDN" "$CHN" "$THM"

  if [[ "$SYNC_TIME_FLAG" =~ ^([Yy]|[Yy][Ee][Ss]|--sync)$ ]]; then
    sync_time
  fi

  echo -e "\n${CYAN}--- Final Weather Summary ---${RESET}"
  printf "Wind Direction: %s° (Runway %s)\n" "$D" \
    "$(get_airport_runways "$ICAO" "$D")"
  echo "Wind Strength : $W"
  echo "Visibility    : $VN"
  echo "Cloud Base    : $HN"
  echo "Cumulus Dens. : $CN"
  echo "Cirrus Height : $CHN"
  echo "Cirrus Dens.  : $CDN"
  echo "Turbulence    : $TN"
  echo "Thermals      : $THM"
  [[ "$SYNC_TIME_FLAG" =~ ^[Yy-]*sync.*$ ]] && \
    echo "UTC Time Sync : enabled"
  echo -e "${CYAN}Weather successfully updated in Aerofly FS4.${RESET}\n"
}

# ------------ Process Full Flight -----------------------
process_full_flight() {
  local START END SYNC_TIME_FLAG
  START="$1"
  END="$2"
  SYNC_TIME_FLAG="$3"

  echo -e "${BOLD}${BLUE}Fetching METARs for $START and $END...${RESET}"

  local M1 M2
  M1=$(fetch_metar "$START")
  M2=$(fetch_metar "$END")

  if [[ -z "$M1" || -z "$M2" ]]; then
    echo -e "${YELLOW}METAR fetch failed. Using clear weather.${RESET}"
    apply_weather 0 0 1 1 0 0.1 0.05 1 0.2
    exit 0
  fi

  IFS=';' read D1 W1 V1N H1N C1N T1N <<< "$(parse_metar "$M1")"
  IFS=';' read D2 W2 V2N H2N C2N T2N <<< "$(parse_metar "$M2")"

  local DIR WN VN HN DN TN
  DIR=$(( (D1 + D2) / 2 ))
  WN=$(echo "scale=3; ($W1 + $W2)/2" | bc)
  VN=$(echo "scale=3; ($V1N + $V2N)/2" | bc)
  HN=$(echo "scale=3; ($H1N + $H2N)/2" | bc)
  DN=$(echo "scale=3; ($C1N + $C2N)/2" | bc)
  TN=$(echo "scale=3; ($T1N + $T2N)/2" | bc)

  IFS=';' read CDN CHN THM VN <<< \
    "$(compute_derived "$VN" "$HN" "$DN" "$WN" "$TN")"

  cp "$MCF" "$MCF.bak"

  apply_weather "$DIR" "$WN" "$VN" "$HN" "$DN" "$TN" "$CDN" "$CHN" "$THM"

  if [[ "$SYNC_TIME_FLAG" =~ ^([Yy]|[Yy][Ee][Ss]|--sync)$ ]]; then
    sync_time
  fi

  echo -e "\n${CYAN}--- Final Weather Summary (Blended) ---${RESET}"
  printf "Wind Direction: %s° (Runway %s at %s)\n" "$DIR" \
    "$(get_airport_runways "$START" "$DIR")" "$START"
  echo "Wind Strength : $WN"
  echo "Visibility    : $VN"
  echo "Cloud Base    : $HN"
  echo "Cumulus Dens. : $DN"
  echo "Cirrus Height : $CHN"
  echo "Cirrus Dens.  : $CDN"
  echo "Turbulence    : $TN"
  echo "Thermals      : $THM"
  [[ "$SYNC_TIME_FLAG" =~ ^[Yy-]*sync.*$ ]] && \
    echo "UTC Time Sync : enabled"
  echo -e "${CYAN}Weather successfully updated in Aerofly FS4.${RESET}\n"
}

# ------------ Main --------------------------------------
main() {
  local FLIGHT_TYPE START END SYNC_TIME_FLAG

  # Check for non-interactive mode with arguments
  if [[ "$1" =~ ^--(full|takeoff|landing|cruise)$ ]]; then
    FLIGHT_TYPE="$1"
    case "$FLIGHT_TYPE" in
      --full)
        START="$2"
        END="$3"
        SYNC_TIME_FLAG="$4"
        [[ -z "$START" || -z "$END" ]] && \
          { echo "Error: --full requires two ICAO codes"; exit 1; }
        process_full_flight "$START" "$END" "$SYNC_TIME_FLAG"
        ;;
      --takeoff)
        START="$2"
        SYNC_TIME_FLAG="$3"
        [[ -z "$START" ]] && \
          { echo "Error: --takeoff requires one ICAO code"; exit 1; }
        process_single_airport "$START" "$SYNC_TIME_FLAG"
        ;;
      --landing)
        END="$2"
        SYNC_TIME_FLAG="$3"
        [[ -z "$END" ]] && \
          { echo "Error: --landing requires one ICAO code"; exit 1; }
        process_single_airport "$END" "$SYNC_TIME_FLAG"
        ;;
      --cruise)
        SYNC_TIME_FLAG="$2"
        
        echo -e "${BOLD}${CYAN}Detecting current aircraft position...${RESET}"
        
        IFS=';' read LAT LON ALT_M GS_KTS <<< "$(get_current_position_full)"
        
        if [[ $? -ne 0 ]]; then
          echo "Failed to get position. Exiting."
          exit 1
        fi
        
        local ALT_FT
        ALT_FT=$(echo "$ALT_M * 3.28084" | bc | awk '{printf "%.0f", $0}')
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${BOLD}Current Position:${RESET}"
        echo "  Latitude  : ${LAT}°"
        echo "  Longitude : ${LON}°"
        echo "  Altitude  : ${ALT_FT} ft (${ALT_M} m)"
        echo "  Speed     : ${GS_KTS} kts"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        CURRENT_ICAO=$(find_nearest_airport "$LAT" "$LON")
        
        if [[ -z "$CURRENT_ICAO" ]]; then
          echo "Could not find nearby airport. Exiting."
          exit 1
        fi
        
        echo -e "${CYAN}Nearest airport: ${BOLD}$CURRENT_ICAO${RESET}"
        process_single_airport "$CURRENT_ICAO" "$SYNC_TIME_FLAG"
        ;;
    esac
  elif [[ "$1" && "$2" ]]; then
    # Legacy mode: two arguments without flag (assume full flight)
    START="$1"
    END="$2"
    SYNC_TIME_FLAG="$3"
    process_full_flight "$START" "$END" "$SYNC_TIME_FLAG"
  else
    # Interactive mode: show flight type menu
    FLIGHT_TYPE=$(flight_type_menu)
    case "$FLIGHT_TYPE" in
      1)
        echo -n "Start ICAO (origin): "; read -r START
        echo -n "End ICAO (destination): "; read -r END
        echo -n "Sync system UTC time? (y/n): "; read -r SYNC_TIME_FLAG
        process_full_flight "$START" "$END" "$SYNC_TIME_FLAG"
        ;;
      2)
        echo -n "Airport ICAO: "; read -r START
        echo -n "Sync system UTC time? (y/n): "; read -r SYNC_TIME_FLAG
        process_single_airport "$START" "$SYNC_TIME_FLAG"
        ;;
      3)
        echo -n "Airport ICAO: "; read -r END
        echo -n "Sync system UTC time? (y/n): "; read -r SYNC_TIME_FLAG
        process_single_airport "$END" "$SYNC_TIME_FLAG"
        ;;
      4)
        echo -e "${BOLD}${CYAN}Detecting current aircraft position...${RESET}"
        
        IFS=';' read LAT LON ALT_M GS_KTS <<< "$(get_current_position_full)"
        
        if [[ $? -ne 0 ]]; then
          echo "Failed to get position. Exiting."
          exit 1
        fi
        
        local ALT_FT
        ALT_FT=$(echo "$ALT_M * 3.28084" | bc | awk '{printf "%.0f", $0}')
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${BOLD}Current Position:${RESET}"
        echo "  Latitude  : ${LAT}°"
        echo "  Longitude : ${LON}°"
        echo "  Altitude  : ${ALT_FT} ft (${ALT_M} m)"
        echo "  Speed     : ${GS_KTS} kts"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        CURRENT_ICAO=$(find_nearest_airport "$LAT" "$LON")
        
        if [[ -z "$CURRENT_ICAO" ]]; then
          echo "Could not find nearby airport. Exiting."
          exit 1
        fi
        
        echo -e "${CYAN}Nearest airport: ${BOLD}$CURRENT_ICAO${RESET}"
        echo -n "Sync system UTC time? (y/n): "; read -r SYNC_TIME_FLAG
        process_single_airport "$CURRENT_ICAO" "$SYNC_TIME_FLAG"
        ;;
      *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
    esac
  fi
}

main "$@"