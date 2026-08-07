#!/bin/bash
# Force-removes pods stuck in Terminating state.
# For kata pods, uses crictl stopp to stop the sandbox through the kata-runtime
# so that VFIO GPU bindings and device plugin accounting are released cleanly.
# Reports failure rather than falling back to pkill.
#
# Usage:
#   ./scripts/cleanup-terminating-pods.sh                        # all namespaces
#   ./scripts/cleanup-terminating-pods.sh seismic-interpretation # specific namespace

set -euo pipefail

NAMESPACE="${1:-}"

if [ -n "$NAMESPACE" ]; then
    NS_ARG="-n $NAMESPACE"
    NS_LABEL="namespace $NAMESPACE"
else
    NS_ARG="-A"
    NS_LABEL="all namespaces"
fi

echo "=== Scanning for Terminating pods ($NS_LABEL) ==="

PODS=$(oc get pods $NS_ARG -o json 2>/dev/null | jq -r '
    .items[] |
    select(.metadata.deletionTimestamp != null) |
    [
        .metadata.namespace,
        .metadata.name,
        (.spec.nodeName // ""),
        (.spec.runtimeClassName // "")
    ] | @tsv
')

if [ -z "$PODS" ]; then
    echo "No Terminating pods found."
    exit 0
fi

echo ""
printf "%-30s %-45s %-35s %-20s\n" "NAMESPACE" "POD" "NODE" "RUNTIME"
printf "%-30s %-45s %-35s %-20s\n" "---------" "---" "----" "-------"
while IFS=$'\t' read -r ns pod node runtime; do
    printf "%-30s %-45s %-35s %-20s\n" "$ns" "$pod" "${node:-unknown}" "${runtime:-default}"
done <<< "$PODS"

# --- Collect sandbox IDs for kata pods BEFORE deleting their records ---
# The sandbox ID is needed to stop the runtime sandbox on the node.
# It must be collected before force-deleting the pod record.
declare -A NODE_SANDBOXES   # node -> space-separated "ns/pod/sandbox_id" triples
declare -A SKIP_DELETE       # "ns/pod" -> 1 for pods whose sandbox stop failed

while IFS=$'\t' read -r ns pod node runtime; do
    [[ "$runtime" != *kata* ]] && continue
    [ -z "$node" ] && continue

    echo ""
    echo "Collecting sandbox ID for kata pod $ns/$pod on $node..."
    SID=$(oc debug node/"$node" -- chroot /host \
        crictl pods --namespace "$ns" --name "$pod" --no-trunc -q 2>/dev/null \
        | head -1 || true)

    if [ -n "$SID" ]; then
        echo "  Sandbox ID: $SID"
        NODE_SANDBOXES["$node"]="${NODE_SANDBOXES[$node]:-} $ns/$pod/$SID"
    else
        echo "  WARNING: could not get sandbox ID for $ns/$pod (may have already exited)"
    fi
done <<< "$PODS"

# --- Stop kata sandboxes via crictl before removing pod records ---
# crictl stopp goes through the kata-runtime shutdown sequence so the VM
# exits cleanly, VFIO GPU bindings are released, and the device plugin
# accounting is updated correctly.
FAILED_STOPS=()

if [ ${#NODE_SANDBOXES[@]} -gt 0 ]; then
    echo ""
    echo "=== Stopping kata sandboxes via crictl ==="

    for node in "${!NODE_SANDBOXES[@]}"; do
        for entry in ${NODE_SANDBOXES[$node]}; do
            ns=$(echo "$entry" | cut -d/ -f1)
            pod=$(echo "$entry" | cut -d/ -f2)
            SID=$(echo "$entry" | cut -d/ -f3)

            echo ""
            echo "  Stopping sandbox $SID ($ns/$pod) on $node..."
            if oc debug node/"$node" -- chroot /host \
                crictl stopp "$SID" 2>/dev/null; then
                echo "  ✓ sandbox stopped cleanly via kata-runtime"
            else
                echo "  ✗ crictl stopp failed for sandbox $SID — pod record will NOT be deleted"
                FAILED_STOPS+=("$node / $ns/$pod / $SID")
                SKIP_DELETE["$ns/$pod"]=1
            fi
        done
    done
fi

# --- Force-delete the pod records from Kubernetes ---
echo ""
echo "=== Force-deleting pod records ==="

while IFS=$'\t' read -r ns pod node runtime; do
    if [ -n "${SKIP_DELETE[$ns/$pod]:-}" ]; then
        echo "  Skipping $ns/$pod — sandbox stop failed, pod record preserved"
    else
        echo "  Deleting $ns/$pod..."
        oc delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null || true
    fi
done <<< "$PODS"

# --- Report any sandboxes that could not be stopped ---
echo ""
if [ ${#FAILED_STOPS[@]} -eq 0 ]; then
    echo "=== Done — all kata sandboxes stopped cleanly ==="
else
    echo "=== WARNING: the following sandboxes could not be stopped cleanly ==="
    echo ""
    echo "  The pod records have been removed from Kubernetes but the kata VM"
    echo "  may still be running on the node, holding the GPU."
    echo ""
    for entry in "${FAILED_STOPS[@]}"; do
        node=$(echo "$entry" | cut -d/ -f1 | xargs)
        SID=$(echo "$entry"  | cut -d/ -f3 | xargs)
        echo "  Node: $node   Sandbox: $SID"
        echo "    Check:  oc debug node/$node -- chroot /host crictl pods"
        echo "    Retry:  oc debug node/$node -- chroot /host crictl stopp $SID"
    done
    echo ""
    echo "  If crictl stopp continues to fail, contact your cluster admin to"
    echo "  investigate the node. A node drain/reboot will fully clear the GPU."
    exit 1
fi
