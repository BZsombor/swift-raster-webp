#!/usr/bin/env bash
#
# Downloads the libwebp conformance corpus at a pinned commit into .corpus/.
# The corpus is not redistributed with this repository.

set -euo pipefail

readonly repository="https://chromium.googlesource.com/webm/libwebp-test-data"
readonly commit="06ddd96e276c2c638a72d39d3c0f340afd61978c"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly destination="${root}/.corpus/libwebp-test-data"

if [[ ! -d "${destination}/.git" ]]; then
    mkdir -p "$(dirname "${destination}")"
    git clone --quiet "${repository}" "${destination}"
fi

if [[ "$(git -C "${destination}" rev-parse HEAD)" != "${commit}" ]]; then
    git -C "${destination}" fetch --quiet origin
    git -C "${destination}" checkout --quiet --detach "${commit}"
fi

echo "Corpus ready at ${destination} (${commit})"
