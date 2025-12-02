#!/bin/bash

# =======================================================
# Aerofly FS4 Dynamic Weather Updater
# =======================================================
# Fetches and synthesizes realistic weather between two ICAOs
# and updates main.mcf with averaged flight conditions.
# Includes cirrus & thermal tuning, plus optional UTC sync.
# =======================================================

MCF="$HOME/Library/Application Support/Aerofly FS 4/main.mcf"

echo "Start ICAO:"
read START
echo "End ICAO:"
read END

echo "Sync system UTC time into Aerofly FS4? (y/n)"
read SYNC_TIME

fetch_metar() {
  curl -s "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${1}.TXT" | tail -n 1
}

safe_number() {
  if [[ -z "$1" ]] || ! [[ "$1" =~ ^[0-9.]+$ ]]; then
    echo "$2"
  else
    echo "$1"
  fi
}

parse_metar() {
  local METAR="$1"

  # 🟦 WIND
  local WIND=$(echo "$METAR" | grep -oE '[0-9]{3}[0-9]{2}(G[0-9]{2})?KT' | head -n1)
  local DIR=$(safe_number "$(echo "$WIND" | cut -c1-3)" 0)
  local SPD=$(safe_number "$(echo "$WIND" | cut -c4-5)" 0)
  local GUST=$(echo "$WIND" | grep -oE 'G[0-9]{2}' | tr -d G)
  [ -z "$GUST" ] && GUST="$SPD"
  GUST=$(safe_number "$GUST" "$SPD")

  # 🟦 VISIBILITY
  local VIS=$(echo "$METAR" | grep -oE ' [0-9]{4} ' | tr -d ' ')
  VIS=$(safe_number "$VIS" 9999)

  # 🟦 CLOUDS
  local CLOUD=$(echo "$METAR" | grep -oE '(FEW|SCT|BKN|OVC)[0-9]{3}' | head -n1)

  if [[ -z "$CLOUD" ]]; then
    CLOUD_CODE="CLR"
    CLOUD_HT_M=0
    CLOUD_DENS=0
  else
    CLOUD_CODE=$(echo "$CLOUD" | cut -c1-3)
    local HT_FT=$(echo "$CLOUD" | cut -c4-6)
    CLOUD_HT_M=$(echo "$HT_FT * 30.48" | bc | awk '{printf "%.0f",$0}')

    case $CLOUD_CODE in
      FEW) CLOUD_DENS=0.3 ;;
      SCT) CLOUD_DENS=0.5 ;;
      BKN) CLOUD_DENS=0.7 ;;
      OVC) CLOUD_DENS=1.0 ;;
      *) CLOUD_DENS=0.0 ;;
    esac
  fi

  # 🟦 NORMALIZATIONS
  local WN=$(echo "scale=3; $SPD/40" | bc)
  (( $(echo "$WN > 1" | bc -l) )) && WN=1.0

  local VN=$(echo "scale=3; $VIS/20000" | bc)
  (( $(echo "$VN > 1" | bc -l) )) && VN=1.0

  local HN=$(echo "scale=3; $CLOUD_HT_M/3000" | bc)
  (( $(echo "$HN > 1" | bc -l) )) && HN=1.0

  # 🟦 TURBULENCE (gust factor)
  local DIFF=$(echo "$GUST - $SPD" | bc)
  (( $(echo "$DIFF < 0" | bc -l) )) && DIFF=0
  local TBN=$(echo "scale=3; $DIFF/10" | bc)
  (( $(echo "$TBN > 1" | bc -l) )) && TBN=1.0
  (( $(echo "$TBN < 0.1" | bc -l) )) && TBN=0.1

  echo "$DIR;$WN;$VN;$HN;$CLOUD_DENS;$TBN"
}

# =======================================================
# FETCH & PARSE METARS
# =======================================================
M1=$(fetch_metar "$START")
M2=$(fetch_metar "$END")

echo "Start METAR: $M1"
echo "End METAR:   $M2"

V1=$(parse_metar "$M1")
V2=$(parse_metar "$M2")

IFS=';' read D1 W1 V1N H1N C1N T1N <<< "$V1"
IFS=';' read D2 W2 V2N H2N C2N T2N <<< "$V2"

