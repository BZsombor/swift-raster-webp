#!/usr/bin/env bash
#
# Runs the decoder comparison inside a Linux container. Scripts/compare-decoders.sh starts it as
#
#   docker run --rm -v <repository>:/src/swift-raster-webp:ro -v <output>:/out swift:6.3-noble \
#       /src/swift-raster-webp/Benchmarks/Comparison/run-linux.sh
#
# Everything it installs and builds stays inside the container, which is removed afterward.
# The raw measurements are written to /out/raw.

set -euo pipefail

readonly repository=/src/swift-raster-webp
readonly work=/work
readonly raw=/out/raw
readonly corpus="${repository}/.corpus/libwebp-test-data"
mkdir -p "${work}" "${raw}"
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

case "$(uname -m)" in
    aarch64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
esac

# --- Toolchains --------------------------------------------------------------------------------

log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends make cmake time python3 curl ca-certificates \
    openjdk-21-jdk-headless maven > /dev/null
# C code is compiled with the clang of the Swift toolchain, as on macOS.
export CC=clang

log "Building libwebp 1.6.0"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch v1.6.0 https://chromium.googlesource.com/webm/libwebp "${work}/libwebp"
cmake -S "${work}/libwebp" -B "${work}/libwebp/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${work}/prefix" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF > /dev/null
cmake --build "${work}/libwebp/build" --parallel > /dev/null
cmake --install "${work}/libwebp/build" > /dev/null
export PATH="${work}/prefix/bin:${PATH}"

log "Installing Rust"
export RUSTUP_HOME="${work}/rustup" CARGO_HOME="${work}/cargo"
curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain stable > /dev/null
export PATH="${CARGO_HOME}/bin:${PATH}"
# Rust links with clang too, because the image has no other C compiler.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang

log "Installing Go"
go_version="$(curl -sSf 'https://go.dev/VERSION?m=text' | head -1)"
curl -sSfL "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" | tar -xz -C "${work}"
export PATH="${work}/go/bin:${PATH}" GOPATH="${work}/gopath" GOCACHE="${work}/gocache" GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod CGO_ENABLED=0

log "Installing .NET"
curl -sSfL https://dot.net/v1/dotnet-install.sh -o "${work}/dotnet-install.sh"
bash "${work}/dotnet-install.sh" --channel 10.0 --install-dir "${work}/dotnet" > /dev/null
export PATH="${work}/dotnet:${PATH}" DOTNET_ROOT="${work}/dotnet" DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 NUGET_PACKAGES="${work}/nuget"

# --- Test images -------------------------------------------------------------------------------

