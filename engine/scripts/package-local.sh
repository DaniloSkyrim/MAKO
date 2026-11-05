#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
monorepo_root="$(cd "$repo_root/.." && pwd)"
build_cache_root="${MAKO_BUILD_CACHE_ROOT:-$repo_root/build/cache}"
build_work_root="${MAKO_BUILD_WORK_ROOT:-$repo_root/build/work}"
if [[ "$build_cache_root" != /* ]]; then
    build_cache_root="$repo_root/$build_cache_root"
fi
if [[ "$build_work_root" != /* ]]; then
    build_work_root="$repo_root/$build_work_root"
fi
local_vkbasalt_archive="${MAKO_VKBASALT_LOCAL_ARCHIVE:-}"
if [[ -n "$local_vkbasalt_archive" ]]; then
    if [[ "$local_vkbasalt_archive" == /* || "$local_vkbasalt_archive" == *..* || ! -f "$monorepo_root/$local_vkbasalt_archive" ]]; then
        echo "MAKO_VKBASALT_LOCAL_ARCHIVE must be an existing repository-relative archive." >&2
        exit 1
    fi
fi
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
output_path=""
build_32_bit=true
host_arch=""

usage() {
    cat <<'EOF'
Usage: scripts/package-local.sh [--64-bit-only] [--host-arch x86_64|aarch64] [output-path]

Build and verify a local Linux engine archive. --64-bit-only omits the 32-bit
layer and manifest for faster native 64-bit Deck/Steam Machine test builds.
--host-arch selects the package architecture. Native Linux builds must match
`uname -m`; containerized builds select the matching linux/amd64 or
linux/arm64 builder. AArch64 packages are always 64-bit only and compile the
pinned vkBasalt fork from source.
EOF
}

normalize_host_arch() {
    case "$1" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        *) return 1 ;;
    esac
}

while (($#)); do
    case "$1" in
        --64-bit-only)
            build_32_bit=false
            ;;
        --host-arch)
            if (($# < 2)) || ! host_arch="$(normalize_host_arch "$2")"; then
                echo "--host-arch must be x86_64 or aarch64" >&2
                exit 2
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$output_path" ]]; then
                echo "Only one output path may be specified" >&2
                exit 2
            fi
            output_path="$1"
            ;;
    esac
    shift
done

containerized_build="${MAKO_PACKAGE_CONTAINERIZED:-0}"
if [[ -z "$host_arch" ]]; then
    if [[ "$(uname -s)" == "Linux" ]] && host_arch="$(normalize_host_arch "$(uname -m)")"; then
        :
    else
        host_arch=x86_64
    fi
fi
if [[ "$(uname -s)" == "Linux" && ( "$containerized_build" == "1" || "${MAKO_PORTABLE_PACKAGE:-0}" != "1" ) ]]; then
    native_arch="$(normalize_host_arch "$(uname -m)" || uname -m)"
    if [[ "$native_arch" != "$host_arch" ]]; then
        echo "Native packaging builds for $native_arch, but --host-arch is $host_arch." >&2
        echo "Cross-compiled Vulkan layers are not packaged; set MAKO_PORTABLE_PACKAGE=1 to use a $host_arch container." >&2
        exit 1
    fi
fi
if [[ "$host_arch" == aarch64 ]]; then
    # AArch64 Vulkan applications are 64-bit only: Steam's ARM Proton runs
    # wine-arm64, and x86 Linux games reach the host loader through FEX thunks.
    build_32_bit=false
    if [[ -n "$local_vkbasalt_archive" ]]; then
        echo "MAKO_VKBASALT_LOCAL_ARCHIVE is an x86 release candidate; AArch64 builds compile vkBasalt from its pinned source." >&2
        exit 1
    fi
    default_output="$repo_root/out/MAKO-Renderer-v$version-linux-aarch64.tar.xz"
else
    default_output="$repo_root/out/MAKO-Renderer-v$version-linux.tar.xz"
fi
output_path="${output_path:-$default_output}"

if [[ "$output_path" != /* ]]; then
    output_path="$PWD/$output_path"
fi

if [[ -z "$version" ]]; then
    echo "VERSION must contain a release version." >&2
    exit 1
fi

vulkan_headers_revision="$(< "$repo_root/vulkan-headers-revision.txt")"
if [[ ! "$vulkan_headers_revision" =~ ^(vulkan-sdk-|v)[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "vulkan-headers-revision.txt must contain a Vulkan-Headers SDK branch (vulkan-sdk-X.Y.Z) or release tag (vX.Y.Z)." >&2
    exit 1
fi

portable_container="${MAKO_PORTABLE_PACKAGE:-0}"
if [[ "$containerized_build" != "1" && ( "$(uname -s)" != "Linux" || "$portable_container" == "1" ) ]]; then
    container_runtime=""
    if command -v docker >/dev/null 2>&1; then
        container_runtime="docker"
    elif command -v podman >/dev/null 2>&1; then
        container_runtime="podman"
    else
        echo "Portable packaging needs Docker or Podman. Install one and try again." >&2
        exit 1
    fi

    case "$output_path" in
        "$repo_root"/*)
            output_relative="${output_path#"$repo_root"/}"
            ;;
        *)
            echo "For a containerized build, the output path must be inside this repository." >&2
            exit 1
            ;;
    esac

    if [[ "$host_arch" == aarch64 ]]; then
        container_platform=linux/arm64
        # vkBasalt is compiled from its pinned source on AArch64; the x86
        # builder instead downloads the verified release asset.
        container_toolchain="gcc g++ meson glslang-tools libx11-dev spirv-headers xz-utils"
    else
        container_platform=linux/amd64
        container_toolchain="g++-multilib"
    fi
    echo "Using local $container_platform $container_runtime packaging environment..."
    docker_64_only=0
    if [[ "$build_32_bit" == false ]]; then
        docker_64_only=1
    fi
    exec "$container_runtime" run --rm --platform "$container_platform" \
        -e MAKO_PACKAGE_64_ONLY="$docker_64_only" \
        -e MAKO_PACKAGE_HOST_ARCH="$host_arch" \
        -e MAKO_PACKAGE_TOOLCHAIN="$container_toolchain" \
        -e MAKO_PACKAGE_CONTAINERIZED=1 \
        -e MAKO_VULKAN_HEADERS_REVISION="$vulkan_headers_revision" \
        -e MAKO_RELEASE_SKIP_TESTS="${MAKO_RELEASE_SKIP_TESTS:-0}" \
        -e MAKO_VKBASALT_LOCAL_ARCHIVE="$local_vkbasalt_archive" \
        -v "$monorepo_root:/workspace" \
        -w /workspace/engine \
        ubuntu:22.04 \
        bash -lc '
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            sed -i "s|http://|https://|g" /etc/apt/sources.list
            # Minimal Ubuntu images do not contain a CA bundle. APT still
            # verifies signed Ubuntu repository metadata during this one-time
            # TLS bootstrap; subsequent downloads use normal certificate checks.
            if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
                apt-get -o Acquire::https::Verify-Peer=false update -qq
                apt-get -o Acquire::https::Verify-Peer=false install -y -qq ca-certificates
            fi
            apt-get update -qq
            apt-get install -y -qq \
                git curl nodejs python3 llvm clang cmake ninja-build pkg-config $MAKO_PACKAGE_TOOLCHAIN \
                libvulkan-dev mesa-common-dev \
                qt6-base-dev qt6-base-dev-tools \
                qt6-tools-dev qt6-tools-dev-tools \
                qt6-declarative-dev qt6-declarative-dev-tools \
                qml6-module-qtqml qml6-module-qtqml-models qml6-module-qtqml-workerscript \
                qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
                qml6-module-qtquick-templates qml6-module-qtquick-window
            git clone --depth=1 -b "$MAKO_VULKAN_HEADERS_REVISION" \
                https://github.com/KhronosGroup/Vulkan-Headers /tmp/vkh
            rm -rf /usr/include/vulkan /usr/include/vk_video
            cp -a /tmp/vkh/include/vulkan /tmp/vkh/include/vk_video /usr/include/
            package_args=(--host-arch "$MAKO_PACKAGE_HOST_ARCH")
            if [[ "${MAKO_PACKAGE_64_ONLY:-0}" == "1" ]]; then
                package_args+=(--64-bit-only)
            fi
            scripts/package-local.sh "${package_args[@]}" "/workspace/engine/'"$output_relative"'"
        '
fi

for command in cmake ninja clang++ nm python3 readelf strings tar sha256sum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

has_usable_qt_prefix() {
    local prefix="$1"
    local qt_config
    local qt_header
    local gl_header
    local opengl_library
    qt_config="$(find "$prefix/lib" -path '*/cmake/Qt6/Qt6Config.cmake' -print -quit 2>/dev/null)"
    qt_header="$(find "$prefix/include" -path '*/qt6/QtCore/QtCore' -print -quit 2>/dev/null)"
    gl_header="$(find "$prefix/include" -path '*/GL/gl.h' -print -quit 2>/dev/null)"
    opengl_library="$(find "$prefix/lib" -name 'libOpenGL.so' -print -quit 2>/dev/null)"
    [[ -n "$qt_config" && -n "$qt_header" && -n "$gl_header" && -n "$opengl_library" ]]
}

bootstrap_native_qt_sdk() {
    local prefix_list="/usr"
    local candidate_prefix
    local configured_prefixes
    local -a prefix_candidates=()

    if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
        configured_prefixes="${CMAKE_PREFIX_PATH//;/:}"
        IFS=':' read -r -a prefix_candidates <<< "$configured_prefixes"
        for candidate_prefix in "${prefix_candidates[@]}"; do
            if [[ -n "$candidate_prefix" ]] && has_usable_qt_prefix "${candidate_prefix%/}"; then
                return
            fi
        done
    fi
    if has_usable_qt_prefix "$prefix_list"; then
        return
    fi

    for command in pacman curl bsdtar; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "MAKO's release UI needs Qt 6 development files, but $command is unavailable." >&2
            echo "Install the Qt development packages, or run the package script on a Pacman-based SteamOS host." >&2
            exit 1
        fi
    done

    local sdk_cache_dir="${MAKO_NATIVE_SDK_DIR:-$build_cache_root/native-sdk}"
    if [[ "$sdk_cache_dir" != /* ]]; then
        sdk_cache_dir="$repo_root/$sdk_cache_dir"
    fi
    local package_cache_dir="$sdk_cache_dir/packages"
    local package_urls
    if ! package_urls="$(pacman -Sp qt6-base qt6-declarative libglvnd)"; then
        echo "Could not resolve the SteamOS packages needed for MAKO's native Qt SDK." >&2
        exit 1
    fi

    local -a package_names=(qt6-base qt6-declarative libglvnd)
    local -a package_files=()
    local package_name
    local package_url
    local package_file
    local -A package_sources=()
    while IFS= read -r package_url; do
        package_file="${package_url##*/}"
        for package_name in "${package_names[@]}"; do
            if [[ "$package_file" == "$package_name"-*.pkg.tar.* ]]; then
                package_sources["$package_name"]="$package_url"
            fi
        done
    done <<< "$package_urls"

    for package_name in "${package_names[@]}"; do
        package_url="${package_sources[$package_name]:-}"
        if [[ -z "$package_url" ]]; then
            echo "Pacman did not provide a download URL for $package_name." >&2
            exit 1
        fi
        package_file="${package_url##*/}"
        package_files+=("$package_file")
        mkdir -p "$package_cache_dir"
        if [[ ! -s "$package_cache_dir/$package_file" ]]; then
            echo "Caching $package_name for MAKO's native release builds..."
            curl --fail --location --retry 3 \
                --output "$package_cache_dir/$package_file.part" \
                "$package_url"
            mv "$package_cache_dir/$package_file.part" "$package_cache_dir/$package_file"
        fi
    done

    local sdk_key
    sdk_key="$(printf '%s\n' "${package_files[@]}" | sha256sum | awk '{print substr($1, 1, 16)}')"
    local sdk_root="$sdk_cache_dir/$sdk_key"
    if [[ ! -f "$sdk_root/.ready" ]]; then
        echo "Preparing isolated native Qt SDK at $sdk_root..."
        mkdir -p "$sdk_root"
        for package_file in "${package_files[@]}"; do
            bsdtar -xf "$package_cache_dir/$package_file" -C "$sdk_root"
        done
        touch "$sdk_root/.ready"
    fi

    local sdk_prefix="$sdk_root/usr"
    if ! has_usable_qt_prefix "$sdk_prefix"; then
        echo "The cached MAKO native Qt SDK is incomplete: $sdk_root" >&2
        echo "Remove that SDK directory and run the package command again." >&2
        exit 1
    fi

    export CMAKE_PREFIX_PATH="$sdk_prefix${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    echo "Using cached isolated native Qt SDK: $sdk_prefix"
}

bootstrap_native_qt_sdk

mkdir -p "$build_work_root"
build_root="$(mktemp -d "$build_work_root/mako-package.XXXXXX")"
cleanup() {
    rm -rf "$build_root"
}
trap cleanup EXIT

build64_dir="$build_root/build64"
build32_dir="$build_root/build32"
install_dir="$build_root/target"
mkdir -p "$(dirname "$output_path")"

build_testing=ON
if [[ "${MAKO_RELEASE_SKIP_TESTS:-0}" == "1" ]]; then
    build_testing=OFF
    echo "Automated tests skipped by maintainer request; package verification remains enabled."
fi
cmake -S "$repo_root" -B "$build64_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTING="$build_testing" \
    -DMAKO_REQUIRE_NATIVE_PACKAGE_HEADERS=ON \
    -DMAKO_BUILD_VK_LAYER=ON \
    -DMAKO_BUILD_UI=ON \
    -DMAKO_BUILD_CLI=ON \
    -DMAKO_INSTALL_XDG_FILES=ON \
    -DMAKO_LAYER_LIBRARY_PATH="../../../lib/libmako-render.so" \
    -DMAKO_SCALING_LAYER_LIBRARY_PATH="../../../lib/libmako-render-scaling.so"

# Build the complete configured tree before CTest so CMake remains the single
# authority for every registered test executable and production dependency.
cmake --build "$build64_dir"
if [[ "${MAKO_RELEASE_SKIP_TESTS:-0}" != "1" ]]; then
    ctest --test-dir "$build64_dir" --output-on-failure
fi
# Release archives do not need local symbol tables. CMake's install-time strip
# preserves the dynamic entrypoints required by the Vulkan loader while
# keeping both the installed payload and compressed archive smaller.
cmake --install "$build64_dir" --strip

if [[ "$build_32_bit" == true ]]; then
    # A Vulkan layer is loaded into the application's process. Release archives
    # retain the second copy for genuine 32-bit games; local 64-bit-only builds
    # skip it to shorten the edit/test cycle.
    cmake -S "$repo_root" -B "$build32_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_CXX_FLAGS=-m32 \
        -DCMAKE_SHARED_LINKER_FLAGS=-m32 \
        -DCMAKE_INSTALL_LIBDIR=lib32 \
        -DBUILD_TESTING=OFF \
        -DMAKO_REQUIRE_NATIVE_PACKAGE_HEADERS=ON \
        -DMAKO_BUILD_VK_LAYER=ON \
        -DMAKO_BUILD_UI=OFF \
        -DMAKO_BUILD_CLI=OFF \
        -DMAKO_INSTALL_XDG_FILES=OFF \
        -DMAKO_LAYER_MANIFEST_SUFFIX=.x86 \
        -DMAKO_LAYER_LIBRARY_PATH="../../../lib32/libmako-render.so" \
        -DMAKO_SCALING_LAYER_LIBRARY_PATH="../../../lib32/libmako-render-scaling.so"

    cmake --build "$build32_dir" --target mako-render mako-render-scaling
    cmake --install "$build32_dir" --strip
fi

vkbasalt_stage_args=(
    --stage-native "$install_dir"
    --cache-dir "$build_cache_root/vkbasalt"
)
if [[ "$build_32_bit" == false ]]; then
    vkbasalt_stage_args+=(--64-bit-only)
fi
if [[ "$host_arch" == aarch64 ]]; then
    # Compile the exact pinned fork commit once per commit and reuse it. The
    # cached archive is revalidated against the pin on every staging run.
    vkbasalt_source_commit="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' \
        "$repo_root/vkbasalt-release.json")"
    vkbasalt_source_cache="$build_cache_root/vkbasalt-aarch64/$vkbasalt_source_commit"
    vkbasalt_source_archive="$(find "$vkbasalt_source_cache" -maxdepth 1 -name 'vkBasalt-*-linux-aarch64.tar.xz' -print -quit 2>/dev/null || true)"
    if [[ -z "$vkbasalt_source_archive" ]]; then
        bash "$repo_root/scripts/build-vkbasalt-from-source.sh" --output "$vkbasalt_source_cache"
        vkbasalt_source_archive="$(find "$vkbasalt_source_cache" -maxdepth 1 -name 'vkBasalt-*-linux-aarch64.tar.xz' -print -quit)"
    fi
    vkbasalt_stage_args+=(--aarch64-source-archive "$vkbasalt_source_archive")
elif [[ -n "$local_vkbasalt_archive" ]]; then
    vkbasalt_stage_args+=(--local-archive "$monorepo_root/$local_vkbasalt_archive")
fi
python3 "$repo_root/scripts/manage-vkbasalt-release.py" \
    "${vkbasalt_stage_args[@]}"

required_paths=(
    "bin/mako-cli" \
    "bin/mako-diagnostics" \
    "bin/mako-installer" \
    "bin/mako-launch" \
    "bin/mako-remote-play" \
    "share/mako-render/host-architecture" \
    "share/mako-render/mako_remote_play/__init__.py" \
    "share/mako-render/mako_remote_play/remote_play_core.py" \
    "share/mako-render/mako_remote_play/remote_play_launch.py" \
    "share/mako-render/mako_remote_play/managed_files.py" \
    "bin/mako-vrr-lease" \
    "bin/mako-ui" \
    "lib/libmako-render.so" \
    "lib/libmako-render-scaling.so" \
    "lib/vkbasalt/libvkbasalt.so" \
    "share/doc/mako-render/ASSET_PROVENANCE.md" \
    "share/doc/mako-render/LICENSE.md" \
    "share/doc/mako-render/THIRD_PARTY_NOTICES.md" \
    "share/applications/io.github.eugeniosegala.mako.desktop" \
    "share/applications/io.github.eugeniosegala.mako.uninstaller.desktop" \
    "share/mako-render/vulkan/implicit_layer.d/VkLayer_MAKO_render.json" \
    "share/mako-render/vulkan/spatial_scaling.d/VkLayer_MAKO_spatial_scaling.json" \
    "share/mako-render/vulkan/vkbasalt.d/vkBasalt.json" \
    "share/mako-render/vkbasalt-shaders/Clarity.fx" \
    "share/mako-render/vkbasalt-shaders/CropStretch.fx" \
    "share/mako-render/vkbasalt-shaders/LevelsPlus.fx" \
    "share/mako-render/vkbasalt-shaders/SOURCE.md" \
    "share/mako-render/vkbasalt-shaders/Vibrance.fx" \
    "share/mako-render/vkbasalt-shaders/LICENSE-SweetFX" \
    "share/doc/mako-render/vkbasalt/LICENSE" \
    "share/doc/mako-render/vkbasalt/RESHade-LICENSE.md" \
    "share/doc/mako-render/vkbasalt/SOURCE" \
    "share/doc/mako-render/vkbasalt/MAKO-PIN.json" \
    "share/vulkan/implicit_layer.d/VkLayer_MAKO_spatial_scaling.json" \
    "share/vulkan/implicit_layer.d/VkLayer_MAKO_render.json"
)
if [[ "$host_arch" == x86_64 ]]; then
    # The native Remote Play helper hooks Steam's x86_64 streaming client; the
    # AArch64 package keeps the command, which reports the feature unsupported.
    required_paths+=("share/mako-render/mako_remote_play/libmako-remote-play-sdr.so")
elif [[ -e "$install_dir/share/mako-render/mako_remote_play/libmako-remote-play-sdr.so" ]]; then
    echo "Packaging failed: the x86_64-only Remote Play helper was built for $host_arch" >&2
    exit 1
fi
if [[ "$build_32_bit" == true ]]; then
    required_paths+=(
        "lib32/libmako-render.so"
        "lib32/libmako-render-scaling.so"
        "lib32/vkbasalt/libvkbasalt.so"
        "share/mako-render/vulkan/implicit_layer.d/VkLayer_MAKO_render.x86.json"
        "share/vulkan/implicit_layer.d/VkLayer_MAKO_render.x86.json"
        "share/mako-render/vulkan/spatial_scaling.d/VkLayer_MAKO_spatial_scaling.x86.json"
        "share/vulkan/implicit_layer.d/VkLayer_MAKO_spatial_scaling.x86.json"
        "share/mako-render/vulkan/vkbasalt.d/vkBasalt.x86.json"
    )
fi
for required_path in "${required_paths[@]}"; do
    if [[ ! -e "$install_dir/$required_path" ]]; then
        echo "Packaging failed: missing $required_path" >&2
        exit 1
    fi
done

# The archive-root launcher is intentionally separate from the installed
# `mako-installer` command. Users extract the archive, double-click this file,
# and the installer copies only the verified payload into their user-local
# prefix. The generated manifest gives upgrades and uninstalls an exact,
# checksummed ownership record without treating the entire ~/.local tree as
# disposable.
cp "$repo_root/scripts/mako-installer" "$install_dir/Install MAKO Renderer"
chmod 0755 "$install_dir/Install MAKO Renderer"
standalone_readme="$repo_root/dist/MAKO-Renderer-README.txt"
if [[ ! -s "$standalone_readme" ]]; then
    echo "Packaging failed: missing standalone Renderer README: $standalone_readme" >&2
    exit 1
fi
cp "$standalone_readme" "$install_dir/README.txt"
if ! grep -Fq '~/.local/bin/mako-launch %command%' "$install_dir/README.txt" ||
        ! grep -Fq 'ENABLE_VKBASALT=1' "$install_dir/README.txt" ||
        ! grep -Fq 'Uninstall MAKO Renderer' "$install_dir/README.txt" ||
        ! grep -Fq 'profiles, settings, and diagnostics' "$install_dir/README.txt"; then
    echo "Packaging failed: standalone Renderer README is incomplete" >&2
    exit 1
fi
printf '%s\n' "$version" > "$install_dir/MAKO-Renderer-version.txt"
manifest_roots=(bin lib share)
if [[ -d "$install_dir/lib32" ]]; then
    manifest_roots+=(lib32)
fi
(
    cd "$install_dir"
    find "${manifest_roots[@]}" -type f -print | LC_ALL=C sort | xargs sha256sum
) > "$install_dir/MAKO-Renderer-install-manifest.txt"
if [[ ! -s "$install_dir/MAKO-Renderer-install-manifest.txt" ]]; then
    echo "Packaging failed: standalone installer manifest is empty" >&2
    exit 1
fi
if ! (cd "$install_dir" && sha256sum --check --status MAKO-Renderer-install-manifest.txt); then
    echo "Packaging failed: standalone installer manifest does not verify" >&2
    exit 1
fi

if [[ ! -x "$install_dir/bin/mako-launch" ]]; then
    echo "Packaging failed: bin/mako-launch is not executable" >&2
    exit 1
fi
if [[ ! -x "$install_dir/bin/mako-installer" ]]; then
    echo "Packaging failed: bin/mako-installer is not executable" >&2
    exit 1
fi
bash -n "$install_dir/bin/mako-launch"
if [[ "${MAKO_RELEASE_SKIP_TESTS:-0}" != "1" ]]; then
    bash "$repo_root/scripts/test-mako-launch.sh" "$install_dir/bin/mako-launch"
fi

verify_elf_class() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(od -An -t u1 -j 4 -N 1 "$path" | tr -d '[:space:]')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Packaging failed: $path has unexpected ELF class byte $actual" >&2
        exit 1
    fi
}

verify_elf_class "$install_dir/lib/libmako-render.so" 2
verify_elf_class "$install_dir/lib/libmako-render-scaling.so" 2
verify_elf_class "$install_dir/lib/vkbasalt/libvkbasalt.so" 2
if [[ "$build_32_bit" == true ]]; then
    verify_elf_class "$install_dir/lib32/libmako-render.so" 1
    verify_elf_class "$install_dir/lib32/libmako-render-scaling.so" 1
    verify_elf_class "$install_dir/lib32/vkbasalt/libvkbasalt.so" 1
fi

# Every ELF in the payload must target the package architecture: 64-bit files
# use the host ISA, and 32-bit files (x86_64 packages only) use i386.
case "$host_arch" in
    x86_64) expected_machine64=62 ;;
    aarch64) expected_machine64=183 ;;
