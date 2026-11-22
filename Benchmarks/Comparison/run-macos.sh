#!/usr/bin/env bash
#
# Measures swift-raster-webp, libwebp and Apple's ImageIO natively on macOS, with the images that
# run-linux.sh encoded. Scripts/compare-decoders.sh runs it after the Linux run:
#
#   Benchmarks/Comparison/run-macos.sh <images-directory> <output-directory>
#
# Needs Swift and Homebrew's webp package. Builds go to a temporary directory that is removed.

set -euo pipefail

readonly images="${1:?usage: run-macos.sh <images> <output>}"
readonly raw="${2:?usage: run-macos.sh <images> <output>}/raw"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly corpus="${root}/.corpus/libwebp-test-data"
readonly comparison="${root}/Benchmarks/Comparison"
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

work="$(mktemp -d)"
readonly work
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "${raw}"
prefix="$(brew --prefix webp)"

log "Building the measuring programs"
swift build -c release --package-path "${comparison}/swift" --scratch-path "${work}/swift" > /dev/null
clang -O3 -o "${work}/libwebp-bench" "${comparison}/c/libwebp-bench.c" -I"${prefix}/include" \
    "${prefix}/lib/libwebp.a" "${prefix}/lib/libsharpyuv.a"

libraries=(
    "swift-raster-webp|${work}/swift/release/raster-bench"
    "libwebp|${work}/libwebp-bench"
    "imageio|${work}/swift/release/imageio-bench"
)
large=("${images}"/photo-*.webp)
small=("${images}"/small-*.webp)

# The peak resident memory, in KiB, of one run of a command.
peak_kb() {
    /usr/bin/time -l "$@" 2>&1 > /dev/null | awk '/maximum resident set size/ { print int($1 / 1024) }'
}

# Two rounds of speed measurements, as in run-linux.sh.
for round in 1 2; do
    for entry in "${libraries[@]}"; do
        id="${entry%%|*}"
        read -r -a command <<< "${entry#*|}"
        log "Measuring the speed of ${id}, round ${round}"
        "${command[@]}" speed 3 20 "${large[@]}" >> "${raw}/speed-${id}.jsonl"
        "${command[@]}" speed 100 1000 "${small[@]}" >> "${raw}/speed-${id}.jsonl"
    done
done

for entry in "${libraries[@]}"; do
    id="${entry%%|*}"
    read -r -a command <<< "${entry#*|}"
    log "Measuring the memory and pixels of ${id}"
    : > "${raw}/memory-${id}.tsv"
    for image in "${large[@]}"; do
        printf '%s\t%s\t%s\n' "$(basename "${image}")" "$(peak_kb "${command[@]}" decode "${image}")" \
            "$(peak_kb "${command[@]}" read "${image}")" >> "${raw}/memory-${id}.tsv"
    done
    "${command[@]}" hash "${corpus}"/*.webp > "${raw}/hash-corpus-${id}.tsv"
    "${command[@]}" hash "${images}"/*.webp > "${raw}/hash-images-${id}.tsv"
done

{
    printf 'machine\t%s\n' "$(sysctl -n machdep.cpu.brand_string)"
    printf 'architecture\t%s\n' "$(uname -m)"
    printf 'processors\t%s\n' "$(sysctl -n hw.ncpu)"
    printf 'os\tmacOS %s\n' "$(sw_vers -productVersion)"
    printf 'swift\t%s\n' "$(swift --version 2>&1 | grep -m1 -o 'Swift version [0-9.]*')"
    printf 'cc\t%s\n' "$(clang --version | head -1)"
    printf 'imageio-version\tmacOS %s\n' "$(sw_vers -productVersion)"
    printf 'date\t%s\n' "$(date -u +%Y-%m-%d)"
} > "${raw}/environment.tsv"
log "Done"
