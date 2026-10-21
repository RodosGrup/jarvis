#!/bin/sh
# sherpa-onnx kütüphanesini ve konuşmacı modelini indirir (vendor/ git'e girmez).
# Kullanım: sh scripts/fetch-vendor.sh
set -e
cd "$(dirname "$0")/.."
VER=1.13.8
mkdir -p vendor/sherpa-onnx/include vendor/models
curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VER}/sherpa-onnx-v${VER}-osx-arm64-shared-no-tts-lib.tar.bz2" -o /tmp/sherpa.tar.bz2
tar -xjf /tmp/sherpa.tar.bz2 -C vendor/sherpa-onnx --strip-components=1
rm /tmp/sherpa.tar.bz2
curl -sL "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VER}/sherpa-onnx/c-api/c-api.h" -o vendor/sherpa-onnx/include/c-api.h
curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx" -o vendor/models/speaker.onnx
echo "tamam: vendor/sherpa-onnx ve vendor/models/speaker.onnx"
