#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Update Hikvision NVR channel names from CSV
# CSV columns:
#   1) channelId
#   2) ipAddress
#   3) name
#
# Example CSV line:
#   19,10.32.200.70,Z67
# ----------------------------

NVR_HOST="12.174.167.242"   # NVR IP:PORT
NVR_USER="admin"
NVR_PASS="Yqnhwc123="            # <-- change if needed

CAM_USER="admin"               # camera login stored in InputProxy (if required by your NVR)
CAM_PASS="Yqnhwc123="          # <-- from your example; change if needed

CSV_FILE="${1:-channels.csv}"
TIMEOUT=20
RETRIES=2
SLEEP_BETWEEN=1

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE"
  echo "Usage: $0 path/to/channels.csv"
  exit 1
fi

# Escape XML special chars (& < > " ')
xml_escape() {
  local s="${1-}"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&apos;}
  printf '%s' "$s"
}

ok=0
fail=0
line_no=0

# Read CSV (simple CSV: no embedded commas/quotes inside fields)
# If your names can contain commas, tell me and I’ll switch to a robust CSV parser.
while IFS=',' read -r channelId ipAddress name rest; do
  line_no=$((line_no+1))

  # Skip empty lines
  [[ -n "${channelId// /}" ]] || continue

  # Skip header row if present
  if [[ "$channelId" =~ ^[Cc]hannel[Ii]d$ ]]; then
    continue
  fi

  # Trim whitespace
  channelId="$(echo "$channelId" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  ipAddress="$(echo "$ipAddress" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  name="$(echo "${name}${rest:+,$rest}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"  # preserve commas if extra cols exist

  if [[ -z "$channelId" || -z "$ipAddress" || -z "$name" ]]; then
    echo "[SKIP] line $line_no: missing channelId/ipAddress/name"
    continue
  fi

  if ! [[ "$channelId" =~ ^[0-9]+$ ]]; then
    echo "[SKIP] line $line_no: invalid channelId '$channelId'"
    continue
  fi

  esc_name="$(xml_escape "$name")"
  esc_ip="$(xml_escape "$ipAddress")"
  esc_cam_user="$(xml_escape "$CAM_USER")"
  esc_cam_pass="$(xml_escape "$CAM_PASS")"

  url="http://${NVR_HOST}/ISAPI/ContentMgmt/InputProxy/channels/${channelId}"

  payload="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<InputProxyChannel xmlns=\"http://www.isapi.org/ver20/XMLSchema\" version=\"2.0\">
  <id>${channelId}</id>
  <name>${esc_name}</name>
  <sourceInputPortDescriptor>
    <proxyProtocol>IPCAM</proxyProtocol>
    <addressingFormatType>ipaddress</addressingFormatType>
    <ipAddress>${esc_ip}</ipAddress>
    <managePortNo>8000</managePortNo>
    <srcInputPort>1</srcInputPort>
    <userName>${esc_cam_user}</userName>
    <password>${esc_cam_pass}</password>
    <streamType>auto</streamType>
    <deviceID/>
  </sourceInputPortDescriptor>
</InputProxyChannel>"

  echo "Updating channelId=${channelId} ip=${ipAddress} name='${name}'"

  success=0
  for attempt in $(seq 1 "$RETRIES"); do
    # --anyauth will negotiate Digest/Basic automatically
    # -f makes curl fail on HTTP 4xx/5xx
    if curl -sS -f --anyauth -u "${NVR_USER}:${NVR_PASS}" \
        -m "${TIMEOUT}" \
        -H 'Accept: */*' \
        -H 'Content-Type: application/xml' \
        -X PUT \
        --data-binary "$payload" \
        "$url" >/dev/null; then
      success=1
      break
    fi
    sleep "$SLEEP_BETWEEN"
  done

  if [[ "$success" -eq 1 ]]; then
    echo "  [OK] channelId ${channelId} updated"
    ok=$((ok+1))
  else
    echo "  [FAIL] channelId ${channelId}"
    fail=$((fail+1))
  fi

done < "$CSV_FILE"

echo "Done. OK=${ok}, FAIL=${fail}"
