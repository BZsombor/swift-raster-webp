#!/usr/bin/env bash
#
# Compares the decoding speed of this package with libwebp and the Rust image-webp crate.
#
#   Scripts/fetch-corpus.sh
#   Scripts/compare-decoders.sh
#
# Needs swift, cargo, cwebp and dwebp. The test images, the Rust build and its downloaded
# crates live in a temporary directory that is removed at the end, so the script leaves
# nothing behind except the usual Tools/.build directory.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly source="${root}/.corpus/libwebp-test-data/bryce.webp"

if [[ ! -f "${source}" ]]; then
    echo "Run Scripts/fetch-corpus.sh first" >&2
    exit 1
fi
for tool in swift cargo cwebp dwebp; do
    command -v "${tool}" > /dev/null || { echo "Missing ${tool}" >&2; exit 1; }
done

work="$(mktemp -d)"
readonly work
trap 'rm -rf "${work:?}"' EXIT

# The 24 Mpx photo of the corpus, encoded as a typical web image, a high-quality one and a
# lossless one.
dwebp -quiet "${source}" -pam -o "${work}/bryce.pam"
cwebp -quiet -q 75 -m 4 "${work}/bryce.pam" -o "${work}/lossy_q75.webp"
cwebp -quiet -q 90 -m 4 "${work}/bryce.pam" -o "${work}/lossy_q90.webp"
cwebp -quiet -lossless -z 6 "${work}/bryce.pam" -o "${work}/lossless.webp"
readonly images=("${work}/lossy_q75.webp" "${work}/lossy_q90.webp" "${work}/lossless.webp")

echo "Building the decoders" >&2
swift build -c release --package-path "${root}/Tools" > /dev/null
CARGO_HOME="${work}/cargo" CARGO_TARGET_DIR="${work}/target" \
    cargo build --quiet --release --locked --manifest-path "${root}/Scripts/image-webp-bench/Cargo.toml"

echo "Measuring" >&2
swift_results="$("${root}/Tools/.build/release/webp-tools" speed "${images[@]}")"
rust_results="$("${work}/target/release/image-webp-bench" "${images[@]}")"

# Each line reads "name: N Mpx/s", followed by "dwebp N Mpx/s" for this package's tool.
speed() { grep "^$1:" <<< "$2" | sed -E "s/^[^:]*: ([0-9]+) Mpx\/s.*/\1/"; }
reference() { grep "^$1:" <<< "${swift_results}" | sed -E 's/.*dwebp ([0-9]+) Mpx\/s.*/\1/'; }

echo
echo "| Image | swift-raster-webp | image-webp | libwebp |"
echo "|---|---:|---:|---:|"
for image in "${images[@]}"; do
    name="$(basename "${image}")"
    echo "| ${name%.webp} | $(speed "${name}" "${swift_results}") Mpx/s" \
        "| $(speed "${name}" "${rust_results}") Mpx/s | $(reference "${name}") Mpx/s |"
done
