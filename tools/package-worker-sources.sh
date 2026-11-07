#!/usr/bin/env bash
# Release companion to the coordinator: canonical sources, never GHC binaries
# or a second Hackage/Stack package store. Put the result beside the coordinator.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?Usage: bash tools/package-worker-sources.sh /absolute/path/visual-haskell-worker-sources.tar.gz}"
if [[ "$destination" != /* ]]; then
  echo "The archive destination must be absolute" >&2
  exit 1
fi
sources=(vh/workers/cabal.project)
for package in vh/packages/semantic-model vh/packages/analysis-protocol \
  vh/packages/analysis-client vh/packages/projects vh/workers/ghc-9.10; do
  for entry in package.yaml src app data; do
    [[ ! -e "$repository_root/$package/$entry" ]] || sources+=("$package/$entry")
  done
  for manifest in "$repository_root/$package/"*.cabal; do
    [[ ! -f "$manifest" ]] || sources+=("${manifest#"$repository_root/"}")
  done
done
COPYFILE_DISABLE=1 tar --format=ustar -C "$repository_root" -czf "$destination" "${sources[@]}"
echo "Worker sources packaged at $destination (no compilers or dependency stores)"
