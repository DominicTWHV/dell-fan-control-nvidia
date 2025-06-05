#!/bin/bash

for cmd in ipmitool nvidia-smi sensors bc awk; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

function apply_automatic_fan_control () {
  ipmitool -I $IDRAC_CONNECTION_STRING raw 0x30 0x30 0x01 0x01 > /dev/null
  FAN_CONTROL_CURRENT_STATE=$FAN_CONTROL_STATE_AUTOMATIC
  echo "Fan control set to automatic."
}

function apply_manual_fan_control () {
  ipmitool -I $IDRAC_CONNECTION_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  FAN_CONTROL_CURRENT_STATE=$FAN_CONTROL_STATE_MANUAL
  echo "Fan control set to manual."
}

function apply_fan_speed () {
    local HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $1)

    ipmitool -I $IDRAC_CONNECTION_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
    FAN_CONTROL_MANUAL_PERCENTAGE=$1
    STEPS_SINCE_LAST_FAN_CHANGED=0
    echo "Fan speed set to $1% ($HEXADECIMAL_FAN_SPEED)."
}

function retrieve_temperatures () {
  #obtain gpu temp from nvidia-smi, select highest
  GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
  #obtain cpu temp from lm-sensors, select highest
  CPU_TEMP=$(sensors | grep -E 'Core [0-9]+' | awk '{print $3}' | cut -d'+' -f2 | cut -d'.' -f1 | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
  #select highest temp between cpu and gpu
  if [ $CPU_TEMP -gt $GPU_TEMP ]; then
    HIGHEST_TEMP=$CPU_TEMP
    TEMP_SOURCE="CPU"
  else
    HIGHEST_TEMP=$GPU_TEMP
    TEMP_SOURCE="GPU"
  fi
  echo "Current Highest GPU Temp: $GPU_TEMP °C, Highest CPU Temp: $CPU_TEMP °C, Using $TEMP_SOURCE Temp: $HIGHEST_TEMP °C"
}

function gracefull_exit () {
  apply_automatic_fan_control
  echo "Script stopped, automatic fan speed restored for safety."
  exit 0
}

function emergency_shutdown () {
  echo "$(date): Emergency shutdown triggered due to $TEMP_SOURCE temp ${HIGHEST_TEMP}°C" >> /var/log/fan_control.log
  echo "Shutting down the system immediately!"
  sync
  shutdown -h now
}

#trap signal
trap 'gracefull_exit' SIGQUIT SIGKILL SIGTERM EXIT

# --- User Configuration ---
IDRAC_CONNECTION_STRING="lanplus -H <YOUR IDRAC IP HERE> -U <YOUR USERNAME HERE> -P <YOUR PASSWORD HERE>"

# Fan Control States (do not modify if you don't know what these are)
FAN_CONTROL_STATE_MANUAL="manual"
FAN_CONTROL_STATE_AUTOMATIC="automatic"
FAN_CONTROL_CURRENT_STATE=$FAN_CONTROL_STATE_AUTOMATIC
FAN_CONTROL_MANUAL_PERCENTAGE=0

# Fan Speed Variables
MIN_TEMP=65        # Temperature in Celsius to start increasing fan speed
MAX_TEMP=90        # Temperature in Celsius at which fan speed reaches maximum
MIN_FAN=20         # Minimum fan speed percentage
MAX_FAN=100        # Maximum fan speed percentage
INTERVAL=3         # Seconds, the interval between temp checks and adjustment

# Emergency Termination
EMRG_TERM_STATE="enabled" # or "disabled". Enabled by default to prevent hw dmg
EMRG_TERM_TEMP=100 # in deg celsius, when reached, system will shut down immediately if termination is enabled

# --- End of User Configuration ---
#do not touch below this point unless you know what you are doing

while true; do
  sleep $INTERVAL &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures

  if [[ "$EMRG_TERM_STATE" == "enabled" && $HIGHEST_TEMP -ge $EMRG_TERM_TEMP ]]; then
    emergency_shutdown
  fi

  if (($HIGHEST_TEMP >= $MIN_TEMP)); then
      if [[ "$FAN_CONTROL_STATE_AUTOMATIC" == "$FAN_CONTROL_CURRENT_STATE" ]]; then
        echo "$TEMP_SOURCE temperature is getting high. Enabling manual fan control."
        apply_manual_fan_control
      fi

      if (($HIGHEST_TEMP <= $MAX_TEMP)); then
          TEMP_RATIO=$(echo "scale=4; ($HIGHEST_TEMP - $MIN_TEMP) / ($MAX_TEMP - $MIN_TEMP)" | bc)
          FAN_SPEED=$(echo "$MIN_FAN + ($MAX_FAN - $MIN_FAN) * ($TEMP_RATIO ^ 2)" | bc | awk '{printf("%d\n", $1 + 0.5)}')

          #ensure fan speed is sane
          if (($FAN_SPEED < $MIN_FAN)); then
              FAN_SPEED=$MIN_FAN
          elif (($FAN_SPEED > $MAX_FAN)); then
              FAN_SPEED=$MAX_FAN
          fi
      else
          FAN_SPEED=$MAX_FAN
      fi

      if [[ "$FAN_CONTROL_MANUAL_PERCENTAGE" != "$FAN_SPEED" ]]; then
          echo "Setting fan speed to ${FAN_SPEED}% based on non-linear algorithm for $TEMP_SOURCE temperature."
          apply_fan_speed $FAN_SPEED
      fi

  elif [[ "$FAN_CONTROL_STATE_MANUAL" == "$FAN_CONTROL_CURRENT_STATE" ]]; then
    echo "$TEMP_SOURCE temperature is calming down. Returning to automatic fan control."
    apply_automatic_fan_control
    FAN_CONTROL_MANUAL_PERCENTAGE=0
  fi

  wait $SLEEP_PROCESS_PID
done
