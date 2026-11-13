#!/usr/bin/env bash
set -euo pipefail

default_image_tag=ccr.ccs.tencentyun.com/gz_asr/light-tts:local
default_base_image=nvcr.io/nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo "Usage: $0 [IMAGE_TAG]"
    echo "Build from /usr/local/tts/.venv on Linux x86_64."
    echo "Set VENV_DIR to use a virtual environment from another directory."
    echo "Default image tag: $default_image_tag"
    echo "Set BASE_IMAGE to override the CUDA base ($default_base_image)."
    echo "Set MODEL_DIR to include a local CosyVoice2 model directory in the image."
    echo "Set TTSFRD_RESOURCE_DIR to include CosyVoice-ttsfrd/resource in the image."
    exit 0
fi

if (( $# > 1 )); then
    echo "Usage: $0 [IMAGE_TAG]" >&2
    exit 2
fi

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo "Run this script on a Linux x86_64 host with the virtual environment." >&2
    exit 1
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venv_dir=${VENV_DIR:-/usr/local/tts/.venv}
image_tag=${1:-$default_image_tag}
base_image=${BASE_IMAGE:-$default_base_image}

if [[ ! -f $venv_dir/pyvenv.cfg || ! -x $venv_dir/bin/python ]]; then
    echo "A working Python virtual environment is required at $venv_dir. Check that bin/python and its base interpreter exist." >&2
    exit 1
fi
venv_dir=$(cd -P -- "$venv_dir" && pwd)

if ! docker buildx version >/dev/null 2>&1; then
    echo "Docker with the Buildx plugin is required." >&2
    exit 1
fi

if [[ ! -f $project_dir/cosyvoice/cosyvoice/cli/frontend.py ||
      ! -f $project_dir/third_party/Matcha-TTS/matcha/__init__.py ]]; then
    echo "Initialize the submodules with: git submodule update --init --recursive" >&2
    exit 1
fi

python_version=$("$venv_dir/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
python_base_prefix=$("$venv_dir/bin/python" -c 'import sys; print(sys.base_prefix)')
build_args=(--build-arg "PYTHON_VERSION=$python_version"
            --build-arg "BASE_IMAGE=$base_image")

case $python_base_prefix in
    /usr|/usr/local)
        # A system Python must be present at the same path in the base image.
        ;;
    /|/opt|/home|/root|/usr/local/tts|"$venv_dir"|"$venv_dir"/*)
        echo "Unsupported Python base prefix: $python_base_prefix. Use a compatible BASE_IMAGE or a standalone Python installation." >&2
        exit 1
        ;;
    *)
        # uv-managed Python and Conda can keep their own interpreter outside the venv.
        if [[ ! -d $python_base_prefix || $venv_dir == "$python_base_prefix"/* ]]; then
            echo "Cannot use $python_base_prefix as a standalone Python installation." >&2
            exit 1
        fi
        build_args+=(--build-context "python_install=$python_base_prefix"
                     --build-arg PYTHON_BASE_STAGE=standalone-python
                     --build-arg "PYTHON_BASE_PREFIX=$python_base_prefix")
        ;;
esac

source "$project_dir/build-image-model.sh"
append_model_build_args

ttsfrd_resource_dir=${TTSFRD_RESOURCE_DIR:-}
if [[ -z $ttsfrd_resource_dir && -n ${MODEL_DIR:-} ]]; then
    sibling_resource_dir=$(cd -P -- "$MODEL_DIR" && pwd)/../CosyVoice-ttsfrd/resource
    if [[ -d $sibling_resource_dir ]]; then
        ttsfrd_resource_dir=$sibling_resource_dir
    elif "$venv_dir/bin/python" -c 'import importlib.util; raise SystemExit(importlib.util.find_spec("ttsfrd") is None)'; then
        echo "The virtual environment contains ttsfrd. Set TTSFRD_RESOURCE_DIR to the CosyVoice-ttsfrd/resource directory." >&2
        exit 1
    fi
fi

if [[ -n $ttsfrd_resource_dir ]]; then
    if ! ttsfrd_resource_dir=$(cd -P -- "$ttsfrd_resource_dir" && pwd); then
        echo "Cannot open the ttsfrd resource directory." >&2
        exit 1
    fi
    resource_file=$(find "$ttsfrd_resource_dir" -type f ! -name '*.whl' -print -quit)
    if [[ -z $resource_file ]]; then
        echo "No resource files found in: $ttsfrd_resource_dir" >&2
        exit 1
    fi
    resource_link=$(find "$ttsfrd_resource_dir" -type l -print -quit)
    if [[ -n $resource_link ]]; then
        echo "Replace this resource symlink with its target before building: $resource_link" >&2
        exit 1
    fi
    build_args+=(--build-arg "TTSFRD_BASE_STAGE=$image_target"
                 --build-context "ttsfrd_resources=$ttsfrd_resource_dir")
    image_target=light-tts-with-ttsfrd
fi

docker buildx build --platform linux/amd64 --load \
    --target "$image_target" \
    --file "$project_dir/Dockerfile.venv" \
    --build-context "tts_venv=$venv_dir" \
    --tag "$image_tag" \
    "${build_args[@]}" "$project_dir"
