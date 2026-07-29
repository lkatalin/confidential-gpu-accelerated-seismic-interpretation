#!/usr/bin/env python3
"""
Build the cc_init_data blob for the kata VM.

Usage: build-initdata.py <KBS_URL> <NAMESPACE> [--pcr8-only]
  Reads the KBS TLS certificate PEM from stdin.
  Default: prints the gzip+base64-encoded initdata TOML to stdout.
  --pcr8-only: prints the tdx_pcr08 hex value to stdout instead.

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
import sys

pcr8_only = "--pcr8-only" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]

if len(args) != 2:
    print(f"Usage: {sys.argv[0]} <KBS_URL> <NAMESPACE> [--pcr8-only]", file=sys.stderr)
    sys.exit(1)

kbs_url = args[0]
namespace = args[1]
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

[api_server]
address = "127.0.0.1:8006"\
"""

policy_rego = """\
package agent_policy
import future.keywords.in
import future.keywords.if
default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := false
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := false
default ExecProcessRequest := true\
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
