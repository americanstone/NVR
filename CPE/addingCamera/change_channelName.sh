#!/usr/bin/env bash
set -euo pipefail

# --- Usage ---
# ./change_channelName.sh <csv_file> <nvr_ip> <nvr_port> <nvr_user> <nvr_pass>
#
# Example:
# ./change_channelName.sh cameras.csv 208.222.23.136 81 admin Yqnhwc123=
#
# CSV format (no header row):
#   id,channel_name,ip_address,username,password
#   53,NC14,10.32.102.162,admin,YQN1125-

# --- Defaults ---
DEFAULT_PROTOCOL="HIKVISION"
DEFAULT_MANAGE_PORT="8000"
TIMEOUT=15

# --- Validate arguments ---
if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <csv_file> <nvr_ip> <nvr_port> <nvr_user> <nvr_pass>"
  echo ""
  echo "CSV format (no header): id,channel_name,ip_address,username,password"
  echo ""
  echo "Example:"
  echo "  $0 cameras.csv 208.222.23.136 81 admin Yqnhwc123="
  exit 1
fi

CSV_FILE="$1"
NVR_IP="$2"
NVR_PORT="$3"
NVR_USER="$4"
NVR_PASS="$5"

NVR_HOST="${NVR_IP}:${NVR_PORT}"
LOG_FILE="change_channelName_$(date +%Y%m%d_%H%M%S).log"

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

log "Updating channel names on NVR: ${NVR_HOST}"
log "Log file: ${LOG_FILE}"
log "=========================================="

while IFS=',' read -r CAM_ID CHAN_NAME CAM_IP CAM_USER CAM_PASS || [[ -n "$CAM_ID" ]]; do

  # Skip blank lines and comments
  [[ -z "$CAM_ID" ]] && continue
  [[ "$CAM_ID" =~ ^[[:space:]]*# ]] && continue

  # Strip whitespace
  CAM_ID=$(echo "$CAM_ID"       | tr -d '[:space:]')
  CHAN_NAME=$(echo "$CHAN_NAME"  | xargs)
  CAM_IP=$(echo "$CAM_IP"       | tr -d '[:space:]')
  CAM_USER=$(echo "$CAM_USER"   | tr -d '[:space:]')
  CAM_PASS=$(echo "$CAM_PASS"   | tr -d '[:space:]')

  count=$((count + 1))
  log ""
  log "--- Channel ${CAM_ID}: \"${CHAN_NAME}\" | Camera IP: ${CAM_IP} ---"

  URL="http://${NVR_HOST}/ISAPI/ContentMgmt/InputProxy/channels/${CAM_ID}"

  PAYLOAD="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<InputProxyChannel xmlns=\"http://www.isapi.org/ver20/XMLSchema\" version=\"2.0\">
  <id>${CAM_ID}</id>
  <name>${CHAN_NAME}</name>
  <sourceInputPortDescriptor>
    <proxyProtocol>${DEFAULT_PROTOCOL}</proxyProtocol>
    <addressingFormatType>ipaddress</addressingFormatType>
    <ipAddress>${CAM_IP}</ipAddress>
    <managePortNo>${DEFAULT_MANAGE_PORT}</managePortNo>
    <srcInputPort>1</srcInputPort>
    <userName>${CAM_USER}</userName>
    <password>${CAM_PASS}</password>
    <streamType>auto</streamType>
    <deviceID/>
  </sourceInputPortDescriptor>
</InputProxyChannel>"

  RESP=$(curl -s \
    --anyauth \
    -u "${NVR_USER}:${NVR_PASS}" \
    -X PUT \
    -H "Content-Type: application/xml" \
    -H "Accept: */*" \
    -m "$TIMEOUT" --connect-timeout 5 \
    -d "$PAYLOAD" \
    "$URL" 2>/dev/null || true)

  # Parse response
  STATUS_CODE=$(echo "$RESP" | grep -o '<statusCode>[^<]*</statusCode>' | sed 's/<[^>]*>//g' || true)
  STATUS_STR=$(echo  "$RESP" | grep -o '<statusString>[^<]*</statusString>' | sed 's/<[^>]*>//g' || true)

  if echo "$RESP" | grep -qi "statusCode>1<\|statusCode>200<\|<statusString>OK"; then
    log "  [OK] Channel ${CAM_ID} renamed to \"${CHAN_NAME}\""
    ok=$((ok + 1))
  else
    log "  [FAIL] Channel ${CAM_ID} | code: ${STATUS_CODE:-?} | msg: ${STATUS_STR:-no response}"
    log "         URL: ${URL}"
    fail=$((fail + 1))
  fi

  sleep 5

done < "$CSV_FILE"

log ""
log "=========================================="
log "DONE. Total: ${count} | OK: ${ok} | FAIL: ${fail}"
log "Full log: ${LOG_FILE}"