esac
recorded_host_arch="$(tr -d '[:space:]' < "$install_dir/share/mako-render/host-architecture")"
if [[ "$recorded_host_arch" != "$host_arch" ]]; then
    echo "Packaging failed: payload records host architecture $recorded_host_arch, expected $host_arch" >&2
    exit 1
fi
while IFS= read -r -d '' payload_file; do
    if [[ "$(od -An -c -N 4 "$payload_file" | tr -d '[:space:]')" != '177ELF' ]]; then
        continue
    fi
    elf_class="$(od -An -t u1 -j 4 -N 1 "$payload_file" | tr -d '[:space:]')"
    elf_machine="$(od -An -t u2 -j 18 -N 2 --endian=little "$payload_file" | tr -d '[:space:]')"
    expected_machine="$expected_machine64"
    if [[ "$elf_class" == 1 ]]; then
        if [[ "$host_arch" != x86_64 ]]; then
            echo "Packaging failed: 32-bit ELF $payload_file in a $host_arch package" >&2
            exit 1
        fi
        expected_machine=3
    fi
    if [[ "$elf_machine" != "$expected_machine" ]]; then
        echo "Packaging failed: $payload_file has ELF machine $elf_machine, expected $expected_machine" >&2
        exit 1
    fi
done < <(find "$install_dir" -type f -print0)
for vkbasalt_library in "$install_dir/lib/vkbasalt/libvkbasalt.so"; do
    if ! strings "$vkbasalt_library" |
            grep -Fx "vkBasalt_GetInstanceProcAddr" >/dev/null ||
            ! strings "$vkbasalt_library" |
                grep -Fx "vkBasalt_GetDeviceProcAddr" >/dev/null; then
        echo "Packaging failed: invalid bundled vkBasalt entry point in $vkbasalt_library" >&2
        exit 1
    fi
