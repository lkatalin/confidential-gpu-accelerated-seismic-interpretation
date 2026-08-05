#!/usr/bin/env python3
"""
Decode an EAR (Entity Attestation Report) JWT token from CDH and display trust claims
with full evidence details and optional actual-vs-expected measurement comparison.

Reads the CDH /aa/token JSON response from stdin:
  {"token": "<JWT>", "tee_keypair": "..."}

Or accepts a raw JWT string directly.

Usage:
    # Basic:
    curl -s http://127.0.0.1:8006/aa/token?token_type=kbs | python3 scripts/decode-ear-token.py

    # With expected TDX measurements for mismatch detection:
    ... | python3 scripts/decode-ear-token.py \
        --mr-td $TDX_MR_TD --xfam $TDX_XFAM \
        --rtmr-1 $TDX_RTMR_1 --rtmr-2 $TDX_RTMR_2

    # Or via environment variables (used by make debug-attestation):
    export TDX_MR_TD=... TDX_XFAM=... TDX_RTMR_1=... TDX_RTMR_2=...
    ... | python3 scripts/decode-ear-token.py
"""
import sys
import json
import base64
import os
import argparse

AFFIRMING_MIN = 2
AFFIRMING_MAX = 31

# Fields where we can compare actual vs. expected (Makefile variable name → evidence key)
TDX_MEASUREMENT_FIELDS = {
    'mr_td':  'TDX_MR_TD',
    'xfam':   'TDX_XFAM',
    'rtmr_1': 'TDX_RTMR_1',
    'rtmr_2': 'TDX_RTMR_2',
}


def affirming(val):
    return isinstance(val, int) and AFFIRMING_MIN <= val <= AFFIRMING_MAX


