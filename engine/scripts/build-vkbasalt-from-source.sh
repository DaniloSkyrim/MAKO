#!/usr/bin/env bash
# Build MAKO's vkBasalt fork for native AArch64 from the exact commit recorded
# in engine/vkbasalt-release.json.
#
# The fork publishes only an x86 release asset. AArch64 packages therefore
# compile the same reviewed source on the target architecture instead of
# trusting an opaque binary. The produced archive mirrors the fork's release
# layout (64-bit only) and records its provenance so
# manage-vkbasalt-release.py --aarch64-source-archive can verify it against the
# pin before anything is staged.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine_root="$(cd "$script_dir/.." && pwd)"
pin_path="$engine_root/vkbasalt-release.json"
output_dir=""
source_dir=""

usage() {
    cat <<'USAGE'
Usage: build-vkbasalt-from-source.sh --output DIR [--pin FILE] [--source DIR]

Builds vkBasalt for native aarch64 from the pinned fork commit and writes
vkBasalt-<tag>-linux-aarch64.tar.xz into DIR. --source reuses an existing
checkout, which must already be at the pinned commit with a clean worktree.
USAGE
}

while (($#)); do
    case "$1" in
        --output) output_dir="${2:?--output needs a directory}"; shift 2 ;;
        --pin) pin_path="${2:?--pin needs a file}"; shift 2 ;;
        --source) source_dir="${2:?--source needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$output_dir" ]] || { usage >&2; exit 2; }

machine="$(uname -m)"
if [[ "$machine" != aarch64 && "$machine" != arm64 ]]; then
    echo "vkBasalt source builds run natively on aarch64; this host is $machine" >&2
    exit 1
fi

for command in git python3 meson ninja glslangValidator pkg-config readelf strip tar sha256sum xz od; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

pin_field() {
    python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$pin_path" "$1"
}
repository="$(pin_field repository)"
tag="$(pin_field tag)"
source_commit="$(pin_field source_commit)"
upstream_commit="$(pin_field upstream_commit)"
headers_revision="$(pin_field vulkan_headers_revision)"
headers_commit="$(pin_field vulkan_headers_commit)"
api_version="$(pin_field vulkan_api_version)"

renderer_headers="$(tr -d '[:space:]' < "$engine_root/vulkan-headers-revision.txt")"
if [[ "$headers_revision" != "$renderer_headers" ]]; then
    echo "vkBasalt pin uses Vulkan-Headers $headers_revision but the Renderer pins $renderer_headers" >&2
    exit 1
fi

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

if [[ -z "$source_dir" ]]; then
    source_dir="$work_root/vkbasalt"
    git init --quiet "$source_dir"
    git -C "$source_dir" remote add origin "https://github.com/$repository"
    git -C "$source_dir" fetch --quiet --depth=1 origin "refs/tags/$tag:refs/tags/$tag"
    git -C "$source_dir" checkout --quiet --detach "refs/tags/$tag"
fi
actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$source_commit" ]]; then
    echo "vkBasalt checkout is at $actual_commit; the pin requires $source_commit ($tag)" >&2
    exit 1
