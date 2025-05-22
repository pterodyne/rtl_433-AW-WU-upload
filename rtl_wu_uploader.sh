#!/bin/bash

# --- Configuration ---
WU_STATION_ID="Wunderground Station ID"
WU_STATION_KEY="Wunderground Device Key"
RTL_FREQ="915M"
SOFTWARE_TYPE="rtl433-bash-json-v1.3" # Version bump

# --- STATION SPECIFIC CONFIGURATION ---
STATION_ALTITUDE_METERS=2760
MSLP_CALIBRATED_EXPONENT="5.549"

# --- State Variable for Outdoor Temperature ---
# This variable will store the last known outdoor temperature from WH24
# It needs to be accessible and updatable across loop iterations.
LATEST_OUTDOOR_TEMP_C=""

# Check for required commands
# ... (same as before) ...
for cmd in rtl_433 jq bc curl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it."
        exit 1
    fi
done
# ... (rest of initial checks) ...
if [[ -z "$WU_STATION_KEY" ]]; then echo "ERROR: WU_STATION_KEY empty."; exit 1; fi
if [[ -z "$WU_STATION_ID" ]]; then echo "ERROR: WU_STATION_ID empty."; exit 1; fi
if ! [[ "$STATION_ALTITUDE_METERS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "ERROR: STATION_ALTITUDE_METERS invalid."; exit 1; fi


echo "Starting rtl_433 (JSON) data logger and Weather Underground uploader..."
echo "Station ID: $WU_STATION_ID, Key: ${WU_STATION_KEY:0:4}********"
echo "Configured Altitude: ${STATION_ALTITUDE_METERS}m, MSLP Exponent: $MSLP_CALIBRATED_EXPONENT"
echo "Listening on frequency: $RTL_FREQ"
echo "Press Ctrl+C to stop."
echo "-----------------------------------------------------"

# Use Process Substitution to potentially avoid subshell for the while loop,
# allowing LATEST_OUTDOOR_TEMP_C to be updated across iterations.
while IFS= read -r json_line; do
    model=$(echo "$json_line" | jq -r '.model // empty')

    if [[ -z "$model" ]]; then
        continue
    fi

    declare -A wu_params

    echo "-----------------------------------------------------"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing data for model: $model"

    if [[ "$model" == "Fineoffset-WH24" ]]; then
        temp_c_wh24=$(echo "$json_line" | jq -r '.temperature_C // empty')
        # ... (extract other WH24 fields) ...
        humidity_wh24=$(echo "$json_line" | jq -r '.humidity // empty')
        wind_dir_deg=$(echo "$json_line" | jq -r '.wind_dir_deg // empty')
        wind_avg_ms=$(echo "$json_line" | jq -r '.wind_avg_m_s // empty')
        wind_max_ms=$(echo "$json_line" | jq -r '.wind_max_m_s // empty')
        rain_mm=$(echo "$json_line" | jq -r '.rain_mm // empty')
        uvi=$(echo "$json_line" | jq -r '.uvi // empty')
        light_lux=$(echo "$json_line" | jq -r '.light_lux // empty')


        if [[ -n "$temp_c_wh24" ]]; then
            wu_params["tempf"]=$(echo "scale=2; ($temp_c_wh24 * 9 / 5) + 32" | bc -l)
            # Update the global variable with the latest outdoor temperature
            LATEST_OUTDOOR_TEMP_C="$temp_c_wh24"
            echo "INFO: Updated LATEST_OUTDOOR_TEMP_C to: $LATEST_OUTDOOR_TEMP_C C"
        fi
        # ... (populate other wu_params for WH24) ...
        if [[ -n "$humidity_wh24" ]]; then wu_params["humidity"]="$humidity_wh24"; fi
        if [[ -n "$wind_dir_deg" ]]; then wu_params["winddir"]="$wind_dir_deg"; fi
        if [[ -n "$wind_avg_ms" ]]; then wu_params["windspeedmph"]=$(echo "scale=2; $wind_avg_ms * 2.23694" | bc -l); fi
        if [[ -n "$wind_max_ms" ]]; then wu_params["windgustmph"]=$(echo "scale=2; $wind_max_ms * 2.23694" | bc -l); fi
        if [[ -n "$rain_mm" ]]; then wu_params["dailyrainin"]=$(echo "scale=2; $rain_mm / 25.4" | bc -l); fi
        if [[ -n "$uvi" ]]; then wu_params["UV"]="$uvi"; fi
        if [[ -n "$light_lux" ]]; then wu_params["solarradiation"]=$(echo "scale=2; $light_lux / 126.7" | bc -l); fi


    elif [[ "$model" == "Fineoffset-WH25" ]]; then
        temp_c_wh25=$(echo "$json_line" | jq -r '.temperature_C // empty') # Indoor temp
        humidity_wh25=$(echo "$json_line" | jq -r '.humidity // empty')   # Indoor humidity
        abs_pressure_hpa=$(echo "$json_line" | jq -r '.pressure_hPa // empty')

        if [[ -n "$temp_c_wh25" ]]; then
            wu_params["indoortempf"]=$(echo "scale=2; ($temp_c_wh25 * 9 / 5) + 32" | bc -l)
        fi
        if [[ -n "$humidity_wh25" ]]; then
            wu_params["indoorhumidity"]="$humidity_wh25"
        fi

        # For MSLP calculation, use LATEST_OUTDOOR_TEMP_C (from WH24)
        if [[ -n "$abs_pressure_hpa" && -n "$LATEST_OUTDOOR_TEMP_C" ]]; then
            temp_for_mslp_calc_c="$LATEST_OUTDOOR_TEMP_C" # Use the stored outdoor temp
            echo "DEBUG: MSLP Calc Input -> AbsPress: $abs_pressure_hpa hPa, Outdoor Temp: $temp_for_mslp_calc_c C, Alt: $STATION_ALTITUDE_METERS m, Exp: $MSLP_CALIBRATED_EXPONENT"
            
            term1=$(echo "scale=10; $temp_for_mslp_calc_c + (0.0065 * $STATION_ALTITUDE_METERS) + 273.15" | bc -l)
            denom=$(echo "scale=10; $temp_for_mslp_calc_c + 273.15" | bc -l)
            
            if (( $(echo "$denom == 0" | bc -l) )); then
                 echo "ERROR: Denom zero in MSLP calc. Skipping pressure."
            else
                base_val=$(echo "scale=10; $term1 / $denom" | bc -l)
                if (( $(echo "$base_val <= 0" | bc -l) )); then
                    echo "ERROR: Base val non-positive in MSLP calc. Skipping pressure."
                else
                    mslp_hpa=$(echo "scale=4; e($MSLP_CALIBRATED_EXPONENT * l($base_val)) * $abs_pressure_hpa" | bc -l)
                    echo "DEBUG: Calculated MSLP (hPa): $mslp_hpa"
                    if [[ -n "$mslp_hpa" ]]; then
                        wu_params["baromin"]=$(echo "scale=4; $mslp_hpa * 0.02953" | bc -l)
                        echo "DEBUG: baromin (inHg): ${wu_params["baromin"]}"
                    fi
                fi
            fi
        elif [[ -n "$abs_pressure_hpa" ]]; then
             echo "WARN: Abs press ($abs_pressure_hpa hPa) present, but LATEST_OUTDOOR_TEMP_C ('$LATEST_OUTDOOR_TEMP_C') is not set. Cannot calculate MSLP yet."
        fi
    else
        echo "INFO: Unhandled model: $model. Skipping."
    fi

    if [[ ${#wu_params[@]} -eq 0 ]]; then
        echo "No processable params for model [$model]. Skipping WU upload."
        continue
    fi

    # ... (URL construction and curl upload - same as before) ...
    UPLOAD_URL="https://weatherstation.wunderground.com/weatherstation/updateweatherstation.php?"
    UPLOAD_URL+="ID=${WU_STATION_ID}"
    UPLOAD_URL+="&PASSWORD=${WU_STATION_KEY}"
    UPLOAD_URL+="&dateutc=now"
    UPLOAD_URL+="&action=updateraw"
    UPLOAD_URL+="&softwaretype=${SOFTWARE_TYPE}"
    param_string=""
    for key in "${!wu_params[@]}"; do
        value_encoded=$(echo -n "${wu_params[$key]}" | sed 's/%/%25/g; s/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/\&/%26/g; s/'"'"'/%27/g; s/(/%28/g; s/)/%29/g; s/\*/%2a/g; s/+/%2b/g; s/,/%2c/g; s/-/%2d/g; s/\./%2e/g; s/\//%2f/g; s/:/%3a/g; s/;/%3b/g; s/</%3c/g; s/=/%3d/g; s/>/%3e/g; s/?/%3f/g; s/@/%40/g; s/\[/%5b/g; s/\\/%5c/g; s/\]/%5d/g; s/\^/%5e/g; s/_/%5f/g; s/`/%60/g; s/{/%7b/g; s/|/%7c/g; s/}/%7d/g; s/~/%7e/g')
        param_string+="&${key}=${value_encoded}"
    done
    UPLOAD_URL+="$param_string"
    MASKED_URL="${UPLOAD_URL/$WU_STATION_KEY/${WU_STATION_KEY:0:2}********}"
    echo "Uploading to WU: $MASKED_URL"
    response=$(curl --connect-timeout 10 -m 30 -s -k "$UPLOAD_URL")
    echo "WU Response: [$response]"
    if [[ "$response" == *"success"* ]]; then echo "Successfully uploaded data for $model."; else echo "WARN: Upload for $model may have failed. WU Response: [$response]"; fi

done < <(stdbuf -oL rtl_433 -f "$RTL_FREQ" -F json) # rtl_433 output fed via Process Substitution

echo "Script finished or interrupted."
# If LATEST_OUTDOOR_TEMP_C was updated in the loop, its final value can be seen here
# if the loop was not in a subshell.
echo "Final LATEST_OUTDOOR_TEMP_C was: $LATEST_OUTDOOR_TEMP_C"
