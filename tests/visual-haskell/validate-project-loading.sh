#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
worker_package="$repository_root/vh/workers/ghc-9.10"

cd "$repository_root"
stack build visual-haskell-analysis-ghc910:exe:visual-haskell-project-loading-check \
  visual-haskell-analysis-ghc910:exe:visual-haskell-analysis-ghc910 --fast --jobs 1
worker_dist="$(cd "$worker_package" && stack path --dist-dir)"
probe="$worker_package/$worker_dist/build/visual-haskell-project-loading-check/visual-haskell-project-loading-check"

if [[ ! -x "$probe" ]]; then
  echo "Project-loading acceptance runner was not built at $probe" >&2
  exit 1
fi

# Run outside Stack's build lock: the runner invokes real Stack and Cabal tools.
if [[ "${1:-}" == "self-host" ]]; then
  "$probe" --self-host "$repository_root"
else
  "$probe" "$worker_package/test/fixtures/project-loading" "$@"
fi
