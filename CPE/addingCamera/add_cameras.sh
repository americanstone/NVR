#!/usr/bin/env bash
set -euo pipefail

# --- Usage ---
# ./add_cameras.sh cameras.csv NVR_IP NVR_PORT NVR_USER NVR_PASS
# Example:
# ./add_cameras.sh cameras.csv 192.168.1.100 8080 admin admin123
#
# CSV format (no header row):
#   id,channel_name,ip_address,username,password
#   1,Front Door,192.168.1.50,admin,pass123
#   2,Parking Lot,192.168.1.51,admin,pass456

# --- Defaults ---
DEFAULT_PROTOCOL="HIKVISION"
DEFAULT_PORT="8000"
TIMEOUT=15

# --- Validate arguments ---
if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <csv_file> <nvr_ip> <nvr_port> <nvr_user> <nvr_pass>"
  echo ""
  echo "CSV format (no header): id,channel_name,ip_address,username,password"
  echo "Example:"
  echo "  $0 cameras.csv 192.168.1.100 8080 admin admin123"
  exit 1
fi

CSV_FILE="$1"
NVR_IP="$2"
NVR_PORT="$3"
NVR_USER="$4"
NVR_PASS="$5"

NVR_HOST="${NVR_IP}:${NVR_PORT}"
LOG_FILE="add_cameras_$(date +%Y%m%d_%H%M%S).log"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: ${CSV_FILE}"
  exit 1
fi