done
if [[ "$build_32_bit" == true ]] &&
        { ! strings "$install_dir/lib32/vkbasalt/libvkbasalt.so" |
            grep -Fx "vkBasalt_GetInstanceProcAddr" >/dev/null ||
          ! strings "$install_dir/lib32/vkbasalt/libvkbasalt.so" |
            grep -Fx "vkBasalt_GetDeviceProcAddr" >/dev/null; }; then
    echo "Packaging failed: invalid bundled 32-bit vkBasalt entry point" >&2
    exit 1
fi

vkbasalt_manifest64="$install_dir/share/mako-render/vulkan/vkbasalt.d/vkBasalt.json"
if ! grep -Fq '"name": "VK_LAYER_VKBASALT_post_processing"' "$vkbasalt_manifest64" ||
        ! grep -Fq '"library_arch": "64"' "$vkbasalt_manifest64" ||
        ! grep -Fq '../../../../lib/vkbasalt/libvkbasalt.so' "$vkbasalt_manifest64" ||
        ! grep -Fq '"ENABLE_VKBASALT": "1"' "$vkbasalt_manifest64" ||
        ! grep -Fq '"DISABLE_VKBASALT": "1"' "$vkbasalt_manifest64"; then
    echo "Packaging failed: bundled 64-bit vkBasalt manifest is incorrect" >&2
    exit 1