# =======================================================
# AVERAGE VALUES
# =======================================================
DIR=$(( (D1 + D2) / 2 ))
WN=$(echo "scale=3; ($W1 + $W2)/2" | bc)
VN=$(echo "scale=3; ($V1N + $V2N)/2" | bc)
HN=$(echo "scale=3; ($H1N + $H2N)/2" | bc)
DN=$(echo "scale=3; ($C1N + $C2N)/2" | bc)
TN=$(echo "scale=3; ($T1N + $T2N)/2" | bc)

# =======================================================
# ADDITIONAL METEOROLOGICAL DERIVATIONS
# =======================================================

# Cirrus density (inversely correlated with visibility)
CDN=$(echo "scale=3; (1 - $VN) * 0.6 + ($DN * 0.4)" | bc)
(( $(echo "$CDN > 1" | bc -l) )) && CDN=1.0
(( $(echo "$CDN < 0.05" | bc -l) )) && CDN=0.05

# Cirrus height (about 3× cumulus height, capped)
CHN=$(echo "scale=3; $HN * 3" | bc)
(( $(echo "$CHN > 1" | bc -l) )) && CHN=1.0

# Thermal activity (based on sun heating potential, turbulence, and sky cover)
THM=$(echo "scale=3; $DN * 0.5 + $WN * 0.3 + (1 - $VN) * 0.2" | bc)
(( $(echo "$THM > 1" | bc -l) )) && THM=1.0

# =======================================================
# OPTIONAL UTC SYNC
# =======================================================
if [[ "$SYNC_TIME" =~ ^[Yy]$ ]]; then
  YEAR=$(date -u +"%Y")
  MON=$(date -u +"%m")
  DAY=$(date -u +"%d")
  HOUR_DEC=$(echo "scale=6; $(date -u +%H) + ($(date -u +%M)/60)" | bc)

  sed -i '' "s/<\[int32\]\[time_year\].*/<[int32][time_year][$YEAR]>/g" "$MCF"
  sed -i '' "s/<\[int32\]\[time_month\].*/<[int32][time_month][$MON]>/g" "$MCF"
  sed -i '' "s/<\[int32\]\[time_day\].*/<[int32][time_day][$DAY]>/g" "$MCF"
  sed -i '' "s/<\[float64\]\[time_hours\].*/<[float64][time_hours][$HOUR_DEC]>/g" "$MCF"
fi

# =======================================================
# WRITE WEATHER TO MCF
# =======================================================
# WIND
sed -i '' "s/<\[float64\]\[direction_in_degree\].*/<[float64][direction_in_degree][$DIR]>/g" "$MCF"
sed -i '' "s/<\[float64\]\[strength\].*/<[float64][strength][$WN]>/g" "$MCF"
sed -i '' "s/<\[float64\]\[turbulence\].*/<[float64][turbulence][$TN]>/g" "$MCF"

# VISIBILITY
sed -i '' "s/<\[float64\]\[visibility\].*/<[float64][visibility][$VN]>/g" "$MCF"

# CLOUDS
sed -i '' "s/<\[float64\]\[cumulus_density\].*/<[float64][cumulus_density][$DN]>/g" "$MCF"
sed -i '' "s/<\[float64\]\[cumulus_height\].*/<[float64][cumulus_height][$HN]>/g" "$MCF"
sed -i '' "s/<\[float64\]\[cirrus_density\].*/<[float64][cirrus_density][$CDN]>/g" "$MCF"
sed -i '' "s/<\[float64\]\[cirrus_height\].*/<[float64][cirrus_height][$CHN]>/g" "$MCF"

# THERMALS
sed -i '' "s/<\[float64\]\[thermal_activity\].*/<[float64][thermal_activity][$THM]>/g" "$MCF"

# =======================================================
# REPORT
# =======================================================
echo ""
echo "-------------------------------------------------------"
echo "   Aerofly FS4 WEATHER SUMMARY"
echo "-------------------------------------------------------"
echo "Wind Dir:  $DIR°"
echo "Wind Str:  $WN"
echo "Visib:     $VN"
echo "Cloud H:   $HN"
echo "Cumulus D: $DN"
echo "Cirrus H:  $CHN"
echo "Cirrus D:  $CDN"
echo "Turb:      $TN"
echo "Thermal:   $THM"
[[ "$SYNC_TIME" =~ ^[Yy]$ ]] && echo "Time UTC:  ${YEAR}-${MON}-${DAY} @ ${HOUR_DEC}h"
echo "-------------------------------------------------------"
echo "Weather data updated successfully!"