# --- Logging ---
log() {
  local msg="[$(date '+%H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

ok=0
fail=0
count=0

log "Starting camera import to NVR: ${NVR_HOST}"
log "Log file: ${LOG_FILE}"
log "=========================================="

# --- Process each camera ---
while IFS=',' read -r CAM_ID CHAN_NAME CAM_IP CAM_USER CAM_PASS || [[ -n "$CAM_ID" ]]; do

  # Skip blank lines and comments
  [[ -z "$CAM_ID" ]] && continue
  [[ "$CAM_ID" =~ ^[[:space:]]*# ]] && continue

  # Strip whitespace
  CAM_ID=$(echo "$CAM_ID"       | tr -d '[:space:]')
  CHAN_NAME=$(echo "$CHAN_NAME"  | xargs)   # xargs trims leading/trailing spaces
  CAM_IP=$(echo "$CAM_IP"       | tr -d '[:space:]')
  CAM_USER=$(echo "$CAM_USER"   | tr -d '[:space:]')
  CAM_PASS=$(echo "$CAM_PASS"   | tr -d '[:space:]')

  count=$((count + 1))
  log ""
  log "--- Camera #${count} | Channel ${CAM_ID}: ${CHAN_NAME} | IP: ${CAM_IP} ---"

  # -------------------------------------------------------
  # STEP 1: Add the IP camera to the NVR channel
  # POST /ISAPI/ContentMgmt/InputProxy/channels
  # -------------------------------------------------------
  ADD_URL="http://${NVR_HOST}/ISAPI/ContentMgmt/InputProxy/channels"

  ADD_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<InputProxyChannel version=\"2.0\" xmlns=\"http://www.isapi.org/ver20/XMLSchema\">
  <id>${CAM_ID}</id>
  <sourceInputPortDescriptor>
    <adminProtocol>${DEFAULT_PROTOCOL}</adminProtocol>
    <addressingFormatType>ipaddress</addressingFormatType>
    <ipAddress>${CAM_IP}</ipAddress>
    <managePortNo>${DEFAULT_PORT}</managePortNo>
    <srcInputPort>1</srcInputPort>
    <userName>${CAM_USER}</userName>
    <password>${CAM_PASS}</password>
    <streamType>auto</streamType>
  </sourceInputPortDescriptor>
</InputProxyChannel>"

  ADD_RESP=$(curl -s --anyauth \
    -u "${NVR_USER}:${NVR_PASS}" \
    -X POST \
    -H "Content-Type: application/xml" \
    -m "$TIMEOUT" --connect-timeout 5 \
    -d "$ADD_XML" \
    "$ADD_URL" 2>/dev/null || true)

  # Check response for success/error
  if echo "$ADD_RESP" | grep -qi "statusCode>1<\|statusCode>200<\|OK"; then
    log "  [OK] Camera added to channel ${CAM_ID}"
  elif echo "$ADD_RESP" | grep -qi "statusCode"; then
    STATUS=$(echo "$ADD_RESP" | grep -o '<statusCode>[^<]*</statusCode>' | head -1)
    STATUS_STR=$(echo "$ADD_RESP" | grep -o '<statusString>[^<]*</statusString>' | head -1)
    log "  [WARN] Add response: ${STATUS} ${STATUS_STR}"
    log "         (Camera may already exist — proceeding to name update)"
  else
    log "  [WARN] Unexpected add response: ${ADD_RESP:0:200}"
    log "         Proceeding to name update anyway"
  fi

  # -------------------------------------------------------
  # STEP 2: Update the streaming channel name
  # Streaming channel ID = CAM_ID * 100 + 1  (e.g. ch1 -> 101, ch2 -> 201)
  # GET current config first, then PUT with updated name
  # -------------------------------------------------------
  # STREAM_CH=$(( CAM_ID * 100 + 1 ))
  # STREAM_URL="http://${NVR_HOST}/ISAPI/ContentMgmt/InputProxy/channels/${CAM_ID}"

  # log "  Updating channel name -> \"${CHAN_NAME}\" (streaming ch ${STREAM_CH})"

  # # GET current streaming channel config
  # GET_RESP=$(curl -s --anyauth \
  #   -u "${NVR_USER}:${NVR_PASS}" \
  #   -X GET \
  #   -m "$TIMEOUT" --connect-timeout 5 \
  #   "$STREAM_URL" 2>/dev/null || true)

  # if [[ -z "$GET_RESP" ]]; then
  #   log "  [FAIL] Could not retrieve streaming channel config for ch ${STREAM_CH}"
  #   fail=$((fail + 1))
  #   continue
  # fi

  # echo " GET_RESP ----"

  # echo "${GET_RESP}"

  # # Inject the new channel name into the retrieved XML
  # # Replace existing <channelName>...</channelName> or insert after <id>...</id>
  # if echo "$GET_RESP" | grep -q "<name>"; then
  #   NAME_XML=$(echo "$GET_RESP" | sed "s|<name>[^<]*</name>|<name>${CHAN_NAME}</name>|")
  # else
  #   NAME_XML=$(echo "$GET_RESP" | sed "s|</id>|</id>\n  <channelName>${CHAN_NAME}</channelName>|")
  # fi

  # # PUT updated config back
  # NAME_RESP=$(curl -s --anyauth \
  #   -u "${NVR_USER}:${NVR_PASS}" \
  #   -X PUT \
  #   -H "Content-Type: application/xml" \
  #   -m "$TIMEOUT" --connect-timeout 5 \
  #   -d "$NAME_XML" \
  #   "$STREAM_URL" 2>/dev/null || true)
  
  # echo "posting NAME_XML"

  # echo "$NAME_XML"

  # if echo "$NAME_RESP" | grep -qi "statusCode>1<\|statusCode>200<\|OK"; then
  #   log "  [OK] Channel name set to \"${CHAN_NAME}\""
  #   ok=$((ok + 1))
  # else
  #   STATUS=$(echo "$NAME_RESP" | grep -o '<statusCode>[^<]*</statusCode>' | head -1)
  #   STATUS_STR=$(echo "$NAME_RESP" | grep -o '<statusString>[^<]*</statusString>' | head -1)
  #   log "  [FAIL] Name update failed: ${STATUS} ${STATUS_STR}"
  #   fail=$((fail + 1))
  # fi

  # Brief pause between cameras to avoid overwhelming NVR
  sleep 1

done < "$CSV_FILE"

log ""
log "=========================================="
log "DONE. Total: ${count} | OK: ${ok} | FAIL: ${fail}"
log "Full log saved to: ${LOG_FILE}"
