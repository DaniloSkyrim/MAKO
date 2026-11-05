#!/usr/bin/env bash
# Collect read-only evidence that an installed AArch64 MAKO package is wired
# correctly on a native ARM host such as DroidDeck. It never installs, edits
# profiles, or changes Steam; it only reads state and runs MAKO's own GPU
# self-tests from the installed CLI.
set -uo pipefail

dll_path=""
output_dir=""
run_gpu=true

usage() {
  cat <<'EOF'
Usage: collect-aarch64-evidence.sh [--dll PATH] [--no-gpu] [--output DIR]

Writes mako-aarch64-evidence-<time>.tar.gz with host detection, installed
payload identity, generated-wrapper guard, Vulkan layer discovery, and the
installed mako-cli GPU self-tests. --dll adds the licensed Lossless.dll
benchmark; the DLL itself is never copied into the report.
EOF
}

while (($#)); do
  case "$1" in
    --dll) dll_path="${2:?--dll needs a path}"; shift 2 ;;
    --no-gpu) run_gpu=false; shift ;;
    --output) output_dir="${2:?--output needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

stamp="$(date +%Y%m%d-%H%M%S)"
output_dir="${output_dir:-$PWD}"
report_dir="$(mktemp -d)/mako-aarch64-evidence-$stamp"
mkdir -p "$report_dir"
mako_root="$HOME/.local/share/mako-render"
cli="$mako_root/bin/mako-cli"

section() { printf '\n===== %s =====\n' "$1"; }
run() {
  # Record the command, its output, and its exit status without stopping.
  printf '$ %s\n' "$*"
  "$@" 2>&1
  printf '[exit %s]\n' "$?"
}
elf_machine() {
  [[ -r "$1" ]] || { printf 'unreadable'; return; }
  case "$(od -An -t u2 -j 18 -N 2 --endian=little "$1" 2>/dev/null | tr -d '[:space:]')" in
    62) printf 'x86_64' ;;
    3) printf 'i386' ;;
    183) printf 'aarch64' ;;
    '') printf 'not-elf' ;;
    *) printf 'other' ;;
  esac
}