fi
if [[ "$build_32_bit" == true ]]; then
    vkbasalt_manifest32="$install_dir/share/mako-render/vulkan/vkbasalt.d/vkBasalt.x86.json"
    if ! grep -Fq '"library_arch": "32"' "$vkbasalt_manifest32" ||
            ! grep -Fq '../../../../lib32/vkbasalt/libvkbasalt.so' "$vkbasalt_manifest32"; then
        echo "Packaging failed: bundled 32-bit vkBasalt manifest is incorrect" >&2
        exit 1
    fi
fi

scaling_manifest64="$install_dir/share/vulkan/implicit_layer.d/VkLayer_MAKO_spatial_scaling.json"
private_scaling_manifest64="$install_dir/share/mako-render/vulkan/spatial_scaling.d/VkLayer_MAKO_spatial_scaling.json"
if ! grep -Fq '"library_arch": "64"' "$scaling_manifest64" ||
        ! grep -Fq '../../../lib/libmako-render-scaling.so' "$scaling_manifest64" ||
        ! grep -Fq '"name": "VK_LAYER_MAKO_spatial_scaling"' "$scaling_manifest64" ||
        ! grep -Fq '"ENABLE_MAKO_SPATIAL_SCALING": "1"' "$scaling_manifest64" ||
        ! grep -Fq '"DISABLE_MAKO_SPATIAL_SCALING": "1"' "$scaling_manifest64"; then
    echo "Packaging failed: 64-bit spatial Vulkan manifest is incorrect" >&2
    exit 1
