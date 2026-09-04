#!/bin/bash

set -euo pipefail

theia_root="$(cd "$(dirname "$0")/.." && pwd)"
theia_output="${TMPDIR:-/tmp}/TheiaRegressions"
theia_module_cache="$theia_output/ModuleCache"

mkdir -p "$theia_output" "$theia_module_cache"
cd "$theia_root"

theia_sources=(
    Models/*.swift
    Services/*.swift
    App/*.swift
    UI/*.swift
    UI/*/*.swift
)

theia_tests=(
    ChatHistoryStoreRegression
    IntentMemoryIsolationRegression
    InternetAccessRoutingRegression
    PromptActionContractRegression
    PromptTemplateCustomizationRegression
    TemporalFreshnessRegression
    WebsiteEvaluationRegression
)

for theia_test in "${theia_tests[@]}"; do
    echo "Running $theia_test"
    env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcrun swiftc \
        -O \
        -target arm64-apple-macos13.0 \
        -module-cache-path "$theia_module_cache" \
        "${theia_sources[@]}" \
        "Tests/$theia_test.swift" \
        -framework AppKit \
        -framework SwiftUI \
        -framework Vision \
        -framework ScreenCaptureKit \
        -framework NaturalLanguage \
        -lsqlite3 \
        -o "$theia_output/$theia_test"
    "$theia_output/$theia_test"
done

echo "All Theia regressions passed."
