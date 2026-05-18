#!/usr/bin/env python3
"""
Query one or more Hikvision NVRs via ISAPI and export all channels to CSV.

Usage:
    python3 scripts/get_devices.py <warehouse-dir>

    <warehouse-dir> must contain a .env file. NVRs are configured with indexed
    variables (NVR_NAME_0, NVR_HOST_0, ...). The output CSV is written to
    <warehouse-dir>/<WAREHOUSE_NAME>_NVRs_<TIMESTAMP>.csv.

Example:
    python3 scripts/get_devices.py poc
    python3 scripts/get_devices.py warehouse-a

Columns: nvr_name, channel_id, channel_name, ip_address, mac_address, online, detect_result

MAC address is fetched from each camera's own /ISAPI/System/Network/interfaces endpoint.
If a camera is unreachable or uses different credentials, mac_address will be blank.
"""

import argparse
import csv
import re
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import requests
from requests.auth import HTTPDigestAuth

NS = "http://www.isapi.org/ver20/XMLSchema"


@dataclass
class NVRConfig:
    name: str
    host: str
    port: int
    user: str
    password: str
    cam_user: str  # global default camera credentials
    cam_pass: str
    cam_overrides: dict = field(default_factory=dict)  # {channel_id: (user, pass)}


def load_env(warehouse_dir: Path) -> tuple[str, list[NVRConfig], int]:
    """Returns (warehouse_name, nvr_configs, timeout)."""
    env_file = warehouse_dir / ".env"
    if not env_file.exists():
        print(f"ERROR: {env_file} not found.", file=sys.stderr)
        sys.exit(1)

    try:
        from dotenv import dotenv_values
        values = dotenv_values(env_file)
    except ImportError:
        values = {}
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            values[k.strip()] = v.strip()

    warehouse_name = values.get("WAREHOUSE_NAME", "")
    if not warehouse_name:
        print(f"ERROR: WAREHOUSE_NAME must be set in {env_file}", file=sys.stderr)
        sys.exit(1)

    timeout = int(values.get("TIMEOUT", "5"))

    # Global camera credential fallbacks
    global_cam_user = values.get("CAM_USER", "")
    global_cam_pass = values.get("CAM_PASS", "")

    nvrs: list[NVRConfig] = []
    i = 0
    while True:
        host = values.get(f"NVR_HOST_{i}", "")
        if not host:
            break
        name = values.get(f"NVR_NAME_{i}", "")
        port = int(values.get(f"NVR_PORT_{i}", "80"))
        user = values.get(f"NVR_USER_{i}", "admin")
        password = values.get(f"NVR_PASS_{i}", "")
        # Per-camera credential overrides: CAM_USER_{nvr_index}_{channel_id}
        cam_overrides = {}
        for key, val in values.items():
            m = re.match(rf"^CAM_USER_{i}_(\w+)$", key)
            if m and val:
                channel_id = m.group(1)
                cam_pass_override = values.get(f"CAM_PASS_{i}_{channel_id}", "")
                cam_overrides[channel_id] = (val, cam_pass_override)

        if not name:
            print(f"ERROR: NVR_NAME_{i} must be set in {env_file}", file=sys.stderr)
            sys.exit(1)
        if not password:
            print(f"ERROR: NVR_PASS_{i} must be set in {env_file}", file=sys.stderr)
            sys.exit(1)

        nvrs.append(NVRConfig(name=name, host=host, port=port, user=user, password=password,
                              cam_user=global_cam_user, cam_pass=global_cam_pass,
                              cam_overrides=cam_overrides))
        i += 1

    if not nvrs:
        print(f"ERROR: No NVRs configured in {env_file}. Add NVR_HOST_0, NVR_NAME_0, etc.", file=sys.stderr)
        sys.exit(1)

    return warehouse_name, nvrs, timeout


def nvr_get(path: str, nvr: NVRConfig, timeout: int) -> ET.Element:
    url = f"http://{nvr.host}:{nvr.port}{path}"
    r = requests.get(url, auth=HTTPDigestAuth(nvr.user, nvr.password), timeout=timeout)
    r.raise_for_status()
    return ET.fromstring(r.text)


def cam_get_mac(ip: str, cam_user: str, cam_pass: str, timeout: int) -> str:
    try:
        url = f"http://{ip}/ISAPI/System/Network/interfaces"
        r = requests.get(url, auth=HTTPDigestAuth(cam_user, cam_pass), timeout=timeout)
        r.raise_for_status()
        root = ET.fromstring(r.text)
        for el in root.iter():
            if el.tag.split("}")[-1] == "MACAddress":
                mac = (el.text or "").strip()
                if mac:
                    return mac
        print(f"    [WARN] {ip}: MACAddress not found in response", file=sys.stderr)
    except requests.exceptions.ConnectionError as e:
        print(f"    [WARN] {ip}: connection failed — {e}", file=sys.stderr)
    except requests.exceptions.Timeout:
        print(f"    [WARN] {ip}: request timed out", file=sys.stderr)
    except requests.exceptions.HTTPError as e:
        print(f"    [WARN] {ip}: HTTP {e.response.status_code} — {e}", file=sys.stderr)
    except Exception as e:
        print(f"    [WARN] {ip}: {e}", file=sys.stderr)
    return ""


