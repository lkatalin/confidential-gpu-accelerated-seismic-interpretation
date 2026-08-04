#!/usr/bin/env python3
"""
Upsert RVPS reference values into the trusteeconfig-rvps-reference-values configmap.

The configmap stores values in the RVPS provenance format:
  [{"version": "0.1.0", "type": "sample", "payload": "<base64-encoded-json>"}]

where the decoded payload is a JSON object mapping measurement names to arrays
of allowed hex values:
  {"mr_td": ["hex..."], "rtmr_1": ["hex..."], ...}

Usage: update-rvps.py <current_json> <pcr8_value>
  current_json  - existing JSON content of the configmap's reference-values.json key
  pcr8_value    - computed tdx_pcr08 hex string for the current namespace/initdata

TDX hardware measurements are read from the environment:
  TDX_MR_TD   - OVMF firmware measurement
  TDX_RTMR_1  - kata kernel + initrd measurement
  TDX_RTMR_2  - additional boot measurement
  TDX_XFAM    - QEMU CPU feature mask

Values absent from the environment are silently skipped.
Each named entry is appended if new; existing entries gain the new value
only if not already present (safe to run repeatedly).

Prints the updated JSON to stdout.
"""
import base64
import json
import os
import sys


def upsert(values, name, value):
    if not value:
        return
    if name not in values:
        values[name] = []
    if value not in values[name]:
        values[name].append(value)


if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <current_json> <pcr8_value>", file=sys.stderr)
    sys.exit(1)

current_json, pcr8 = sys.argv[1], sys.argv[2]

# Extract existing values from provenance format (or start empty)
values = {}
if current_json.strip():
    try:
        entries = json.loads(current_json)
        if entries and entries[0].get('type') == 'sample':
            payload = entries[0]['payload']
            padding = (4 - len(payload) % 4) % 4
            values = json.loads(base64.b64decode(payload + '=' * padding).decode())
    except Exception:
        values = {}

upsert(values, 'tdx_pcr08', pcr8)
upsert(values, 'mr_td',  os.environ.get('TDX_MR_TD', ''))
upsert(values, 'rtmr_1', os.environ.get('TDX_RTMR_1', ''))
upsert(values, 'rtmr_2', os.environ.get('TDX_RTMR_2', ''))
upsert(values, 'xfam',   os.environ.get('TDX_XFAM', ''))

payload = base64.b64encode(json.dumps(values).encode()).decode()
print(json.dumps([{'version': '0.1.0', 'type': 'sample', 'payload': payload}]))
