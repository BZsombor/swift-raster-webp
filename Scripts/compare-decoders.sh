#!/usr/bin/env bash
#
# Compares this package with other WebP decoders and redraws the charts.
#
#   Scripts/fetch-corpus.sh
#   Scripts/compare-decoders.sh [--skip-macos]
#
# The Linux run needs Docker. It installs every toolchain inside a swift:6.3-noble container that
# is removed afterward. The macOS run also needs Swift and Homebrew's webp package. Temporary files
# are removed at the end, so only the results and the charts in docs/performance remain.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly comparison="${root}/Benchmarks/Comparison"
readonly results="${root}/docs/performance/results"
readonly container=raster-webp-comparison

if [[ "$(basename "${root}")" != swift-raster-webp ]]; then
    echo "The repository must be checked out in a directory named swift-raster-webp" >&2
    exit 1
fi
if [[ ! -f "${root}/.corpus/libwebp-test-data/bryce.webp" ]]; then
    echo "Run Scripts/fetch-corpus.sh first" >&2
    exit 1
fi
command -v docker > /dev/null || { echo "Missing docker" >&2; exit 1; }

measure_macos=true
[[ "${1:-}" == --skip-macos || "$(uname)" != Darwin ]] && measure_macos=false

work="$(mktemp -d)"
readonly work
cleanup() {
    docker rm -f "${container}" > /dev/null 2>&1 || true
    rm -rf "${work:?}"
}
trap cleanup EXIT

# The latest tag when the library's sources have not changed since it, otherwise the commit.
version="$(git -C "${root}" describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "${version}" ]] || ! git -C "${root}" diff --quiet "${version}" -- Sources Package.swift; then
    version="$(git -C "${root}" describe --tags --always --dirty)"
fi
machine="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu | sed -n 's/^Model name: *//p' | head -1)"

echo "Measuring in a Linux container, which takes about half an hour" >&2
mkdir -p "${work}/linux"
docker run --rm --name "${container}" -v "${root}:/src/swift-raster-webp:ro" -v "${work}/linux:/out" \
    swift:6.3-noble /src/swift-raster-webp/Benchmarks/Comparison/run-linux.sh
# The container resolves the Go and .NET dependencies when their lock files are missing.
for lock in go/go.sum dotnet/packages.lock.json; do
    [[ -f "${comparison}/${lock}" ]] || cp "${work}/linux/raw/$(basename "${lock}")" "${comparison}/${lock}"
done
architecture="$(sed -n 's/^architecture\t//p' "${work}/linux/raw/environment.tsv")"
printf 'machine\t%s, Docker\nswift-raster-webp-version\t%s\n' "${machine}" "${version}" \
    >> "${work}/linux/raw/environment.tsv"
mkdir -p "${results}"
python3 -I "${comparison}/collect.py" "${work}/linux/raw" linux "${results}/linux-${architecture}.json"

render=("${results}/linux-${architecture}.json")
if [[ "${measure_macos}" == true ]]; then
    echo "Measuring natively on macOS" >&2
    "${comparison}/run-macos.sh" "${work}/linux/images" "${work}/macos"
    printf 'swift-raster-webp-version\t%s\n' "${version}" >> "${work}/macos/raw/environment.tsv"
    python3 -I "${comparison}/collect.py" "${work}/macos/raw" macos "${results}/macos.json"
    render+=("${results}/macos.json")
fi

python3 -I "${comparison}/render.py" "${render[@]}"
echo "Updated docs/performance/comparison.md and its charts" >&2