fi
if ! grep -Fq '"library_arch": "64"' "$private_scaling_manifest64" ||
        ! grep -Fq '../../../../lib/libmako-render-scaling.so' "$private_scaling_manifest64" ||
        ! grep -Fq '"name": "VK_LAYER_MAKO_spatial_scaling"' "$private_scaling_manifest64"; then
    echo "Packaging failed: private 64-bit spatial Vulkan manifest is incorrect" >&2
    exit 1
fi

# Qt promises backwards binary compatibility, not forwards compatibility.
# Keep release archives usable on the Qt 6.4 baseline provided by Ubuntu
# 24.04 even when packaging is initiated on a rolling distribution. Portable
# packaging intentionally builds against Qt 6.2 and therefore produces an
# archive with a broader runtime range.
ui_strings="$build_root/mako-ui.strings"
strings "$install_dir/bin/mako-ui" > "$ui_strings"
if grep -Eq 'Qt_6\.([5-9]|[1-9][0-9])' "$ui_strings"; then
    echo "Packaging failed: mako-ui requires a Qt ABI newer than 6.4." >&2
    echo "Re-run with MAKO_PORTABLE_PACKAGE=1 to use the reproducible Qt 6.2 container." >&2
    exit 1
fi
if grep -Fq 'libQt6QmlMeta.so.6' "$ui_strings"; then
    echo "Packaging failed: mako-ui unexpectedly depends on Qt 6.8's QmlMeta library." >&2
    echo "Re-run with MAKO_PORTABLE_PACKAGE=1 to use the reproducible Qt 6.2 container." >&2
    exit 1
