#!/bin/bash
set -euo pipefail

ENC_PATH=/models-cache/dutchf3_unet_final.pth.enc
PT_PATH=/models-cache/dutchf3_unet_final.pth
CDH_URL=http://127.0.0.1:8006/cdh/resource/default/${KBS_NAMESPACE}/model-key

echo "Waiting for CDH to be ready (URL: $CDH_URL)..."
until curl -sf "$CDH_URL" -o /tmp/model.key; do
    echo "--- CDH attempt failed, retrying in 5s ---"
    curl -v "$CDH_URL" -o /dev/null 2>&1 | tail -20 || true
    sleep 5
done
echo "Key received from KBS via CDH"

openssl enc -d -aes-256-cbc -pbkdf2 \
    -in  "$ENC_PATH" \
    -out "$PT_PATH"  \
    -pass file:/tmp/model.key

rm -f /tmp/model.key
echo "Model decrypted to $PT_PATH"
