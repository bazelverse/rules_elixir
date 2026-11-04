#!/usr/bin/env bash
set -euo pipefail

app_file="$1"
cat "$app_file"
applications=$(tr -d '\n' < "$app_file" | grep -o '{applications, *\[[^]]*\]}')
echo "$applications"
for app in kernel stdlib elixir dep_app; do
    if ! grep -Eq "[[ ,]$app[],]" <<< "$applications"; then
        echo "FAIL: $app is not in the applications list" >&2
        exit 1
    fi
done
