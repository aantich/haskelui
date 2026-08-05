#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="${1:-13.0}"
target_tag="${target//./}"
work_dir=".stack-work-macos${target_tag}"

cd "$repo_root"

echo "Building and testing UIH with MACOSX_DEPLOYMENT_TARGET=$target in $work_dir"
MACOSX_DEPLOYMENT_TARGET="$target" \
  stack --work-dir "$work_dir" test uih-example-appkit-vertical uih-example-text-editor

install_root="$({
  MACOSX_DEPLOYMENT_TARGET="$target" \
    stack --work-dir "$work_dir" path --local-install-root
} 2>/dev/null)"
binary="$install_root/bin/uih-appkit-vertical"
editor_binary="$install_root/bin/uih-text-editor"

first_match() {
  local search_root="$1"
  local pattern="$2"
  rg --files -uu "$search_root" | rg "$pattern" | awk 'NR == 1 { print; exit }'
}

appkit_object="$(first_match "backends/macos/uih-backend-appkit/$work_dir" '/UIHAppKit\.o$')"
core_object="$(first_match "packages/uih-core/$work_dir" '/UIH/Core\.o$')"
runtime_object="$(first_match "packages/uih-runtime/$work_dir" '/UIH/Runtime\.o$')"

verify_minos() {
  local artifact="$1"
  local actual
  actual="$(vtool -show-build "$artifact" | awk '$1 == "minos" { print $2; exit }')"
  if [[ "$actual" != "$target" ]]; then
    echo "Expected macOS min version $target, found ${actual:-none}: $artifact" >&2
    return 1
  fi
  echo "macOS min version $actual: $artifact"
}

verify_compatible_minos() {
  local artifact="$1"
  local actual
  local actual_key
  local target_key
  actual="$(vtool -show-build "$artifact" | awk '$1 == "minos" { print $2; exit }')"
  actual_key="$(awk -F. -v version="$actual" 'BEGIN { split(version, part, "."); printf "%d%03d%03d", part[1], part[2], part[3] }')"
  target_key="$(awk -F. -v version="$target" 'BEGIN { split(version, part, "."); printf "%d%03d%03d", part[1], part[2], part[3] }')"
  if [[ -z "$actual" || "$actual_key" -gt "$target_key" ]]; then
    echo "GHC runtime object requires macOS ${actual:-unknown}, newer than $target: $artifact" >&2
    return 1
  fi
  echo "GHC runtime-compatible min version $actual: $artifact"
}

verify_minos "$binary"
verify_minos "$editor_binary"
verify_minos "$appkit_object"
verify_minos "$core_object"
verify_minos "$runtime_object"

ghc_libdir="$(ghc --print-libdir)"
rts_archive="$(first_match "$ghc_libdir" '/rts-[^/]+/libHSrts-[^/]+_thr\.a$')"
base_archive="$(first_match "$ghc_libdir" '/base-[^/]+/libHSbase-[^/]+-[^/_]+\.a$')"
runtime_inspect_dir="$(mktemp -d "${TMPDIR:-/tmp}/uih-runtime-inspect.XXXXXX")"
trap 'rm -rf "$runtime_inspect_dir"' EXIT
rts_member="$(ar -t "$rts_archive" | awk '/\.thr_o$/ { print; exit }')"
base_member="$(ar -t "$base_archive" | awk '/\.o$/ { print; exit }')"
cd "$runtime_inspect_dir"
ar -x "$rts_archive" "$rts_member"
ar -x "$base_archive" "$base_member"
verify_compatible_minos "$runtime_inspect_dir/$rts_member"
verify_compatible_minos "$runtime_inspect_dir/$base_member"
cd "$repo_root"

echo "Linked system libraries and frameworks:"
otool -L "$binary"