def decode_jwt_payload(token):
    parts = token.split('.')
    if len(parts) != 3:
        raise ValueError(f"Expected 3-part JWT, got {len(parts)} parts")
    b64 = parts[1]
    b64 += '=' * ((4 - len(b64) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(b64))


def normalize_hex(val):
    """Strip 0x prefix and lowercase for comparison."""
    return str(val).lower().lstrip('0x') if val else ''


def print_field(key, val, indent=8, expected=None):
    """Print a single evidence field, with optional actual-vs-expected comparison."""
    prefix = ' ' * indent
    norm_val = normalize_hex(val)
    norm_exp = normalize_hex(expected) if expected else ''

    if expected:
        match = norm_val == norm_exp
        tag = 'MATCH    ' if match else 'MISMATCH <--'
        print(f"{prefix}{key:<30} {val}")
        print(f"{prefix}{'':30} expected: {expected}  [{tag}]")
    else:
        if isinstance(val, dict):
            print(f"{prefix}{key}:")
            for k, v in sorted(val.items()):
                print_field(k, v, indent + 2)
        elif isinstance(val, list):
            if all(isinstance(x, str) and len(x) < 80 for x in val):
                for i, item in enumerate(val):
                    print_field(f"{key}[{i}]", item, indent)
            else:
                print(f"{prefix}{key}: {json.dumps(val)}")
        else:
            print(f"{prefix}{key:<30} {val}")


def show_evidence(ev, expected_measurements):
    """Print all evidence fields, grouping TDX measurements and NVIDIA separately."""
    if not ev or not isinstance(ev, dict):
        print("        (no annotated evidence)")
        return

    # Separate top-level keys into categories
    nvidia = ev.get('nvidia', {})
    tdx_keys = sorted(k for k in ev if k != 'nvidia')

    if tdx_keys:
        print("      TDX / CPU Evidence:")
        for key in tdx_keys:
            val = ev[key]
            exp = expected_measurements.get(key)
            print_field(key, val, indent=8, expected=exp)

        # Also check rtmr array form: some versions emit rtmr: ["r0","r1","r2","r3"]
        rtmr_arr = ev.get('rtmr')
        if isinstance(rtmr_arr, list):
            for i, r in enumerate(rtmr_arr):
                exp = expected_measurements.get(f'rtmr_{i}')
                print_field(f"rtmr[{i}]", r, indent=8, expected=exp)

    if nvidia and isinstance(nvidia, dict):
        print("      NVIDIA / GPU Evidence:")
        for key in sorted(nvidia.keys()):
            print_field(key, nvidia[key], indent=8)


def main():
    parser = argparse.ArgumentParser(description="Decode EAR JWT and show trust claims")
    parser.add_argument('--mr-td',  default=os.environ.get('TDX_MR_TD',  ''),
                        help='Expected MR_TD value (or set TDX_MR_TD env var)')
    parser.add_argument('--xfam',   default=os.environ.get('TDX_XFAM',   ''),
                        help='Expected XFAM value (or set TDX_XFAM env var)')
    parser.add_argument('--rtmr-1', default=os.environ.get('TDX_RTMR_1', ''),
                        help='Expected RTMR_1 value (or set TDX_RTMR_1 env var)')
    parser.add_argument('--rtmr-2', default=os.environ.get('TDX_RTMR_2', ''),
                        help='Expected RTMR_2 value (or set TDX_RTMR_2 env var)')
    args = parser.parse_args()

    expected_measurements = {
        'mr_td':  args.mr_td,
        'xfam':   args.xfam,
        'rtmr_1': args.rtmr_1,
        'rtmr_2': args.rtmr_2,
    }
    has_expected = any(v for v in expected_measurements.values())

    raw = sys.stdin.read().strip()
    if not raw:
        print("ERROR: empty input — CDH token endpoint may be unreachable", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw)
        token = data['token']
    except (json.JSONDecodeError, KeyError):
        token = raw

    try:
        claims = decode_jwt_payload(token)
    except Exception as e:
        print(f"ERROR: failed to decode JWT: {e}", file=sys.stderr)
        sys.exit(1)

    verifier = claims.get('ear.verifier-id', {}).get('build', 'unknown')
    print(f"\n=== EAR Trust Claims ===")
    print(f"Verifier: {verifier}")
    if not has_expected:
        print("  (Pass --mr-td/--xfam/--rtmr-1/--rtmr-2 or set TDX_* env vars for actual-vs-expected comparison)")

    submods = claims.get('submods', {})
    if not submods:
        print("No submods found in token payload.")
        return

    blocking = []
    for name in sorted(submods):
        sub = submods[name]
        tv = sub.get('ear.trustworthiness-vector', {})
        status = sub.get('ear.status', 'unknown')
        marker = 'OK  ' if status == 'affirming' else 'FAIL'
        print(f"\n  [{marker}] {name}  (status: {status})")

        print("    Trustworthiness vector:")
        for key in ('executables', 'hardware', 'configuration'):
            val = tv.get(key)
            if val is None:
                continue
            if affirming(val):
                label = 'affirming'
            else:
                label = 'NON-AFFIRMING  <-- blocking'
                blocking.append((name, key, val))
            print(f"        {key:<22} {val:>3}  ({label})")

        ev = sub.get('ear.veraison.annotated-evidence', {})
        if isinstance(ev, str):
            try:
                ev = json.loads(ev)
            except Exception:
                ev = {}

        print()
        show_evidence(ev, expected_measurements)

    print()
    if blocking:
        print("  Policy will DENY — non-affirming claims:")
        for name, key, val in blocking:
            print(f"    {name}.{key} = {val}")
        print()
        print("  Fix options:")
        if any(k == 'hardware' and n.startswith('cpu') for n, k, v in blocking):
            print("    CPU hardware=97: tcb_status is OutOfDate.")
            print("      Option 1 (correct): update TDX microcode/firmware on the host.")
            print("      Option 2 (quick):   relax resource policy to exclude CPU hardware check.")
        if any(k == 'executables' for n, k, v in blocking):
            print("    Executables non-affirming: MR_TD, RTMR_1, or RTMR_2 may not match RVPS reference values.")
            print("      Run: scripts/collect-tdx-measurements.sh, export the values,")
            print("           then: make setup-attestation NAMESPACE=<ns> TDX_MR_TD=... TDX_RTMR_1=... TDX_RTMR_2=...")
        if any(k == 'configuration' for n, k, v in blocking):
            print("    Configuration non-affirming: initdata hash (tdx_pcr08) may not match RVPS.")
            print("      Run: make setup-attestation NAMESPACE=<ns>")
        if any(k == 'hardware' and n.startswith('gpu') for n, k, v in blocking):
            print("    GPU hardware non-affirming: NVIDIA HW attestation failed.")
            print("      Check NRAS connectivity and GPU attestation policy.")
    else:
        print("  All trust claims affirming — resource policy should allow key release.")


if __name__ == '__main__':
    main()
