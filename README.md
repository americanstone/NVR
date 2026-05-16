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

Install dependencies:

```bash
pip3 install requests python-dotenv
```

## Configuration

Create a `.env` file in the warehouse folder:

```ini
NVR_NAME=poc
NVR_HOST=192.168.1.100
NVR_USER=admin
NVR_PASS=yourpassword

# Optional: camera credentials if different from NVR credentials
CAM_USER=admin
CAM_PASS=yourpassword

# Optional
# TIMEOUT=5
```

## Running

```bash
python3 scripts/get_devices.py <warehouse-folder>
```

**Example:**

```bash
python3 scripts/get_devices.py poc
```

Output is written to `<warehouse-folder>/<NVR_NAME>-devices.csv`, e.g. `poc/poc-devices.csv`.

## Adding a new warehouse

```bash
mkdir warehouse-a
cp poc/.env warehouse-a/.env
# edit warehouse-a/.env with the correct NVR_NAME, NVR_HOST, NVR_USER, NVR_PASS
python3 scripts/get_devices.py warehouse-a
```

## Output columns

| Column | Description |
|---|---|
| `channel_id` | Channel number on the NVR |
| `channel_name` | Configured camera name |
| `ip_address` | Camera IP address |
| `mac_address` | Camera MAC address (queried directly from each camera) |
| `online` | Whether the camera is currently online |
| `detect_result` | Connection status detail (e.g. `connect`, `errorUserNameOrPasswd`) |
