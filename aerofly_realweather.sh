#!/bin/bash
# =======================================================
# Aerofly FS4 Dynamic Weather Updater
# =======================================================
# DESCRIPTION:
#   Fetches METAR weather from two ICAO stations,
#   averages conditions, and updates Aerofly FS4's main.mcf
#   with realistic, blended conditions including:
#   - wind direction, strength, turbulence
#   - visibility
#   - cumulus density & height (multi-layer)
#   - cirrus density & height
#   - thermal activity
#   - optional UTC time synchronization
#   - cross-platform (macOS & Linux)
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

# ------------ Fetch METAR -------------------------------
fetch_metar() {
  local ICAO="$1"
  local DATA
  DATA=$(curl -fs "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${ICAO}.TXT" 2>/dev/null | tail -n 1)
  echo "$DATA"
}

# ------------ Parse METAR -------------------------------
parse_metar() {
  local METAR="$1"

  # WIND
  local WIND DIR SPD GUST
  WIND=$(echo "$METAR" | grep -oE '[0-9]{3}[0-9]{2}(G[0-9]{2})?KT' | head -n1)
  DIR=$(safe_number "$(echo "$WIND" | cut -c1-3)" 0)
  SPD=$(safe_number "$(echo "$WIND" | cut -c4-5)" 0)
  GUST=$(echo "$WIND" | grep -oE 'G[0-9]{2}' | tr -d G)
  [ -z "$GUST" ] && GUST="$SPD"
  GUST=$(safe_number "$GUST" "$SPD")

  # VISIBILITY
  local VIS
  VIS=$(echo "$METAR" | grep -oE ' [0-9]{4} ' | tr -d ' ')
  VIS=$(safe_number "$VIS" 9999)

  # CLOUDS (multi-layer average)
  local CLOUDS LAYERS COUNT SUM_DEN SUM_HT
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

  VN=$(echo "scale=3; $VIS/20000" | bc)
  (( $(echo "$VN > 1" | bc -l) )) && VN=1.0

  HN=$(echo "scale=3; $CLOUD_HT_M/3000" | bc)
  (( $(echo "$HN > 1" | bc -l) )) && HN=1.0

  DIFF=$(echo "$GUST - $SPD" | bc)
  (( $(echo "$DIFF < 0" | bc -l) )) && DIFF=0
  TBN=$(echo "scale=3; $DIFF/10" | bc)
  (( $(echo "$TBN > 1" | bc -l) )) && TBN=1.0
  (( $(echo "$TBN < 0.1" | bc -l) )) && TBN=0.1

  echo "$DIR;$WN;$VN;$HN;$CLOUD_DENS;$TBN"
}

# ------------ Compute derived values --------------------
compute_derived() {
  local VN="$1" HN="$2" DN="$3" WN="$4" TN="$5"

  # Cirrus
  local CDN CHN
  CDN=$(echo "scale=3; (1 - $VN) * 0.6 + ($DN * 0.4)" | bc)
  (( $(echo "$CDN > 1" | bc -l) )) && CDN=1.0
  (( $(echo "$CDN < 0.05" | bc -l) )) && CDN=0.05

  CHN=$(echo "scale=3; $HN * 3" | bc)
  (( $(echo "$CHN > 1" | bc -l) )) && CHN=1.0

  # Thermal activity
  local THM
  THM=$(echo "scale=3; $DN * 0.5 + $WN * 0.3 + (1 - $VN) * 0.2" | bc)
  (( $(echo "$THM > 1" | bc -l) )) && THM=1.0

  # Seasonal bias
  local MONTH
  MONTH=$(date +%m)
  if (( MONTH < 3 || MONTH > 10 )); then
    THM=$(echo "$THM * 0.8" | bc)
    VN=$(echo "$VN * 0.9" | bc)
  fi

  echo "$CDN;$CHN;$THM;$VN"
}

# ------------ Safe update utility -----------------------
update_mcf() {
  local KEY="$1" VALUE="$2"
  $SED_CMD "s|<\[float64\]\[$KEY\].*|<[float64][$KEY][$VALUE]>|g" "$MCF"
}

