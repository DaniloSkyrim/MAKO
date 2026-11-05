#!/usr/bin/env bash
# Summarize what an upstream MAKO update brings into the AArch64 port and flag
# added code lines that assume an x86 host, so a sync pull request names the
# places that may need an AArch64 counterpart. Read-only; prints Markdown.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/upstream-sync-audit.sh PORT-REF UPSTREAM-REF

Prints the upstream commits missing from PORT-REF and every code line those
commits add that names an x86-only ISA, bitness, or layer identity.
EOF
}

if (($# != 2)); then
  usage >&2
  exit 2
fi
port_ref="$1"
upstream_ref="$2"
base="$(git merge-base "$port_ref" "$upstream_ref")"

# ISA- and bitness-specific identities the port maps per architecture.
pattern='x86_64|x86-64|amd64|i[36]86|lib32|multilib|-m32|\.x86\.json|_x86([^_0-9a-z]|$)|steamoverlay_|gamescope_wsi|MANGOHUD_overlay|host_architectures|e_machine|uname -m|platform\.machine'
# Prose, website, and the x86_64-only Flatpak and Arch packages are not ported.
excludes=(
  ':(exclude)*.md'
  ':(exclude).agents/**'
  ':(exclude)website/**'
  ':(exclude)assets/**'
  ':(exclude)engine/dist/flatpak/**'
  ':(exclude)engine/dist/arch/**'
  ':(exclude)*lock.yaml'
  ':(exclude)*lock.json'
)

commit_count="$(git rev-list --count "$port_ref..$upstream_ref")"
printf '### Upstream commits (%s)\n\n' "$commit_count"
git log --no-merges --format='- `%h` %s' -n 60 "$port_ref..$upstream_ref"
if ((commit_count > 60)); then
  printf -- '- ... and %s more\n' "$((commit_count - 60))"
fi

printf '\n### Changed files\n\n```text\n'
git diff --stat=120 "$base" "$upstream_ref" | tail -n 80
printf '```\n\n### Added code lines with x86-specific assumptions\n\n'

findings="$(
  git diff --unified=0 --no-color "$base" "$upstream_ref" -- . "${excludes[@]}" |
    MAKO_AUDIT_PATTERN="$pattern" awk '
      /^\+\+\+ b\// { file = substr($0, 7); next }
      /^@@/ {
        split($3, range, ",")
        line = substr(range[1], 2) - 1
        next
      }
      /^\+/ {
        line++
        text = substr($0, 2)
        if (text ~ ENVIRON["MAKO_AUDIT_PATTERN"]) {
          gsub(/`/, "'\''", text)
          sub(/^[[:space:]]+/, "", text)
          if (length(text) > 160) text = substr(text, 1, 157) "..."
          printf "- `%s:%d` %s\n", file, line, text
        }
      }
    '
)"
if [[ -n "$findings" ]]; then
  printf '%s\n' "$findings" | head -n 120
  total="$(printf '%s\n' "$findings" | wc -l | tr -d '[:space:]')"
  if ((total > 120)); then
    printf -- '- ... and %s more\n' "$((total - 120))"
  fi
  printf '\nReview each line: an x86 identity with no AArch64 counterpart in `constants.host_layer_identities()`, the wrapper guard, `mako-launch`, or the Renderer packager may need porting before merge.\n'
else
  printf 'None found.\n'
fi