log "Encoding the test images"
images="${work}/images"
mkdir -p "${images}"
dwebp -quiet "${corpus}/bryce.webp" -pam -o "${work}/photo.pam"
# The same photo with a smooth alpha ramp across its width and opaque bands every 500 columns.
python3 - "${work}/photo.pam" "${work}/photo-alpha.pam" <<'PY'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
end = data.index(b'ENDHDR\n') + 7
width = int(data[:end].split(b'WIDTH ')[1].split()[0])
pixels = memoryview(data)[end:]
for x in range(width):
    alpha = 255 if (x // 500) % 3 == 0 else x * 255 // (width - 1)
    column = pixels[x * 4 + 3::width * 4]
    column[:] = bytes([alpha]) * len(column)
open(sys.argv[2], 'wb').write(data)
PY
cwebp -quiet -q 75 -m 4 "${work}/photo.pam" -o "${images}/photo-q75.webp"
cwebp -quiet -q 90 -m 4 "${work}/photo.pam" -o "${images}/photo-q90.webp"
cwebp -quiet -q 75 -m 4 "${work}/photo-alpha.pam" -o "${images}/photo-alpha.webp"
cwebp -quiet -lossless -z 6 "${work}/photo.pam" -o "${images}/photo-lossless.webp"
cwebp -quiet -crop 4000 900 256 256 -q 75 -m 4 "${work}/photo.pam" -o "${images}/small-q75.webp"
cwebp -quiet -crop 4000 900 256 256 -lossless -z 6 "${work}/photo.pam" -o "${images}/small-lossless.webp"
# The macOS run measures the same files.
cp -R "${images}" /out/images
readonly large=("${images}"/photo-*.webp)
readonly small=("${images}"/small-*.webp)

# --- Measuring programs ------------------------------------------------------------------------

log "Building the measuring programs"
# A writable copy of the repository, without build products from the host.
mkdir -p "${work}/src/swift-raster-webp"
tar -C "${repository}" --exclude=./.build --exclude=./.corpus --exclude='*/.build' \
    --exclude='./Benchmarks/Comparison/*/target' -cf - . | tar -C "${work}/src/swift-raster-webp" -xf -
comparison="${work}/src/swift-raster-webp/Benchmarks/Comparison"
bin="${work}/bin"
mkdir -p "${bin}"

swift build -c release --package-path "${comparison}/swift" --scratch-path "${work}/swift" \
    --product raster-bench > /dev/null
cp "${work}/swift/release/raster-bench" "${bin}/"

clang -O3 -o "${bin}/libwebp-bench" "${comparison}/c/libwebp-bench.c" -I"${work}/prefix/include" \
    "${work}/prefix/lib/libwebp.a" "${work}/prefix/lib/libsharpyuv.a" -lm -lpthread

for crate in image-webp zenwebp; do
    cargo build --quiet --release --locked --manifest-path "${comparison}/rust-${crate}/Cargo.toml" \
        --target-dir "${work}/rust-${crate}"
    cp "${work}/rust-${crate}/release/${crate}-bench" "${bin}/"
done

(cd "${comparison}/go" && [[ -f go.sum ]] || go mod tidy)
cp "${comparison}/go/go.sum" "${raw}/go.sum"
(cd "${comparison}/go" && go build -trimpath -o "${bin}/go-bench" ./bench)

dotnet publish "${comparison}/dotnet/Bench.csproj" -c Release -o "${work}/dotnet-bench" --nologo -v quiet > /dev/null
cp "${comparison}/dotnet/packages.lock.json" "${raw}/packages.lock.json"

(cd "${comparison}/java" && mvn -q -B -Dmaven.repo.local="${work}/m2" package -DskipTests)
java_classpath="${comparison}/java/target/java-bench-1.jar:$(ls "${comparison}"/java/target/lib/*.jar | tr '\n' ':')"

# Each line: identifier, then the command that runs the program.
libraries=(
    "swift-raster-webp|${bin}/raster-bench"
    "libwebp|${bin}/libwebp-bench"
    "image-webp|${bin}/image-webp-bench"
    "zenwebp|${bin}/zenwebp-bench"
    "x-image-webp|${bin}/go-bench"
    "imagesharp|dotnet ${work}/dotnet-bench/Bench.dll"
    "twelvemonkeys|java -cp ${java_classpath} bench.Bench twelvemonkeys"
    "jwebp|java -cp ${java_classpath} bench.Bench jwebp"
)

# --- Measurements ------------------------------------------------------------------------------

# Speed is measured in two rounds over all libraries, so that a short disturbance of the machine
# affects at most one round of one library. collect.py keeps the better round.
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

    # Peak memory of one decode, and of the same program that only reads the file.
    : > "${raw}/memory-${id}.tsv"
    for image in "${large[@]}"; do
        decode_kb="$(/usr/bin/time -f %M "${command[@]}" decode "${image}" 2>&1 > /dev/null | tail -1)"
        read_kb="$(/usr/bin/time -f %M "${command[@]}" read "${image}" 2>&1 > /dev/null | tail -1)"
        printf '%s\t%s\t%s\n' "$(basename "${image}")" "${decode_kb}" "${read_kb}" >> "${raw}/memory-${id}.tsv"
    done

    "${command[@]}" hash "${corpus}"/*.webp > "${raw}/hash-corpus-${id}.tsv"
    "${command[@]}" hash "${images}"/*.webp > "${raw}/hash-images-${id}.tsv"
done

# --- Binary sizes ------------------------------------------------------------------------------

log "Measuring binary sizes"
sizes="${work}/sizes"
mkdir -p "${sizes}"
swift build -c release --static-swift-stdlib --package-path "${comparison}/swift" --scratch-path "${work}/swift-static" \
    --product size-empty > /dev/null
swift build -c release --static-swift-stdlib --package-path "${comparison}/swift" --scratch-path "${work}/swift-static" \
    --product size-decode > /dev/null
cp "${work}/swift-static/release/size-empty" "${sizes}/swift-raster-webp-empty"
cp "${work}/swift-static/release/size-decode" "${sizes}/swift-raster-webp-decode"
clang -O2 -static -o "${sizes}/libwebp-empty" "${comparison}/c/size-empty.c"
clang -O2 -static -o "${sizes}/libwebp-decode" "${comparison}/c/size-decode.c" -I"${work}/prefix/include" \
    "${work}/prefix/lib/libwebp.a" "${work}/prefix/lib/libsharpyuv.a" -lm -lpthread
for crate in image-webp zenwebp; do
    cargo build --quiet --release --locked --manifest-path "${comparison}/rust-${crate}/Cargo.toml" \
        --target-dir "${work}/rust-${crate}" --bins
    cp "${work}/rust-${crate}/release/size-empty" "${sizes}/${crate}-empty"
    cp "${work}/rust-${crate}/release/size-decode" "${sizes}/${crate}-decode"
done
(cd "${comparison}/go" && go build -trimpath -o "${sizes}/x-image-webp-empty" ./size-empty \
    && go build -trimpath -o "${sizes}/x-image-webp-decode" ./size-decode)
strip "${sizes}"/*
: > "${raw}/size.tsv"
for id in swift-raster-webp libwebp image-webp zenwebp x-image-webp; do
    printf '%s\t%s\t%s\n' "${id}" "$(stat -c %s "${sizes}/${id}-empty")" "$(stat -c %s "${sizes}/${id}-decode")" >> "${raw}/size.tsv"
done

# --- Environment -------------------------------------------------------------------------------

{
    printf 'architecture\t%s\n' "$(uname -m)"
    printf 'processors\t%s\n' "$(nproc)"
    printf 'os\t%s\n' "$(. /etc/os-release && echo "${PRETTY_NAME}")"
    printf 'swift\t%s\n' "$(swift --version 2>&1 | head -1)"
    printf 'cc\t%s\n' "$(clang --version | head -1)"
    printf 'rust\t%s\n' "$(rustc --version)"
    printf 'go\t%s\n' "$(go version)"
    printf 'dotnet\t%s\n' "$(dotnet --version)"
    printf 'java\t%s\n' "$(java -version 2>&1 | head -1)"
    printf 'date\t%s\n' "$(date -u +%Y-%m-%d)"
} > "${raw}/environment.tsv"
log "Done"
