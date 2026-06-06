#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
SNAP_IP="12.104.88.214"          # NVR IP used for snapshots
META_IP="12.104.88.214"          # NVR IP used for InputProxy metadata (can be same as SNAP_IP)
USER="admin"
PASS="YQN1125-"

START_CAM=1
END_CAM=64
STREAM_SUFFIX=2                  # 1=main (x01), 2=sub (x02) -> 102, 202, ...
OUTDIR="snapshots_${SNAP_IP}"
TIMEOUT=15
RETRIES=3
SLEEP_BETWEEN=1

mkdir -p "$OUTDIR"

# Make safe filenames: keep letters/numbers/._- and replace everything else with _
sanitize() {
  # shellcheck disable=SC2001
  echo -n "$1" | tr -d '\r\n' | sed 's/[^A-Za-z0-9._-]/_/g' | sed 's/__\+/_/g' | sed 's/^_//; s/_$//'
}

# Extract first occurrence of a tag value (handles namespaces by just matching the literal tag)
xml_get_tag() {
  local tag="$1"
  # Pull content between <tag>...</tag> even if whitespace exists around it.
  # Works whether XML is pretty-printed or one-line.
  sed -n "s/.*<${tag}>\\([^<]*\\)<\\/${tag}>.*/\\1/p" | head -n 1
}

ok=0
fail=0

for cam in $(seq "$START_CAM" "$END_CAM"); do
  # Snapshot channel pattern: 1->102, 2->202, ... 43->4302
  ch=$((cam * 100 + STREAM_SUFFIX))

  # Metadata endpoint uses cam index directly: 1,2,3,... (per your example)
  meta_url="http://${META_IP}/ISAPI/ContentMgmt/InputProxy/channels/${cam}"
  snap_url="http://${SNAP_IP}/ISAPI/Streaming/channels/${ch}/picture"

  echo "CamIndex=${cam}  SnapshotChannel=${ch}"

  # --- Fetch metadata XML (name + ipAddress) ---
  xml=""
  if ! xml=$(curl -sS -f --anyauth -u "${USER}:${PASS}" -m "${TIMEOUT}" "${meta_url}"); then
    echo "  [WARN] Metadata fetch failed for cam ${cam}. Using fallback filename."
    cam_name="cam${cam}"
    cam_ip="unknownip"
  else
    cam_name=$(printf '%s' "$xml" | tr -d '\n' | xml_get_tag "name" || true)
    cam_ip=$(printf '%s' "$xml" | tr -d '\n' | xml_get_tag "ipAddress" || true)

    # Fallbacks if tags missing
    [[ -n "${cam_name}" ]] || cam_name="cam${cam}"
    [[ -n "${cam_ip}" ]]   || cam_ip="unknownip"
  fi

  safe_name="$(sanitize "$cam_name")"
  safe_ip="$(sanitize "$cam_ip")"

  outfile="${OUTDIR}/${safe_name}_${safe_ip}_ch${ch}.jpg"

  echo "  Saving -> ${outfile}"

  # --- Fetch snapshot with retries ---
  success=0
  for attempt in $(seq 1 "$RETRIES"); do
    if curl -sS -f --anyauth -u "${USER}:${PASS}" \
        -m "${TIMEOUT}" --connect-timeout 5 \
        -o "${outfile}" "${snap_url}"; then

      # Validate it is a JPEG, not an HTML error page
      if file -b --mime-type "${outfile}" | grep -qiE 'image/jpeg|image/jpg'; then
        success=1
        break
      else
        echo "  [WARN] Not a JPEG (got $(file -b --mime-type "${outfile}")), retrying..."
        rm -f "${outfile}"
      fi
    else
      rm -f "${outfile}" || true
    fi
    sleep "${SLEEP_BETWEEN}"
  done

  if [[ "$success" -eq 1 ]]; then
    echo "  [OK] ${safe_name} ${safe_ip} (ch ${ch})"
    ok=$((ok+1))
  else
    echo "  [FAIL] camIndex ${cam} (ch ${ch})"
    fail=$((fail+1))
  fi
done

echo "Done. OK=${ok}, FAIL=${fail}. Images saved in: ${OUTDIR}"
