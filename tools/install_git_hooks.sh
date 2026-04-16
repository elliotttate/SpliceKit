#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook_src="$repo_root/tools/git-hooks/pre-push"

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[scrub] Not inside a git checkout: $repo_root" >&2
  exit 1
fi

git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir)"
hook_dir="$git_dir/hooks"
hook_dest="$hook_dir/pre-push"

mkdir -p "$hook_dir"
cp "$hook_src" "$hook_dest"
chmod +x "$hook_dest"

echo "[scrub] Installed pre-push hook at $hook_dest"
