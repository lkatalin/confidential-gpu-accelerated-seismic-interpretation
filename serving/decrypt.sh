#!/bin/bash
set -euo pipefail

ENC_PATH=/models-cache/dutchf3_unet_final.pth.enc
PT_PATH=/models-cache/dutchf3_unet_final.pth
CDH_URL=http://127.0.0.1:8006/cdh/resource/${KBS_NAMESPACE}/conf-seismic-model-key/key

echo "Waiting for CDH to be ready..."
until curl -sf "$CDH_URL" -o /tmp/model.key 2>/dev/null; do
    sleep 2
done
echo "Key received from KBS via CDH"

openssl enc -d -aes-256-cbc -pbkdf2 \
    -in  "$ENC_PATH" \
    -out "$PT_PATH"  \
    -pass file:/tmp/model.key

rm -f /tmp/model.key
echo "Model decrypted to $PT_PATH"