{
  section "Host"
  run uname -a
  printf 'uname -m: %s\n' "$(uname -m)"
  for marker in /usr/local/bin/droiddeck-session /usr/libexec/armada/device-env /usr/bin/FEXInterpreter /usr/bin/FEXLoader; do
    if [[ -e "$marker" ]]; then printf 'present: %s\n' "$marker"; else printf 'absent:  %s\n' "$marker"; fi
  done
  [[ -r /etc/os-release ]] && cat /etc/os-release
  printf 'HOME=%s USER=%s\n' "$HOME" "${USER:-$(id -un 2>/dev/null)}"

  section "Process ancestry (ELF machine per ancestor)"
  pid=$$
  for _ in $(seq 1 32); do
    [[ -r "/proc/$pid/status" ]] || break
    name="$(awk '/^Name:/ {print $2}' "/proc/$pid/status")"
    printf '%s %s %s\n' "$pid" "$name" "$(elf_machine "/proc/$pid/exe")"
    pid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status")"
    [[ -n "$pid" && "$pid" != 0 ]] || break
  done
  printf 'pid1: %s\n' "$(elf_machine /proc/1/exe)"

  section "Installed MAKO Renderer payload"
  if [[ -r "$mako_root/host-architecture" ]]; then
    printf 'host-architecture record: %s\n' "$(cat "$mako_root/host-architecture")"
  else
    printf 'host-architecture record: missing\n'
  fi
  [[ -r "$mako_root/installed-engine.json" ]] && cat "$mako_root/installed-engine.json"
  while IFS= read -r -d '' file; do
    printf '%-8s %s\n' "$(elf_machine "$file")" "${file#"$mako_root"/}"
  done < <(find "$mako_root" -type f \( -name '*.so' -o -path '*/bin/*' \) -print0 2>/dev/null)
  [[ -e "$mako_root/lib32" ]] && printf 'UNEXPECTED: lib32 exists on an AArch64 install\n'

  section "Managed Vulkan layer manifests"
  for dir in "$mako_root/vulkan"/* "$HOME/.local/share/vulkan/implicit_layer.d"; do
    [[ -d "$dir" ]] || continue
    for manifest in "$dir"/*.json; do
      [[ -e "$manifest" ]] || continue
      printf -- '--- %s\n' "$manifest"
      cat "$manifest"
      printf '\n'
    done
  done

  section "Generated wrapper guard"
  wrapper="$HOME/.local/bin/mako-run"
  if [[ -r "$wrapper" ]]; then
    grep -n 'mako-host-compatibility\|mako-wrapper-format\|mako_renderer_arch=\|droiddeck\|FROG_gamescope_wsi\|MANGOHUD_overlay' "$wrapper"
    printf 'Guard decision on this host:\n'
    # Execute only the guard, with a stand-in game that prints the result.
    guard="$(awk '/mako-host-compatibility/ {on=1} on {print} /^unset mako_native_arch/ {exit}' "$wrapper")"
    bash -c "$guard"$'\nexport ENABLE_MAKO=1\nexec "$@"' mako-guard \
      sh -c 'printf "ENABLE_MAKO=%s DISABLE_MAKO=%s\n" "${ENABLE_MAKO:-}" "${DISABLE_MAKO:-}"' 2>&1
  else
    printf 'missing: %s (open MAKO Decky once so it generates the wrapper)\n' "$wrapper"
  fi

  section "MAKO Decky logs"
  for log_dir in "$HOME/homebrew/logs/Mako" /root/homebrew/logs/Mako; do
    [[ -d "$log_dir" ]] || continue
    latest="$(ls -t "$log_dir"/*.log 2>/dev/null | head -n 1)"
    [[ -n "$latest" ]] && { printf -- '--- %s\n' "$latest"; tail -n 400 "$latest"; }
  done

  section "Vulkan devices and layers"
  if command -v vulkaninfo >/dev/null 2>&1; then
    run vulkaninfo --summary
    ENABLE_MAKO=1 VK_LOADER_DEBUG=layer \
      VK_ADD_IMPLICIT_LAYER_PATH="$mako_root/vulkan/implicit_layer.d" \
      vulkaninfo --summary 2>&1 | grep -i 'mako\|layer' | head -n 120
  else
    printf 'vulkaninfo not installed (pacman -S vulkan-tools adds it)\n'
  fi
} > "$report_dir/host.txt" 2>&1

if [[ "$run_gpu" == true && -x "$cli" ]]; then
  {
    section "mako-cli synchronization canary"
    run "$cli" synchronization-validation-canary
    for method in native mako; do
      for precision in --no-fp16 --allow-fp16; do
        section "spatial-profile $method $precision"
        run "$cli" spatial-profile --method "$method" "$precision" \
          --width 1280 --height 800 --factor 1.5 --warmup 50 --samples 200
      done
    done
    if [[ -n "$dll_path" ]]; then
      for precision in --no-fp16 --allow-fp16; do
        section "frame-generation benchmark $precision"
        run "$cli" benchmark --dll "$dll_path" "$precision" \
          --width 1280 --height 800 --multiplier 2 --duration 10
      done
    fi
  } > "$report_dir/gpu.txt" 2>&1
elif [[ "$run_gpu" == true ]]; then
  printf 'missing installed CLI: %s\n' "$cli" > "$report_dir/gpu.txt"
fi

if [[ -x "$HOME/.local/bin/mako-diagnostics" ]]; then
  "$HOME/.local/bin/mako-diagnostics" --session all --lines 2000 all \
    > "$report_dir/mako-diagnostics.txt" 2>&1
fi

# Never ship the licensed input, even if a path to it appears in output.
[[ -n "$dll_path" ]] && sed -i "s|$dll_path|<Lossless.dll>|g" "$report_dir"/*.txt

archive="$output_dir/mako-aarch64-evidence-$stamp.tar.gz"
tar -C "$(dirname "$report_dir")" -czf "$archive" "$(basename "$report_dir")"
rm -rf "$(dirname "$report_dir")"
printf 'Wrote %s\n' "$archive"
