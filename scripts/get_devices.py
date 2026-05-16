#!/usr/bin/env python3
"""
Query a Hikvision NVR via ISAPI and export all channels to CSV.

Usage:
    python3 scripts/get_devices.py <warehouse-dir>

    <warehouse-dir> must contain a .env file with NVR_HOST, NVR_USER, NVR_PASS.
    The output CSV is written to <warehouse-dir>/nvr_devices.csv.

Example:
    python3 scripts/get_devices.py poc
    python3 scripts/get_devices.py warehouse-a

Columns: channel_id, channel_name, ip_address, mac_address, online, detect_result

MAC address is fetched from each camera's own /ISAPI/System/Network/interfaces endpoint.
If a camera is unreachable or uses different credentials, mac_address will be blank.
"""

import argparse
import csv
import os
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from requests.auth import HTTPDigestAuth

NS = "http://www.isapi.org/ver20/XMLSchema"

NVR_NAME = ""
NVR_HOST = ""
NVR_USER = ""
NVR_PASS = ""
CAM_USER = ""
CAM_PASS = ""
TIMEOUT = 5


def load_env(warehouse_dir: Path) -> None:
    env_file = warehouse_dir / ".env"
    if not env_file.exists():
        print(f"ERROR: {env_file} not found.", file=sys.stderr)
        sys.exit(1)

    try:
        from dotenv import dotenv_values
        values = dotenv_values(env_file)
    except ImportError:
        # Minimal fallback parser
        values = {}
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            values[k.strip()] = v.strip()

    global NVR_NAME, NVR_HOST, NVR_USER, NVR_PASS, CAM_USER, CAM_PASS, TIMEOUT
    NVR_HOST = values.get("NVR_HOST", "")
    NVR_USER = values.get("NVR_USER", "admin")
    NVR_PASS = values.get("NVR_PASS", "")
    CAM_USER = values.get("CAM_USER", NVR_USER)
    CAM_PASS = values.get("CAM_PASS", NVR_PASS)
    TIMEOUT = int(values.get("TIMEOUT", "5"))
    NVR_NAME = values.get("NVR_NAME", "")

    if not NVR_HOST or not NVR_PASS:
        print(f"ERROR: NVR_HOST and NVR_PASS must be set in {env_file}", file=sys.stderr)
        sys.exit(1)
    if not NVR_NAME:
        print(f"ERROR: NVR_NAME must be set in {env_file}", file=sys.stderr)
        sys.exit(1)


def nvr_get(path: str) -> ET.Element:
    url = f"http://{NVR_HOST}{path}"
    r = requests.get(url, auth=HTTPDigestAuth(NVR_USER, NVR_PASS), timeout=TIMEOUT)
    r.raise_for_status()
    return ET.fromstring(r.text)


def cam_get_mac(ip: str) -> str:
    try:
        url = f"http://{ip}/ISAPI/System/Network/interfaces"
        r = requests.get(url, auth=HTTPDigestAuth(CAM_USER, CAM_PASS), timeout=TIMEOUT)
        r.raise_for_status()
        root = ET.fromstring(r.text)
        for el in root.iter():
            if el.tag.split("}")[-1] == "MACAddress":
                mac = (el.text or "").strip()
                if mac:
                    return mac
    except Exception:
        pass
    return ""


def find(element: ET.Element, tag: str) -> str:
    el = element.find(f"{{{NS}}}{tag}")
    if el is None:
        el = element.find(tag)
    return (el.text or "").strip() if el is not None else ""


def get_channels() -> list[dict]:
    root = nvr_get("/ISAPI/ContentMgmt/InputProxy/channels")
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


def get_statuses() -> dict[str, dict]:
    try:
        root = nvr_get("/ISAPI/ContentMgmt/InputProxy/channels/status")
    except Exception:
        return {}
    statuses = {}
    for st in root.iter(f"{{{NS}}}InputProxyChannelStatus"):
        ch_id = find(st, "id")
        statuses[ch_id] = {
            "online": find(st, "online"),
            "detect_result": find(st, "chanDetectResult"),
        }
    return statuses


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

    load_env(warehouse_dir)
    output_file = warehouse_dir / f"{NVR_NAME}-devices.csv"

    print(f"Querying NVR at {NVR_HOST} ...")
    channels = get_channels()
    print(f"Found {len(channels)} channel(s). Fetching statuses ...")
    statuses = get_statuses()

    print("Fetching MAC addresses from cameras (parallel) ...")
    mac_map: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = {
            pool.submit(cam_get_mac, ch["ip"]): ch["id"]
            for ch in channels if ch["ip"]
        }
        for future in as_completed(futures):
            mac_map[futures[future]] = future.result()

    rows = []
    for ch in channels:
        ch_id = ch["id"]
        status = statuses.get(ch_id, {})
        rows.append({
            "channel_id": ch_id,
            "channel_name": ch["name"],
            "ip_address": ch["ip"],
            "mac_address": mac_map.get(ch_id, ""),
            "online": status.get("online", ""),
            "detect_result": status.get("detect_result", ""),
        })

    rows.sort(key=lambda r: int(r["channel_id"]) if r["channel_id"].isdigit() else 0)

    with open(output_file, "w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["channel_id", "channel_name", "ip_address", "mac_address", "online", "detect_result"],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Saved {len(rows)} row(s) to {output_file}")


if __name__ == "__main__":
    main()
