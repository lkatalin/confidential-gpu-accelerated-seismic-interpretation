#!/usr/bin/env python3
"""
Upsert RVPS reference values into the conf-seismic-rvps-reference-values JSON.

Usage: update-rvps.py <current_json> <pcr8_value>
  current_json  - existing JSON content of the configmap's reference-values.json key
  pcr8_value    - computed tdx_pcr08 hex string for the current namespace/initdata

TDX hardware measurements are read from the environment (set via
'scripts/collect-tdx-measurements.sh' output):
  TDX_MR_TD   - OVMF firmware measurement
  TDX_RTMR_1  - kata kernel + initrd measurement
  TDX_RTMR_2  - additional boot measurement
  TDX_XFAM    - QEMU CPU feature mask

Values that are absent from the environment are silently skipped.
Each named entry is appended if new; existing entries gain the new value
only if it is not already present (safe to run repeatedly).

Prints the updated JSON to stdout.
"""
import json
import os
import sys


def upsert(entries, name, value):
    if not value:
        return
    match = next((e for e in entries if e.get('name') == name), None)
    if match:
        vals = match.setdefault('value', [])
        if value not in vals:
            vals.append(value)
    else:
        entries.append({'name': name, 'value': [value]})


if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <current_json> <pcr8_value>", file=sys.stderr)
    sys.exit(1)

current_json, pcr8 = sys.argv[1], sys.argv[2]
entries = json.loads(current_json) if current_json.strip() else []

upsert(entries, 'tdx_pcr08', pcr8)
upsert(entries, 'mr_td',  os.environ.get('TDX_MR_TD', ''))
upsert(entries, 'rtmr_1', os.environ.get('TDX_RTMR_1', ''))
upsert(entries, 'rtmr_2', os.environ.get('TDX_RTMR_2', ''))
upsert(entries, 'xfam',   os.environ.get('TDX_XFAM', ''))

print(json.dumps(entries))
