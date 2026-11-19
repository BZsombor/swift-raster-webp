#!/usr/bin/env bash
#
# Builds and runs a fuzzer with libFuzzer and AddressSanitizer on Linux.
#
#   Fuzz/run.sh <container|decoder|vp8l> [seconds]
#
# On macOS, run it in a container:
#
#   docker run --rm -v "$PWD:/work:ro" -w /work swift:6.3-noble Fuzz/run.sh decoder 60

set -euo pipefail

readonly target="${1:?usage: Fuzz/run.sh <container|decoder|vp8l> [seconds]}"
readonly seconds="${2:-60}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly work="${FUZZ_WORK:-/tmp/raster-webp-fuzz}/${target}"

case "${target}" in
    container) harness="FuzzContainer" ;;
    decoder) harness="FuzzDecoder" ;;
    vp8l) harness="FuzzVP8L" ;;
    *) echo "Unknown fuzz target: ${target}" >&2; exit 2 ;;
esac

mkdir -p "${work}/corpus" "${work}/artifacts" "${work}/modules"

readonly flags=(-O -wmo -swift-version 6 -parse-as-library -package-name swift_raster_webp
    -sanitize=fuzzer,address -I "${work}/modules" -L "${work}/modules")

build_library() {
    local module="$1"
    local sources
    mapfile -t sources < <(find "${root}/Sources/${module}" -name '*.swift')
    swiftc "${flags[@]}" -module-name "${module}" -emit-library -static \
        -emit-module -emit-module-path "${work}/modules/${module}.swiftmodule" \
        "${sources[@]}" -o "${work}/modules/lib${module}.a"
}

build_library RasterWebPCore
build_library RasterWebPDecoder

swiftc "${flags[@]}" -module-name "${harness}" \
    "${root}/Fuzz/Sources/${harness}.swift" \
    -lRasterWebPDecoder -lRasterWebPCore \
    -o "${work}/fuzzer"

"${work}/fuzzer" \
    -max_total_time="${seconds}" \
    -max_len=65536 \
    -timeout=30 \
    -print_final_stats=1 \
    -artifact_prefix="${work}/artifacts/" \
    "${work}/corpus" \
    "${root}/Tests/RasterWebPCoreTests/Fixtures" \
    "${root}/Tests/RasterWebPDecoderTests/Fixtures"
