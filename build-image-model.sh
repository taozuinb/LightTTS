# Shared by the LightTTS image build scripts.
append_model_build_args() {
    local model_dir model_link file
    image_target=light-tts
    if [[ -z ${MODEL_DIR:-} ]]; then
        return
    fi

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
    image_target=light-tts-with-model
    build_args+=(--build-context "tts_model=$model_dir")
}