fi

manifest64="$install_dir/share/vulkan/implicit_layer.d/VkLayer_MAKO_render.json"
private_manifest64="$install_dir/share/mako-render/vulkan/implicit_layer.d/VkLayer_MAKO_render.json"
if ! grep -Fq '"library_arch": "64"' "$manifest64" ||
        ! grep -Fq '../../../lib/libmako-render.so' "$manifest64" ||
        ! grep -Fq '"name": "VK_LAYER_MAKO_render"' "$manifest64" ||
        ! grep -Fq '"ENABLE_MAKO": "1"' "$manifest64" ||
        ! grep -Fq '"DISABLE_MAKO": "1"' "$manifest64"; then
    echo "Packaging failed: 64-bit Vulkan manifest is incorrect" >&2
    exit 1
fi
if ! grep -Fq '"library_arch": "64"' "$private_manifest64" ||
        ! grep -Fq '../../../../lib/libmako-render.so' "$private_manifest64" ||
        ! grep -Fq '"name": "VK_LAYER_MAKO_render"' "$private_manifest64"; then
    echo "Packaging failed: private 64-bit Vulkan manifest is incorrect" >&2
    exit 1
fi
if [[ "$build_32_bit" == true ]]; then
    manifest32="$install_dir/share/vulkan/implicit_layer.d/VkLayer_MAKO_render.x86.json"
    private_manifest32="$install_dir/share/mako-render/vulkan/implicit_layer.d/VkLayer_MAKO_render.x86.json"
    scaling_manifest32="$install_dir/share/vulkan/implicit_layer.d/VkLayer_MAKO_spatial_scaling.x86.json"
    private_scaling_manifest32="$install_dir/share/mako-render/vulkan/spatial_scaling.d/VkLayer_MAKO_spatial_scaling.x86.json"
    if ! grep -Fq '"library_arch": "32"' "$manifest32" ||
            ! grep -Fq '../../../lib32/libmako-render.so' "$manifest32" ||
            ! grep -Fq '"name": "VK_LAYER_MAKO_render"' "$manifest32" ||
            ! grep -Fq '"ENABLE_MAKO": "1"' "$manifest32" ||
            ! grep -Fq '"DISABLE_MAKO": "1"' "$manifest32"; then
        echo "Packaging failed: 32-bit Vulkan manifest is incorrect" >&2
        exit 1
    fi
    if ! grep -Fq '"library_arch": "32"' "$private_manifest32" ||
            ! grep -Fq '../../../../lib32/libmako-render.so' "$private_manifest32" ||
            ! grep -Fq '"name": "VK_LAYER_MAKO_render"' "$private_manifest32"; then
        echo "Packaging failed: private 32-bit Vulkan manifest is incorrect" >&2
        exit 1
    fi
    if ! grep -Fq '"library_arch": "32"' "$scaling_manifest32" ||
            ! grep -Fq '../../../lib32/libmako-render-scaling.so' "$scaling_manifest32" ||
            ! grep -Fq '"name": "VK_LAYER_MAKO_spatial_scaling"' "$scaling_manifest32" ||
            ! grep -Fq '"ENABLE_MAKO_SPATIAL_SCALING": "1"' "$scaling_manifest32" ||
            ! grep -Fq '"DISABLE_MAKO_SPATIAL_SCALING": "1"' "$scaling_manifest32"; then
        echo "Packaging failed: 32-bit spatial Vulkan manifest is incorrect" >&2
        exit 1
    fi
    if ! grep -Fq '"library_arch": "32"' "$private_scaling_manifest32" ||
            ! grep -Fq '../../../../lib32/libmako-render-scaling.so' "$private_scaling_manifest32" ||
            ! grep -Fq '"name": "VK_LAYER_MAKO_spatial_scaling"' "$private_scaling_manifest32"; then
        echo "Packaging failed: private 32-bit spatial Vulkan manifest is incorrect" >&2
        exit 1
    fi
