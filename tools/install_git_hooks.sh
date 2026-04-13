#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook_src="$repo_root/tools/git-hooks/pre-push"
hook_dir="$repo_root/.git/hooks"
hook_dest="$hook_dir/pre-push"

if [[ ! -d "$repo_root/.git" ]]; then
  echo "[scrub] Not inside a git checkout: $repo_root" >&2
  exit 1
fi

mkdir -p "$hook_dir"
cp "$hook_src" "$hook_dest"
chmod +x "$hook_dest"

echo "[scrub] Installed pre-push hook at $hook_dest"