def find(element: ET.Element, tag: str) -> str:
    el = element.find(f"{{{NS}}}{tag}")
    if el is None:
        el = element.find(tag)
    return (el.text or "").strip() if el is not None else ""


def get_channels(nvr: NVRConfig, timeout: int) -> list[dict]:
    root = nvr_get("/ISAPI/ContentMgmt/InputProxy/channels", nvr, timeout)
    channels = []
    for ch in root.iter(f"{{{NS}}}InputProxyChannel"):
        ch_id = find(ch, "id")
        name = find(ch, "name")
        desc = ch.find(f"{{{NS}}}sourceInputPortDescriptor")
        if desc is None:
            desc = ch.find("sourceInputPortDescriptor")
        ip = ""
        if desc is not None:
            ip = find(desc, "ipAddress") or find(desc, "hostName")
        channels.append({"id": ch_id, "name": name, "ip": ip})
    return channels


def get_statuses(nvr: NVRConfig, timeout: int) -> dict[str, dict]:
    try:
        root = nvr_get("/ISAPI/ContentMgmt/InputProxy/channels/status", nvr, timeout)
    except Exception as e:
        print(f"  [{nvr.name}] WARN: failed to fetch channel statuses — {e}", file=sys.stderr)
        return {}
    statuses = {}
    for st in root.iter(f"{{{NS}}}InputProxyChannelStatus"):
        ch_id = find(st, "id")
        statuses[ch_id] = {
            "online": find(st, "online"),
            "detect_result": find(st, "chanDetectResult"),
        }
    return statuses


def query_nvr(nvr: NVRConfig, timeout: int) -> list[dict]:
    print(f"  [{nvr.name}] Querying {nvr.host} ...")
    channels = get_channels(nvr, timeout)
    print(f"  [{nvr.name}] Found {len(channels)} channel(s). Fetching statuses ...")
    statuses = get_statuses(nvr, timeout)

    mac_map: dict[str, str] = {}
    has_any_creds = bool(nvr.cam_user and nvr.cam_pass) or bool(nvr.cam_overrides)
    if not has_any_creds:
        print(f"  [{nvr.name}] No camera credentials — skipping MAC address fetch.")
    else:
        print(f"  [{nvr.name}] Fetching MAC addresses (parallel) ...")
        with ThreadPoolExecutor(max_workers=16) as pool:
            futures = {}
            for ch in channels:
                if not ch["ip"]:
                    continue
                cam_user, cam_pass = nvr.cam_overrides.get(ch["id"], (nvr.cam_user, nvr.cam_pass))
                if cam_user and cam_pass:
                    futures[pool.submit(cam_get_mac, ch["ip"], cam_user, cam_pass, timeout)] = ch["id"]
            for future in as_completed(futures):
                mac_map[futures[future]] = future.result()

    rows = []
    for ch in channels:
        ch_id = ch["id"]
        status = statuses.get(ch_id, {})
        rows.append({
            "nvr_name": nvr.name,
            "nvr_ip": nvr.host,
            "channel_id": ch_id,
            "channel_name": ch["name"],
            "ip_address": ch["ip"],
            "mac_address": mac_map.get(ch_id, ""),
            "online": status.get("online", ""),
            "detect_result": status.get("detect_result", ""),
        })

    rows.sort(key=lambda r: int(r["channel_id"]) if r["channel_id"].isdigit() else 0)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Export NVR channel list to CSV.")
    parser.add_argument(
        "warehouse_dir",
        help="Warehouse directory containing .env (e.g. poc, warehouse-a). Output CSV is written there.",
    )
    args = parser.parse_args()

    warehouse_dir = Path(args.warehouse_dir).resolve()
    if not warehouse_dir.is_dir():
        print(f"ERROR: Directory not found: {warehouse_dir}", file=sys.stderr)
        sys.exit(1)

    warehouse_name, nvrs, timeout = load_env(warehouse_dir)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = warehouse_dir / f"{warehouse_name}_NVRs_{timestamp}.csv"

    print(f"Warehouse: {warehouse_name} — {len(nvrs)} NVR(s)")

    all_rows: list[dict] = []
    for nvr in nvrs:
        try:
            all_rows.extend(query_nvr(nvr, timeout))
        except Exception as e:
            print(f"  [{nvr.name}] ERROR: {e}", file=sys.stderr)

    with open(output_file, "w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["nvr_name", "nvr_ip", "channel_id", "channel_name", "ip_address",
                        "mac_address", "online", "detect_result"],
        )
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"Saved {len(all_rows)} row(s) to {output_file}")


if __name__ == "__main__":
    main()
