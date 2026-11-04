#!/usr/bin/env bash
# Each argument is "<expected path>=<rootpath>". The targets are in the
# root package, so the rootpath of an output dir is its dest. The output
# dirs of the default-named elixir_app must not gain a prefix.
set -euo pipefail

for arg in "$@"; do
    expected="${arg%%=*}"
    path="${arg#*=}"
    path="${path#./}"
    if [ "$path" != "$expected" ]; then
        echo "FAIL: output dir is $path, expected $expected" >&2
        exit 1
    fi
    if [ ! -d "$path" ]; then
        echo "FAIL: $path is not a directory" >&2
        exit 1
    fi
    echo "ok: $path"
done
