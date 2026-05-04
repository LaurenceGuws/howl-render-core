#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

clone_or_update() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local dir="$ROOT/$name"

  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    git clone "$url" "$dir"
  fi

  git -C "$dir" fetch --all --tags --prune
  git -C "$dir" checkout "$rev"
}

clone_or_update "freetype-zig" "https://github.com/LaurenceGuws/howl-freetype.git" "b2b8e0381b683f8d8fb93fb6343132e46d47213d"
clone_or_update "harfbuzz-zig" "https://github.com/LaurenceGuws/howl-harfbuzz.git" "8807cc6439322bb9f5418950dbfb5fe57b57b313"
