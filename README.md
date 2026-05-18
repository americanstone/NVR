# NVR

Scripts for querying Hikvision NVRs via ISAPI and exporting device info to CSV.

## Project structure

```
NVR/
├── scripts/
│   └── get_devices.py   # query script
├── poc/                 # one folder per warehouse/NVR
│   └── .env             # NVR credentials and config
└── docs/
    └── isapi.pdf
```

Each warehouse has its own folder containing a `.env` file. The output CSV is written to the same folder.

## Setup

**macOS / Linux:**
```bash
pip3 install requests python-dotenv
```

**Windows:**
```bat
pip install requests python-dotenv
```

## Configuration

Create a `.env` file in the warehouse folder:

```ini
WAREHOUSE_NAME=poc

# NVRs — add more by incrementing the index (0, 1, 2, ...)
NVR_NAME_0=NVR1
NVR_HOST_0=192.168.1.100
NVR_PORT_0=80
NVR_USER_0=admin
NVR_PASS_0=yourpassword

# NVR_NAME_1=NVR2
# NVR_HOST_1=192.168.1.101
# NVR_PORT_1=8080
# NVR_USER_1=admin
# NVR_PASS_1=yourpassword

# Global camera credentials for fetching MAC addresses.
# If omitted, MAC address column will be blank.
CAM_USER=admin
CAM_PASS=yourpassword

# Per-camera credential overrides: CAM_USER_{nvr_index}_{channel_id}
# Only needed if a specific camera uses different credentials than the global defaults.
# CAM_USER_0_1=other_user
# CAM_PASS_0_1=other_pass

# TIMEOUT=5
```

## Running

**macOS / Linux:**
```bash
python3 scripts/get_devices.py <warehouse-folder>
```

**Windows:**
```bat
python scripts\get_devices.py <warehouse-folder>
```

**Example:**

```bash
# macOS / Linux
python3 scripts/get_devices.py poc

# Windows
python scripts\get_devices.py poc
```

Output is written to `<warehouse-folder>/<WAREHOUSE_NAME>_NVRs_<TIMESTAMP>.csv`.

## Adding a new warehouse

**macOS / Linux:**
```bash
mkdir warehouse-a
cp poc/.env warehouse-a/.env
# edit warehouse-a/.env with the correct values
python3 scripts/get_devices.py warehouse-a
```

**Windows:**
```bat
mkdir warehouse-a
copy poc\.env warehouse-a\.env
rem edit warehouse-a\.env with the correct values
python scripts\get_devices.py warehouse-a
```

## Output columns

| Column | Description |
|---|---|
| `nvr_name` | NVR name as configured in `.env` |
| `nvr_ip` | NVR IP address |
| `channel_id` | Channel number on the NVR |
| `channel_name` | Configured camera name |
| `ip_address` | Camera IP address |
| `mac_address` | Camera MAC address (queried directly from each camera; blank if no camera credentials provided) |
| `online` | `true`/`false` — whether the NVR currently has an active connection to the camera |
| `detect_result` | Specific connection status. `connect` when online; otherwise the reason it is not connected (see below) |

`online` is effectively redundant — it can be derived from `detect_result`. When `online=true`, `detect_result` is always `connect`.

### `detect_result` values

| Value | Meaning |
|---|---|
| `connect` | Camera is connected |
| `errorUserNameOrPasswd` | Wrong camera credentials |
| `netUnreachable` | Camera IP is not reachable |
| `domainError` | Incorrect domain name |
| `ipcStreamFail` | Connected but failed to get stream |
| `overSysBandwidth` | Insufficient bandwidth |
| `unknownError` | Unclassified failure |
