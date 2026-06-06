#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
NVR_LIST="${1:-nvr_list.csv}"   # CSV file: ip,port,username,password,end_cam
                                 # Usage: ./snap_isapi.sh [nvr_list.csv]

START_CAM=1
# END_CAM is read per-NVR from the last column of nvr_list.csv (default: 64)
STREAM_SUFFIX=2                  # 1=main (x01), 2=sub (x02) -> 102, 202, ...
TIMEOUT=15
RETRIES=3
SLEEP_BETWEEN=1

# Make safe filenames
sanitize() {
  echo -n "$1" | tr -d '\r\n' | sed 's/[^A-Za-z0-9._-]/_/g' | sed 's/__\+/_/g' | sed 's/^_//; s/_$//'
}

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
  echo "  208.222.23.136,8001,admin,Password123,64"
  echo "  192.168.1.100,80,admin,Pass456,32"
  echo "  10.0.0.50,8080,operator,Pass789,128"
  exit 1
fi

total_ok=0
total_fail=0
nvr_count=0

# --- Iterate over each NVR in the list ---
while IFS=',' read -r NVR_IP NVR_PORT USER PASS END_CAM || [[ -n "$NVR_IP" ]]; do

  # Skip empty lines and comment lines (starting with #)
  [[ -z "$NVR_IP" ]] && continue
  [[ "$NVR_IP" =~ ^[[:space:]]*# ]] && continue

  # Strip whitespace
  NVR_IP=$(echo "$NVR_IP"     | tr -d '[:space:]')
  NVR_PORT=$(echo "$NVR_PORT" | tr -d '[:space:]')
  USER=$(echo "$USER"         | tr -d '[:space:]')
  PASS=$(echo "$PASS"         | tr -d '[:space:]')
  END_CAM=$(echo "$END_CAM"   | tr -d '[:space:]')

  # Fallback if END_CAM is missing or not a number
  if [[ -z "$END_CAM" || ! "$END_CAM" =~ ^[0-9]+$ ]]; then
    echo "  [WARN] END_CAM missing or invalid for ${NVR_IP} — defaulting to 64"
    END_CAM=64
  fi

  HOST="${NVR_IP}:${NVR_PORT}"
  OUTDIR="snapshots_${NVR_IP}_${NVR_PORT}"
  mkdir -p "$OUTDIR"

  nvr_count=$((nvr_count + 1))
  ok=0
  fail=0

  echo ""
  echo "========================================"
  echo "NVR #${nvr_count}: ${HOST}  (user: ${USER}, cams: ${START_CAM}-${END_CAM})"
  echo "Output dir: ${OUTDIR}"
  echo "========================================"

  for cam in $(seq "$START_CAM" "$END_CAM"); do

    ch=$((cam * 100 + STREAM_SUFFIX))

    meta_url="http://${HOST}/ISAPI/ContentMgmt/InputProxy/channels/${cam}"
    snap_url="http://${HOST}/ISAPI/Streaming/channels/${ch}/picture"

    echo "  CamIndex=${cam}  SnapshotChannel=${ch}"

    # --- Fetch metadata ---
    xml=""
    if ! xml=$(curl -sS -f --anyauth -u "${USER}:${PASS}" -m "${TIMEOUT}" "${meta_url}" 2>/dev/null); then
      echo "    [WARN] Metadata fetch failed for cam ${cam}. Using fallback filename."
      cam_name="cam${cam}"
      cam_ip="unknownip"
    else
      cam_name=$(printf '%s' "$xml" | tr -d '\n' | xml_get_tag "name" || true)
      cam_ip=$(printf '%s'   "$xml" | tr -d '\n' | xml_get_tag "ipAddress" || true)
      [[ -n "${cam_name}" ]] || cam_name="cam${cam}"
      [[ -n "${cam_ip}" ]]   || cam_ip="unknownip"
    fi

    safe_name="$(sanitize "$cam_name")"
    safe_ip="$(sanitize "$cam_ip")"
    outfile="${OUTDIR}/${safe_name}_${safe_ip}_ch${ch}.jpg"

    echo "    Saving -> ${outfile}"

    # --- Fetch snapshot with retries ---
    success=0
    for attempt in $(seq 1 "$RETRIES"); do
      if curl -sS -f --anyauth -u "${USER}:${PASS}" \
          -m "${TIMEOUT}" --connect-timeout 5 \
          -o "${outfile}" "${snap_url}" 2>/dev/null; then

        if file -b --mime-type "${outfile}" | grep -qiE 'image/jpeg|image/jpg'; then
          success=1
          break
        else
          echo "    [WARN] Not a JPEG (got $(file -b --mime-type "${outfile}")), retrying... (attempt ${attempt}/${RETRIES})"
          rm -f "${outfile}"
        fi
      else
        rm -f "${outfile}" || true
      fi
      sleep "${SLEEP_BETWEEN}"
    done

    if [[ "$success" -eq 1 ]]; then
      echo "    [OK] ${safe_name} @ ${cam_ip} (ch ${ch})"
      ok=$((ok + 1))
    else
      echo "    [FAIL] camIndex ${cam} (ch ${ch})"
      fail=$((fail + 1))
    fi

  done

  echo ""
  echo "  NVR ${HOST} summary -> OK=${ok}, FAIL=${fail}. Images in: ${OUTDIR}"
  total_ok=$((total_ok + ok))
  total_fail=$((total_fail + fail))

done < "$NVR_LIST"

echo ""
echo "========================================"
echo "ALL DONE. NVRs processed: ${nvr_count}"
echo "Total OK=${total_ok}, Total FAIL=${total_fail}"
echo "========================================"