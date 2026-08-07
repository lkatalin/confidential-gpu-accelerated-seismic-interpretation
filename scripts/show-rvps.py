#!/usr/bin/env python3
"""
Decode and pretty-print RVPS reference values — both what 'make setup-attestation'
would register and what is currently stored in the trustee ConfigMap.

Shows all known TDX attestation fields with a clear indicator of whether each
will be registered or not, and why.

Usage: show-rvps.py <pcr8_value> [<current_configmap_json>]
  pcr8_value           - hex PCR8 computed from current initdata (pass '-' to skip)
  current_configmap_json - JSON from the reference_value configmap key (optional)

TDX hardware measurements are read from environment variables:
  TDX_MR_TD    TDVF guest firmware measurement
  TDX_XFAM     CPU extended feature mask
  TDX_RTMR_1   kata guest kernel + command line
  TDX_RTMR_2   kata guest initrd (kata-agent, CDH, AA)
"""
import base64
import json
import os
import sys

# All known TDX/RVPS fields in display order.
# env_key: environment variable that supplies the value (None = not collected via env)
# note:    shown when the field has no value; explains why and what to do
FIELDS = [
    {
        "name":    "tdx_pcr08",
        "desc":    "initdata configuration binding",
        "detail":  "SHA256(zeroes32 || SHA256(initdata_toml_bytes))",
        "env_key": None,   # computed from pcr8 arg, not an env var
        "note":    None,
    },
    {
        "name":    "mr_td",
        "desc":    "TDVF guest firmware (OVMF)",
        "detail":  "changes when kata firmware is updated (OSC upgrade)",
        "env_key": "TDX_MR_TD",
        "note":    "export TDX_MR_TD from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "xfam",
        "desc":    "CPU extended feature mask",
        "detail":  "QEMU CPU feature flags exposed to the TD",
        "env_key": "TDX_XFAM",
        "note":    "export TDX_XFAM from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "rtmr_1",
        "desc":    "kata guest kernel + command line",
        "detail":  "changes when the kata kernel is updated (OSC upgrade)",
        "env_key": "TDX_RTMR_1",
        "note":    "export TDX_RTMR_1 from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "rtmr_2",
        "desc":    "kata guest initrd (kata-agent, CDH, AA)",
        "detail":  "changes when guest components are updated (OSC upgrade)",
        "env_key": "TDX_RTMR_2",
        "note":    "export TDX_RTMR_2 from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "rtmr_0",
        "desc":    "TDVF boot handoff measurement",
        "detail":  "set by TDVF during firmware init, completes the boot chain",
        "env_key": "TDX_RTMR_0",
        "note":    "export TDX_RTMR_0 from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "rtmr_3",
        "desc":    "post-boot guest measurements",
        "detail":  "used by guest OS at runtime; typically zero in kata-cc",
        "env_key": "TDX_RTMR_3",
        "note":    "export TDX_RTMR_3 from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "td_attributes",
        "desc":    "TD attribute flags",
        "detail":  "bit 0 = debug mode; must be 0 for a production confidential workload",
        "env_key": "TDX_TD_ATTRIBUTES",
        "note":    "export TDX_TD_ATTRIBUTES from scripts/collect-tdx-measurements.sh",
    },
    {
        "name":    "mr_seam",
        "desc":    "Intel TDX module version",
        "detail":  "measurement of the Intel TDX module running on the host",
        "env_key": "TDX_MR_SEAM",
        "note":    "export TDX_MR_SEAM from scripts/collect-tdx-measurements.sh",
    },
]

W = 72

def rule(char="─"):
    return char * W

def header(title):
    return f"── {title} {'─' * max(0, W - len(title) - 4)}"

def decode_entry(b64str):
    padding = (4 - len(b64str) % 4) % 4
    return json.loads(base64.b64decode(b64str + '=' * padding).decode())

# ── Collect computed values ───────────────────────────────────────────────────

pcr8         = sys.argv[1] if len(sys.argv) > 1 else "-"
current_json = sys.argv[2] if len(sys.argv) > 2 else "{}"

computed = {}
if pcr8 and pcr8 != "-":
    computed["tdx_pcr08"] = pcr8
for f in FIELDS:
    if f["env_key"]:
        val = os.environ.get(f["env_key"], "").strip()
        if val:
            computed[f["name"]] = val

# ── Decode current configmap ──────────────────────────────────────────────────

current = {}
if current_json and current_json.strip() not in ("", "{}"):
    try:
        raw = json.loads(current_json)
        for name, b64 in raw.items():
            try:
                current[name] = decode_entry(b64)
            except Exception:
                current[name] = {"name": name, "value": [], "expiration": "?"}
    except Exception as e:
        print(f"WARNING: could not parse configmap JSON: {e}", file=sys.stderr)

# ── Print ─────────────────────────────────────────────────────────────────────

print()
print(rule("═"))
print(" RVPS REFERENCE VALUES")
print(rule("═"))
print()

# ── Would be registered ───────────────────────────────────────────────────────

print(header("Would be registered by 'make setup-attestation'"))
print()

known_names = {f["name"] for f in FIELDS}

for f in FIELDS:
    name  = f["name"]
    value = computed.get(name)

    if value:
        print(f"  ✓  {name:<14}  {f['desc']}")
        print(f"                       {f['detail']}")
        print(f"       {value}")
    else:
        print(f"  ✗  {name:<14}  {f['desc']}")
        print(f"                       {f['detail']}")
        if f["note"]:
            print(f"       NOTE: {f['note']}")
    print()

# Show anything in computed that isn't in our known list
for name, value in computed.items():
    if name not in known_names:
        print(f"  ✓  {name:<14}  (unknown field)")
        print(f"       {value}")
        print()

# ── Currently registered ──────────────────────────────────────────────────────

print()
print(header("Currently registered in trustee-operator-system"))
print()

if not current:
    print("  (configmap is empty — nothing registered yet)")
    print()
else:
    # Show in FIELDS order first, then any extras
    ordered = [f["name"] for f in FIELDS] + [k for k in current if k not in known_names]
    for name in ordered:
        if name not in current:
            continue
        entry  = current[name]
        values = entry.get("value", [])
        exp    = entry.get("expiration", "?")
        desc   = next((f["desc"] for f in FIELDS if f["name"] == name), "")
        count  = len(values)
        print(f"  {name:<16}  {desc}")
        print(f"  {'':16}  {count} value{'s' if count != 1 else ''}  expires {exp}")
        for i, v in enumerate(values, 1):
            match = ""
            if name in computed:
                match = "  ✓ matches computed" if v == computed[name] else "  ✗ differs from computed"
            print(f"    [{i}]  {v}{match}")
        print()

print(rule("═"))
print()