fi
if [[ -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
    echo "vkBasalt checkout has local modifications" >&2
    exit 1
fi
recorded_upstream="$(tr -d '[:space:]' < "$source_dir/packaging/UPSTREAM_BASE")"
if [[ "$recorded_upstream" != "$upstream_commit" ]]; then
    echo "vkBasalt UPSTREAM_BASE $recorded_upstream does not match the pin $upstream_commit" >&2
    exit 1
fi
fork_headers="$(tr -d '[:space:]' < "$source_dir/vulkan-headers-revision.txt")"
if [[ "$fork_headers" != "$headers_revision" ]]; then
    echo "vkBasalt source pins Vulkan-Headers $fork_headers; the release pin records $headers_revision" >&2
    exit 1
fi

git clone --quiet --depth=1 --branch "$headers_revision" \
    https://github.com/KhronosGroup/Vulkan-Headers "$work_root/vulkan-headers"
actual_headers_commit="$(git -C "$work_root/vulkan-headers" rev-parse HEAD)"
if [[ "$actual_headers_commit" != "$headers_commit" ]]; then
    echo "Vulkan-Headers $headers_revision resolved to $actual_headers_commit; the pin requires $headers_commit" >&2
    exit 1
fi

build="$work_root/build"
stage="$work_root/stage"
payload="$work_root/payload"
meson setup "$build" "$source_dir" \
    --buildtype=release \
    --prefix=/usr \
    --libdir=lib \
    -Dwith_json=false \
    -Dvulkan_headers="$work_root/vulkan-headers/include"
meson compile -C "$build" -j "${MAKO_BUILD_JOBS:-$(nproc)}"
meson test -C "$build" --print-errorlogs
DESTDIR="$stage" meson install -C "$build"

install -Dm755 "$stage/usr/lib/libvkbasalt.so" "$payload/lib/libvkbasalt.so"
install -Dm755 "$stage/usr/bin/mako-shader-tool" "$payload/bin/mako-shader-tool"
strip --strip-unneeded "$payload/lib/libvkbasalt.so" "$payload/bin/mako-shader-tool"
# The fork's 64-bit manifest template is architecture-neutral ("library_arch":
# "64", relative library path); only its file name names x86_64.
install -Dm644 "$build/packaging/vkBasalt.x86_64.json" \
    "$payload/share/vulkan/implicit_layer.d/vkBasalt.aarch64.json"
install -Dm644 "$source_dir/LICENSE" "$payload/share/doc/vkbasalt/LICENSE"
install -Dm644 "$source_dir/src/reshade/LICENSE.md" "$payload/share/doc/vkbasalt/RESHade-LICENSE.md"

built_api="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["layer"]["api_version"])' \
    "$payload/share/vulkan/implicit_layer.d/vkBasalt.aarch64.json")"
if [[ "$built_api" != "$api_version" ]]; then
    echo "Built vkBasalt declares Vulkan $built_api; the pin records $api_version" >&2
    exit 1
fi

verify_aarch64_elf() {
    local path="$1" class machine
    class="$(od -An -t u1 -j 4 -N 1 "$path" | tr -d '[:space:]')"
    machine="$(od -An -t u2 -j 18 -N 2 --endian=little "$path" | tr -d '[:space:]')"
    if [[ "$class" != 2 || "$machine" != 183 ]]; then
        echo "$path is not a 64-bit AArch64 ELF (class $class, machine $machine)" >&2
        exit 1
    fi
}
verify_aarch64_elf "$payload/lib/libvkbasalt.so"
verify_aarch64_elf "$payload/bin/mako-shader-tool"
readelf -Ws "$payload/lib/libvkbasalt.so" | grep -F vkBasalt_GetInstanceProcAddr >/dev/null || {
    echo "libvkbasalt.so does not export vkBasalt_GetInstanceProcAddr" >&2
    exit 1
}

printf '%s\n' \
    "repository=https://github.com/$repository" \
    "tag=$tag" \
    "commit=$source_commit" \
    "upstream_repository=https://github.com/DadSchoorse/vkBasalt" \
    "upstream_commit=$upstream_commit" \
    "vulkan_headers_revision=$headers_revision" \
    "vulkan_headers_commit=$headers_commit" \
    "vulkan_api_version=$api_version" \
    "architecture=aarch64" \
    "build=source" \
    > "$payload/share/doc/vkbasalt/SOURCE"

(
    cd "$payload"
    find bin lib share -type f -print | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    sha256sum --check --status SHA256SUMS
)

mkdir -p "$output_dir"
archive="$output_dir/vkBasalt-$tag-linux-aarch64.tar.xz"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C "$payload" -cJf "$archive" .
echo "Built $archive from $repository@$source_commit"
