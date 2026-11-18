#!/usr/bin/env bash
#
# Builds and runs the container fuzzer with libFuzzer and AddressSanitizer on Linux.
#
#   Fuzz/run.sh [seconds]
#
# On macOS, run it in a container:
#
#   docker run --rm -v "$PWD:/work:ro" -w /work swift:6.3-noble Fuzz/run.sh 60

set -euo pipefail

readonly seconds="${1:-60}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly work="${FUZZ_WORK:-/tmp/raster-webp-fuzz}"

mkdir -p "${work}/corpus" "${work}/artifacts"

mapfile -t sources < <(find "${root}/Sources/RasterWebPCore" -name '*.swift')

swiftc -O -swift-version 6 -parse-as-library -sanitize=fuzzer,address \
    -module-name FuzzContainer \
    "${sources[@]}" "${root}/Fuzz/Sources/FuzzContainer.swift" \
    -o "${work}/fuzz-container"

"${work}/fuzz-container" \
    -max_total_time="${seconds}" \
    -max_len=4096 \
    -print_final_stats=1 \
    -artifact_prefix="${work}/artifacts/" \
    "${work}/corpus" \
    "${root}/Tests/RasterWebPCoreTests/Fixtures"
