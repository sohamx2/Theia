#!/bin/bash

set -u

binary="${1:-/tmp/TheiaClassifierPipelineBenchmark}"
corpus="${2:-Tests/RealScreenshotBenchmark.json}"
output_directory="${3:-BenchmarkResults/model-candidates}"

if [[ ! -x "$binary" ]]; then
    echo "Benchmark binary is missing or not executable: $binary" >&2
    exit 2
fi

if [[ ! -f "$corpus" ]]; then
    echo "Held-out screenshot manifest is missing: $corpus" >&2
    exit 2
fi

mkdir -p "$output_directory"

models=(
    "qwen3:4b"
    "granite3.3:2b"
    "llama3.2:3b"
    "phi4-mini:3.8b"
    "gemma3:4b"
)

failed=0
for model in "${models[@]}"; do
    safe_name="${model//[:.]/-}"
    echo "Benchmarking $model"
    if ! "$binary" \
        --model "$model" \
        --input "$corpus" \
        --classification-cases 1000 \
        --prompt-cases 1000 \
        --held-out-real-screenshots \
        --minimum-parent-accuracy 0.99 \
        --minimum-prompt-success 0.99 \
        --enforce-replacement-gate \
        --output "$output_directory/$safe_name.json" \
        --svg "$output_directory/$safe_name.svg"
    then
        failed=1
    fi
done

exit "$failed"
