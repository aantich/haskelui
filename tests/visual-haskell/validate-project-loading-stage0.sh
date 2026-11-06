#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
worker_package="$repository_root/vh/workers/ghc-9.10"

cd "$repository_root"
stack build visual-haskell-analysis-ghc910:exe:visual-haskell-project-loading-spike --fast --jobs 1
worker_dist="$(cd "$worker_package" && stack path --dist-dir)"
probe="$worker_package/$worker_dist/build/visual-haskell-project-loading-spike/visual-haskell-project-loading-spike"

if [[ ! -x "$probe" ]]; then
  echo "Project-loading spike was not built at $probe" >&2
  exit 1
fi

# No enclosing Stack process may hold its build lock while the probe runs.
"$probe" "$worker_package/test/fixtures/project-loading" "$@"
