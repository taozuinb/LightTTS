#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo "Usage: $0 [IMAGE_TAG]"
    echo "Build from /usr/local/tts/.venv on Linux x86_64. Set BASE_IMAGE to override the CUDA base."
    exit 0
fi

if (( $# > 1 )); then
    echo "Usage: $0 [IMAGE_TAG]" >&2
    exit 2
fi

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo "Run this script on the Linux x86_64 host that has /usr/local/tts/.venv." >&2
    exit 1
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venv_dir=/usr/local/tts/.venv
image_tag=${1:-light-tts:local}

if [[ ! -f $venv_dir/pyvenv.cfg || ! -x $venv_dir/bin/python ]]; then
    echo "A working Python virtual environment is required at $venv_dir." >&2
    exit 1
fi

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
build_args=(--build-arg "PYTHON_VERSION=$python_version")

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

if [[ -n ${BASE_IMAGE:-} ]]; then
    build_args+=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
fi

docker buildx build --platform linux/amd64 --load \
    --file "$project_dir/Dockerfile.venv" \
    --build-context "tts_venv=$venv_dir" \
    --tag "$image_tag" \
    "${build_args[@]}" "$project_dir"
