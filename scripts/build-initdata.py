#!/usr/bin/env python3
"""
Build the cc_init_data blob for the kata VM.

Usage: build-initdata.py <KBS_URL> <NAMESPACE> [--pcr8-only]
                         [--policy-mode dev|locked]
                         [--app-image <repo>] [--model-image <repo>]
  Reads the KBS TLS certificate PEM from stdin.
  Default: prints the gzip+base64-encoded initdata TOML to stdout.
  --pcr8-only: prints the tdx_pcr08 hex value to stdout instead.
  --policy-mode: selects scripts/policy-dev.rego or scripts/policy-locked.rego
                 (default: locked)
  --app-image / --model-image: image repo prefixes substituted into the locked
                 policy (required when --policy-mode=locked)

The initdata TOML contains three keys (aa.toml, cdh.toml, policy.rego).
Its SHA-256 hash is included in the TEE attestation report when hardware TEE
is present, binding the pod's KBS endpoint and image policy to the hardware
measurement.  On the dev cluster (no TEE) the hash is computed but not bound
to hardware; the binding activates when the pod moves to the bare metal cluster.

tdx_pcr08 is the vTPM PCR8 value after extending the initdata hash:
  SHA256(zeroes_32 || SHA256(initdata_toml_bytes))
Registering this in RVPS prevents the cluster admin from modifying the initdata
(KBS URL, image policy URI, namespace) without failing the configuration check.
"""
import base64
import gzip
import hashlib
import os
import sys

pcr8_only = "--pcr8-only" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]

if len(args) != 2:
    print(f"Usage: {sys.argv[0]} <KBS_URL> <NAMESPACE> [--pcr8-only] [--policy-mode dev|locked] [--app-image <repo>] [--model-image <repo>]", file=sys.stderr)
    sys.exit(1)

kbs_url = args[0]
namespace = args[1]

policy_mode = "locked"
app_image_repo = ""
model_image_repo = ""
i = 1
while i < len(sys.argv):
    if sys.argv[i] == "--policy-mode" and i + 1 < len(sys.argv):
        policy_mode = sys.argv[i + 1]
        i += 2
    elif sys.argv[i] == "--app-image" and i + 1 < len(sys.argv):
        app_image_repo = sys.argv[i + 1].split(":")[0]
        i += 2
    elif sys.argv[i] == "--model-image" and i + 1 < len(sys.argv):
        model_image_repo = sys.argv[i + 1].split(":")[0]
        i += 2
    else:
        i += 1

if policy_mode not in ("dev", "locked"):
    print(f"Error: --policy-mode must be 'dev' or 'locked', got '{policy_mode}'", file=sys.stderr)
    sys.exit(1)

if policy_mode == "locked" and (not app_image_repo or not model_image_repo):
    print("Error: --app-image and --model-image are required when --policy-mode=locked", file=sys.stderr)
    sys.exit(1)

script_dir = os.path.dirname(os.path.abspath(__file__))
policy_file = os.path.join(script_dir, "..", "policies", f"policy-{policy_mode}.rego")
with open(policy_file) as f:
    policy_rego = f.read()

if policy_mode == "locked":
    policy_rego = policy_rego.replace("{app_image_repo}", app_image_repo)
    policy_rego = policy_rego.replace("{model_image_repo}", model_image_repo)

kbs_cert = sys.stdin.read().strip()

aa_toml = f"""\
[token_configs]
[token_configs.coco_as]
url = "{kbs_url}"

[token_configs.kbs]
url = "{kbs_url}"
cert = \"\"\"
{kbs_cert}
\"\"\"\
"""

cdh_toml = f"""\
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "{kbs_url}"
kbs_cert = \"\"\"
{kbs_cert}
\"\"\"

[image]
image_security_policy_uri = 'kbs:///default/{namespace}/image-policy'\
"""

toml = f"""\
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
{aa_toml}
'''

"cdh.toml" = '''
{cdh_toml}
'''

"policy.rego" = '''
{policy_rego}
'''
"""

toml_bytes = toml.encode()

if pcr8_only:
    pcr = bytes(32)
    toml_hash = hashlib.sha256(toml_bytes).digest()
    pcr8 = hashlib.sha256(pcr + toml_hash).hexdigest()
    print(pcr8, end="")
else:
    print(base64.b64encode(gzip.compress(toml_bytes)).decode(), end="")
