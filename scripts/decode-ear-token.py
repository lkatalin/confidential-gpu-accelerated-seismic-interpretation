#!/usr/bin/env python3
"""
Decode an EAR (Entity Attestation Report) JWT token from CDH and display trust claims.

Reads the CDH /aa/token JSON response from stdin:
  {"token": "<JWT>", "tee_keypair": "..."}

Or accepts a raw JWT string directly.

Outputs a human-readable summary of trust claims for each submod (cpu0, gpu0, etc.)
and highlights any non-affirming values that would cause a resource policy deny.
"""
import sys
import json
import base64


AFFIRMING_MIN = 2
AFFIRMING_MAX = 31


def affirming(val):
    return isinstance(val, int) and AFFIRMING_MIN <= val <= AFFIRMING_MAX


def decode_jwt_payload(token):
    parts = token.split('.')
    if len(parts) != 3:
        raise ValueError(f"Expected 3-part JWT, got {len(parts)} parts")
    b64 = parts[1]
    b64 += '=' * ((4 - len(b64) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(b64))


def find_nested(obj, key):
    """Recursively find the first value for a key in a nested dict/list."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            result = find_nested(v, key)
            if result is not None:
                return result
    elif isinstance(obj, list):
        for item in obj:
            result = find_nested(item, key)
            if result is not None:
                return result
    return None


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        print("ERROR: empty input — CDH token endpoint may be unreachable", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw)
        token = data['token']
    except (json.JSONDecodeError, KeyError):
        token = raw  # raw JWT passed directly

    try:
        claims = decode_jwt_payload(token)
    except Exception as e:
        print(f"ERROR: failed to decode JWT: {e}", file=sys.stderr)
        sys.exit(1)

    verifier = claims.get('ear.verifier-id', {}).get('build', 'unknown')
    print(f"\n=== EAR Trust Claims ===")
    print(f"Verifier: {verifier}")

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

        # TDX-specific context
        tcb = find_nested(ev, 'tcb_status')
        if tcb is not None:
            note = '  <-- causes hardware=97' if tcb != 'UpToDate' else ''
            print(f"        {'tcb_status':<22}      {tcb}{note}")

        # NVIDIA-specific context
        nvidia = ev.get('nvidia', {})
        if not isinstance(nvidia, dict):
            nvidia = {}
        for nv_key, label in [
            ('hwmodel',                       'gpu_model'),
            ('x-nvidia-gpu-driver-version',   'driver_version'),
            ('x-nvidia-gpu-vbios-version',    'vbios_version'),
            ('measres',                       'measres'),
            ('secboot',                       'secboot'),
        ]:
            val = nvidia.get(nv_key)
            if val is not None:
                print(f"        {label:<22}      {val}")

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
            print("      Option 2 (quick):   relax the resource policy to not check CPU hardware.")
        if any(k == 'executables' for n, k, v in blocking):
            print("    Executables non-affirming: register missing RVPS reference values")
            print("    (e.g. tdvfkernel, allowed_vbios_versions) or review attestation policy.")
        if any(k == 'hardware' and n.startswith('gpu') for n, k, v in blocking):
            print("    GPU hardware non-affirming: NVIDIA HW attestation failed.")
            print("    Check NRAS connectivity and GPU attestation policy.")
    else:
        print("  All trust claims affirming — resource policy should allow key release.")


if __name__ == '__main__':
    main()
