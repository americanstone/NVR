#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
NVR_LIST="${1:-nvr_list.csv}"   # Usage: ./NVR_IPs.sh [nvr_list.csv]
OUTFILE="${2:-all_camera_ips.txt}"  # Single output file for all NVRs

START_CAM=1
# END_CAM is read per-NVR from the last column of nvr_list.csv

TMPFILE="$(mktemp)"   # Accumulates all IPs across all NVRs
trap 'rm -f "$TMPFILE"' EXIT

# Extract first occurrence of a tag value
xml_get_tag() {
  local tag="$1"
  sed -n "s/.*<${tag}>\\([^<]*\\)<\\/${tag}>.*/\\1/p" | head -n 1
}

# --- Validate NVR list file ---
if [[ ! -f "$NVR_LIST" ]]; then
  echo "ERROR: NVR list file not found: ${NVR_LIST}"
  echo ""
  echo "Create a CSV file with this format (no header row):"
  echo "  ip,port,username,password,end_cam"
  echo ""
  echo "Example nvr_list.csv:"
  echo "  12.104.88.214,80,admin,YQN1125-,64"
  echo "  192.168.1.100,8001,admin,Password123,32"
  exit 1
fi

nvr_count=0

# --- Iterate over each NVR ---
while IFS=',' read -r NVR_IP NVR_PORT USER PASS END_CAM || [[ -n "$NVR_IP" ]]; do

  # Skip empty lines and comment lines
  [[ -z "$NVR_IP" ]] && continue
  [[ "$NVR_IP" =~ ^[[:space:]]*# ]] && continue

  # Strip whitespace
  NVR_IP=$(echo "$NVR_IP"     | tr -d '[:space:]')
  NVR_PORT=$(echo "$NVR_PORT" | tr -d '[:space:]')
  USER=$(echo "$USER"         | tr -d '[:space:]')
  PASS=$(echo "$PASS"         | tr -d '[:space:]')
  END_CAM=$(echo "$END_CAM"   | tr -d '[:space:]')

  # Fallback if END_CAM missing
  END_CAM="${END_CAM:-64}"

  # Build host — omit port if empty or 80
  if [[ -z "$NVR_PORT" || "$NVR_PORT" == "80" ]]; then
    HOST="${NVR_IP}"
  else
    HOST="${NVR_IP}:${NVR_PORT}"
  fi

  nvr_count=$((nvr_count + 1))

  echo ""
  echo "========================================"
  echo "NVR #${nvr_count}: ${HOST}  (user: ${USER}, cams: ${START_CAM}-${END_CAM})"
  echo "========================================"

  for cam in $(seq "$START_CAM" "$END_CAM"); do
    url="http://${HOST}/ISAPI/ContentMgmt/InputProxy/channels/${cam}"

    if xml=$(curl -sS --anyauth -u "${USER}:${PASS}" -m 10 --connect-timeout 5 "$url" 2>/dev/null); then
      ip=$(printf '%s' "$xml" | tr -d '\n' | xml_get_tag "ipAddress" || true)
      if [[ -n "$ip" ]]; then
        echo "$ip" >> "$TMPFILE"
        echo "  Cam ${cam}: $ip"
      fi
    else
      echo "  Cam ${cam}: metadata fetch failed"
    fi
  done

  echo ""
  echo "  Done ✅  NVR ${HOST} scanned."

done < "$NVR_LIST"

# Sort all collected IPs numerically (by IP octets) and deduplicate into one file
sort -u -t '.' -k1,1n -k2,2n -k3,3n -k4,4n "$TMPFILE" > "$OUTFILE"

count=$(wc -l < "$OUTFILE")
echo ""
echo "========================================"
echo "ALL DONE. NVRs processed: ${nvr_count}"
echo "Total unique camera IPs: ${count}"
echo "Saved to: ${OUTFILE}"
echo "========================================"