# ------------ Apply updates -----------------------------
apply_weather() {
  local DIR WN VN HN DN TN CDN CHN THM
  DIR="$1"; WN="$2"; VN="$3"; HN="$4"; DN="$5"; TN="$6"; CDN="$7"; CHN="$8"; THM="$9"

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

# ------------ UTC Time Sync -----------------------------
sync_time() {
  local YEAR MON DAY HOUR_DEC
  YEAR=$(date -u +"%Y")
  MON=$(date -u +"%m")
  DAY=$(date -u +"%d")
  HOUR_DEC=$(echo "scale=6; $(date -u +%H) + ($(date -u +%M)/60)" | bc)

  $SED_CMD "s|<\[int32\]\[time_year\].*|<[int32][time_year][$YEAR]>|g" "$MCF"
  $SED_CMD "s|<\[int32\]\[time_month\].*|<[int32][time_month][$MON]>|g" "$MCF"
  $SED_CMD "s|<\[int32\]\[time_day\].*|<[int32][time_day][$DAY]>|g" "$MCF"
  $SED_CMD "s|<\[float64\]\[time_hours\].*|<[float64][time_hours][$HOUR_DEC]>|g" "$MCF"
}

# ------------ Main --------------------------------------
main() {
  local START END SYNC_TIME_FLAG

  if [[ "$1" && "$2" ]]; then
    START="$1"
    END="$2"
    SYNC_TIME_FLAG="$3"
  else
    echo "Start ICAO:"; read START
    echo "End ICAO:"; read END
    echo "Sync system UTC time? (y/n)"; read SYNC_TIME_FLAG
  fi

  echo -e "${BOLD}${BLUE}Fetching METARs for $START and $END...${RESET}"

  local M1 M2
  M1=$(fetch_metar "$START")
  M2=$(fetch_metar "$END")

  if [[ -z "$M1" || -z "$M2" ]]; then
    echo -e "${YELLOW}METAR fetch failed. Using clear weather.${RESET}"
    WN=0; VN=1; HN=1; DN=0; TN=0.1; CDN=0.05; CHN=1; THM=0.2; DIR=0
    apply_weather "$DIR" "$WN" "$VN" "$HN" "$DN" "$TN" "$CDN" "$CHN" "$THM"
    exit 0
  fi

  # Parse both METARs
  IFS=';' read D1 W1 V1N H1N C1N T1N <<< "$(parse_metar "$M1")"
  IFS=';' read D2 W2 V2N H2N C2N T2N <<< "$(parse_metar "$M2")"

  # Averages
  local DIR WN VN HN DN TN
  DIR=$(( (D1 + D2) / 2 ))
  WN=$(echo "scale=3; ($W1 + $W2)/2" | bc)
  VN=$(echo "scale=3; ($V1N + $V2N)/2" | bc)
  HN=$(echo "scale=3; ($H1N + $H2N)/2" | bc)
  DN=$(echo "scale=3; ($C1N + $C2N)/2" | bc)
  TN=$(echo "scale=3; ($T1N + $T2N)/2" | bc)

  # Compute derived parameters
  IFS=';' read CDN CHN THM VN <<< "$(compute_derived "$VN" "$HN" "$DN" "$WN" "$TN")"

  # Backup before writing
  cp "$MCF" "$MCF.bak"

  # Apply
  apply_weather "$DIR" "$WN" "$VN" "$HN" "$DN" "$TN" "$CDN" "$CHN" "$THM"

  # Sync time if needed
  if [[ "$SYNC_TIME_FLAG" =~ ^[Yy-]*sync.*$ ]]; then
    sync_time
  fi

  # Summary
  echo -e "\n${CYAN}--- Final Weather Summary ---${RESET}"
  echo "Wind Direction: $DIR°"
  echo "Wind Strength : $WN"
  echo "Visibility    : $VN"
  echo "Cloud Base    : $HN"
  echo "Cumulus Dens. : $DN"
  echo "Cirrus Height : $CHN"
  echo "Cirrus Dens.  : $CDN"
  echo "Turbulence    : $TN"
  echo "Thermals      : $THM"
  [[ "$SYNC_TIME_FLAG" =~ ^[Yy-]*sync.*$ ]] && echo "UTC Time Sync : enabled"
  echo -e "${CYAN}Weather successfully updated in Aerofly FS4.${RESET}\n"
}

main "$@"