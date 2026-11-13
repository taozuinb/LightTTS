#!/usr/bin/env bash
set -euo pipefail

default_image_tag=ccr.ccs.tencentyun.com/gz_asr/light-tts:local
default_base_image=nvcr.io/nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo "Usage: $0 [IMAGE_TAG]"
    echo "Install LightTTS dependencies in the image using Python 3.10 and pip."
    echo "Default image tag: $default_image_tag"
    echo "Set BASE_IMAGE to override the CUDA base ($default_base_image)."
    echo "Set MODEL_DIR to include a local CosyVoice2 model directory in the image."
    exit 0
fi

if (( $# > 1 )); then
    echo "Usage: $0 [IMAGE_TAG]" >&2
    exit 2
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! docker buildx version >/dev/null 2>&1; then
    echo "Docker with the Buildx plugin is required." >&2
    exit 1
fi

if [[ ! -f $project_dir/cosyvoice/cosyvoice/cli/frontend.py ||
      ! -f $project_dir/third_party/Matcha-TTS/matcha/__init__.py ]]; then
    echo "Initialize the submodules with: git submodule update --init --recursive" >&2
    exit 1
fi

build_args=(--target light-tts)
if [[ -n ${MODEL_DIR:-} ]]; then
    if ! model_dir=$(cd -P -- "$MODEL_DIR" && pwd); then
        echo "Cannot open model directory: $MODEL_DIR" >&2
        exit 1
    fi

    for file in cosyvoice2.yaml llm.pt flow.pt hift.pt campplus.onnx \
        speech_tokenizer_v2.onnx flow.decoder.estimator.fp32.onnx; do
        if [[ ! -f $model_dir/$file || ! -s $model_dir/$file ]]; then
            echo "Missing or empty model file: $model_dir/$file" >&2
            exit 1
        fi
    done
    if [[ ! -d $model_dir/CosyVoice-BlankEN ]]; then
        echo "Missing tokenizer directory: $model_dir/CosyVoice-BlankEN" >&2
        exit 1
    fi

    model_link=$(find "$model_dir" -name '*.plan' -prune -o -type l -print -quit)
    if [[ -n $model_link ]]; then
        echo "Replace this model symlink with its target before building: $model_link" >&2
        exit 1
    fi
    build_args=(--target light-tts-with-model --build-context "tts_model=$model_dir")
fi

docker buildx build --platform linux/amd64 --load \
    --file "$project_dir/Dockerfile.venv" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-$default_base_image}" \
    --build-arg PYTHON_ENV_STAGE=downloaded-venv \
    --build-arg PYTHON_VERSION=3.10 \
    --tag "${1:-$default_image_tag}" \
    "${build_args[@]}" \
    "$project_dir"
