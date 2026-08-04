#!/bin/bash
# Collect TDX hardware measurement values from a running kata-cc pod.
#
# mr_td, rtmr_1, rtmr_2, and xfam are stable for a given OSC version and must
# be registered in RVPS so the attestation policy produces affirming scores.
# Register them once; re-run only after an OSC upgrade that changes the kata
# firmware or kernel.
#
# Usage: collect-tdx-measurements.sh [NAMESPACE]
#   NAMESPACE defaults to seismic-interpretation
#   The pod must be running (even if looping on CDH key-fetch retries).
set -euo pipefail

NAMESPACE=${1:-seismic-interpretation}
LABEL="app.kubernetes.io/name=seismic-app"

# ── Find a running pod ────────────────────────────────────────────────────────

POD=$(oc get pod -n "$NAMESPACE" -l "$LABEL" --no-headers 2>/dev/null \
  | awk '$3 ~ /Running|Init/ {print $1; exit}')

if [ -z "$POD" ]; then
  echo "ERROR: No Running/Init pod with label $LABEL in namespace $NAMESPACE" >&2
  echo "       Deploy the app first ('make install'); it will retry CDH in a loop." >&2
  exit 1
fi

echo "Pod: $POD"

# ── Find a container we can exec into ────────────────────────────────────────
# model-decrypt is an init container that loops waiting for the CDH key.
# If init has already completed, app is the running container.

CONTAINER=""
for c in model-decrypt app; do
  if oc exec -n "$NAMESPACE" "$POD" -c "$c" -- true 2>/dev/null; then
    CONTAINER="$c"
    break
  fi
done

if [ -z "$CONTAINER" ]; then
  echo "ERROR: Could not exec into any container in pod $POD" >&2
  echo "       Ensure ExecProcessRequest := true in the initdata policy." >&2
  exit 1
fi

echo "Container: $CONTAINER"
echo ""
echo "Querying attestation agent evidence endpoint..."

# ── Fetch the attestation evidence ───────────────────────────────────────────

EVIDENCE_FILE=$(mktemp /tmp/tdx-evidence.XXXXXX.json)
trap 'rm -f "$EVIDENCE_FILE"' EXIT

RUNTIME_DATA=$(printf '%s' "collect-tdx-measurements" | base64 | tr -d '=')

if ! oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
     curl -sf "http://127.0.0.1:8006/aa/evidence?runtime_data=$RUNTIME_DATA" \
     > "$EVIDENCE_FILE" 2>/dev/null; then
  echo "ERROR: AA evidence endpoint did not respond." >&2
  echo "" >&2
  echo "Fallback — enable debug logging in Trustee to read measurements from AS logs:" >&2
  echo "  oc set env deployment/trustee-deployment -n trustee-operator-system \\" >&2
  echo "    RUST_LOG=attestation_service=debug,rvps=debug" >&2
  echo "  oc logs -n trustee-operator-system -l app=trustee -f \\" >&2
  echo "    | grep -E 'mr_td|rtmr|xfam'" >&2
  exit 1
fi

# ── Parse the TDX quote and extract measurements ──────────────────────────────

python3 - "$EVIDENCE_FILE" <<'PYTHON'
import sys, json, base64

evidence_file = sys.argv[1]
with open(evidence_file) as f:
    raw = f.read().strip()

if not raw:
    print("ERROR: Empty response from AA evidence endpoint", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(f"ERROR: Non-JSON response from AA:\n{raw[:500]}", file=sys.stderr)
    sys.exit(1)

# Locate the quote — different AA versions use different key names
quote_b64 = None
for key in ['quote', 'b64_quote', 'tee-evidence', 'evidence', 'raw-evidence']:
    if key in data:
        quote_b64 = data[key]
        break

if quote_b64 is None:
    print(f"ERROR: No quote field in response. Keys: {list(data.keys())}", file=sys.stderr)
    print(json.dumps(data, indent=2), file=sys.stderr)
    sys.exit(1)

# Try standard then URL-safe base64
try:
    quote = base64.b64decode(quote_b64 + '==')
except Exception:
    try:
        quote = base64.urlsafe_b64decode(quote_b64 + '==')
    except Exception as e:
        print(f"ERROR: Cannot base64-decode quote: {e}", file=sys.stderr)
        sys.exit(1)

# Minimum length: header(48) + TCB_SVN(16) + MR_SEAM(48) + MR_SIGNER_SEAM(48)
#   + SEAM_ATTRS(8) + TD_ATTRS(8) + XFAM(8) + MRTD(48)
#   + MR_CONFIG_ID(48) + MR_OWNER(48) + MR_OWNER_CONFIG(48)
#   + RTMR[0](48) + RTMR[1](48) + RTMR[2](48)
MIN_LEN = 48 + 16 + 48 + 48 + 8 + 8 + 8 + 48 + 48 + 48 + 48 + 48 + 48 + 48
if len(quote) < MIN_LEN:
    print(f"ERROR: Quote too short ({len(quote)} bytes, need >= {MIN_LEN})", file=sys.stderr)
    sys.exit(1)

# TDX DCAP v4 quote layout:
#   Header (48 bytes) followed by TD10 Report Body:
#     TEE_TCB_SVN       16 bytes
#     MR_SEAM           48 bytes
#     MR_SIGNER_SEAM    48 bytes
#     SEAM_ATTRIBUTES    8 bytes
#     TD_ATTRIBUTES      8 bytes   ← td_attributes
#     XFAM               8 bytes   ← xfam
#     MRTD              48 bytes   ← mr_td
#     MR_CONFIG_ID      48 bytes
#     MR_OWNER          48 bytes
#     MR_OWNER_CONFIG   48 bytes
#     RTMR[0]           48 bytes
#     RTMR[1]           48 bytes   ← rtmr_1
#     RTMR[2]           48 bytes   ← rtmr_2
#     RTMR[3]           48 bytes
#     REPORT_DATA       64 bytes
o = 48 + 16 + 48 + 48 + 8 + 8      # skip to XFAM
xfam  = quote[o:o+8];   o += 8
mr_td = quote[o:o+48];  o += 48
o += 48 + 48 + 48                   # skip MR_CONFIG_ID, MR_OWNER, MR_OWNER_CONFIG
o += 48                             # skip RTMR[0]
rtmr1 = quote[o:o+48];  o += 48
rtmr2 = quote[o:o+48]

print("TDX measurements:")
print(f"  mr_td:  {mr_td.hex()}")
print(f"  xfam:   {xfam.hex()}")
print(f"  rtmr_1: {rtmr1.hex()}")
print(f"  rtmr_2: {rtmr2.hex()}")
print()
print("# Makefile variables — paste these into the Makefile and update the OSC version comment:")
print(f"TDX_MR_TD  ?= {mr_td.hex()}")
print(f"TDX_XFAM   ?= {xfam.hex()}")
print(f"TDX_RTMR_1 ?= {rtmr1.hex()}")
print(f"TDX_RTMR_2 ?= {rtmr2.hex()}")
PYTHON