fi

layer_binaries=("$install_dir/lib/libmako-render.so")
layer_binaries+=("$install_dir/lib/libmako-render-scaling.so")
if [[ "$build_32_bit" == true ]]; then
    layer_binaries+=("$install_dir/lib32/libmako-render.so")
    layer_binaries+=("$install_dir/lib32/libmako-render-scaling.so")
fi
relay_contract_symbol="makoSpatialScalingLookupFixedContract"
for layer_binary in "${layer_binaries[@]}"; do
    dynamic_dependencies="$(readelf -d "$layer_binary")"
    if ! grep -Fq 'Shared library: [libstdc++.so.6]' <<< "$dynamic_dependencies"; then
        echo "Packaging failed: $layer_binary must use SteamOS's dynamic C++ runtime" >&2
        echo "Static libstdc++ inside a Vulkan layer is not supported." >&2
        exit 1
    fi

    exported_symbols="$(nm -D --defined-only "$layer_binary" | awk '{print $3}')"
    for required_entrypoint in \
            vkNegotiateLoaderLayerInterfaceVersion \
            vkGetInstanceProcAddr \
            vkGetDeviceProcAddr; do
        if ! grep -Fxq "$required_entrypoint" <<< "$exported_symbols"; then
            echo "Packaging failed: Vulkan entrypoint $required_entrypoint is not exported by $layer_binary" >&2
            exit 1
        fi
    done
    expected_identity="VK_LAYER_MAKO_render"
    if [[ "$layer_binary" == *libmako-render-scaling.so ]]; then
        expected_identity="VK_LAYER_MAKO_spatial_scaling"
        if ! grep -Fxq "$relay_contract_symbol" <<< "$exported_symbols"; then
            echo "Packaging failed: spatial capability relay entrypoint is missing from $layer_binary" >&2
            exit 1
        fi
    elif grep -Fxq "$relay_contract_symbol" <<< "$exported_symbols"; then
        echo "Packaging failed: spatial capability relay entrypoint leaked into $layer_binary" >&2
        exit 1
    fi
    if ! strings "$layer_binary" |
            grep -F "MAKO Renderer: render layer active; identity=$expected_identity; build=$version" >/dev/null; then
        echo "Packaging failed: layer build identity diagnostic is missing from $layer_binary" >&2
        exit 1
    fi
    if ! strings "$layer_binary" | grep -F "MAKO_PROFILE_FALLBACK" >/dev/null; then
        echo "Packaging failed: profile-fallback wrapper protocol is missing from $layer_binary" >&2
        exit 1
    fi
done

tar -C "$install_dir" -cJf "$output_path" .

echo "Created and verified: $output_path"
echo "Version: $version"
echo "Host architecture: $host_arch"
echo "Architectures: $([[ "$build_32_bit" == true ]] && printf '64,32' || printf '64')"
