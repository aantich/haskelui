#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
worker_package="$repository_root/vh/workers/ghc-9.10"

cd "$repository_root"
stack build \
  visual-haskell-analysis-ghc910:test:visual-haskell-analysis-ghc-910-test \
  visual-haskell-analysis-ghc910:exe:visual-haskell-analysis-ghc910 \
  --fast \
  --jobs 1 \
  --no-run-tests

worker_dist="$(cd "$worker_package" && stack path --dist-dir)"
test_binary="$worker_package/$worker_dist/build/visual-haskell-analysis-ghc-910-test/visual-haskell-analysis-ghc-910-test"
worker_directory="$worker_package/$worker_dist/build/visual-haskell-analysis-ghc910"

if [[ ! -x "$test_binary" ]]; then
  echo "Analysis test binary was not built at $test_binary" >&2
  exit 1
fi

if [[ ! -x "$worker_directory/visual-haskell-analysis-ghc910" ]]; then
  echo "Analysis worker was not built under $worker_directory" >&2
  exit 1
fi

cd "$worker_package"
VISUAL_HASKELL_TEST_SELF_HOSTED_CRADLE=1 \
  PATH="$worker_directory:$PATH" \
  "$test_binary"
