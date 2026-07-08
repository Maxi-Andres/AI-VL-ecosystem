#!/usr/bin/env bash
# reindex-if-needed.sh — keep the codebase-memory graph fresh, cheaply.
#
# Wired into .claude/settings.local.json on SessionStart and Stop. For each of the
# four repos (the ecosystem root + the three app repos) it computes a signature
# from the current git commit plus the working-tree status; it re-indexes a repo
# ONLY when that signature changed since the last run. Signatures are cached under
# .claude/.reindex-state/. Indexing is itself incremental, so this is doubly cheap.
#
# It must never break a session: every step is guarded and the whole script is
# invoked with `|| true` from the hook. Requires `codebase-memory-mcp` on PATH.
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$ROOT/.claude/.reindex-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

command -v codebase-memory-mcp >/dev/null 2>&1 || exit 0

REPOS=("." "AI-VL-core" "AI-VL-backend" "AI-VL-frontend")

for rel in "${REPOS[@]}"; do
  repo="$ROOT/$rel"
  [ -d "$repo" ] || continue

  # Signature: HEAD commit + a hash of the porcelain status (captures uncommitted
  # edits and untracked files). Non-git dirs fall back to "no-git".
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo no-git)"
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null | sha1sum | cut -d' ' -f1)"
  sig="$head:$dirty"

  key="$(echo "$rel" | tr '/.' '__')"
  state_file="$STATE_DIR/$key"
  prev="$(cat "$state_file" 2>/dev/null || echo)"

  [ "$sig" = "$prev" ] && continue   # unchanged — skip

  abs="$(cd "$repo" && pwd)"
  if codebase-memory-mcp cli index_repository "{\"repo_path\":\"$abs\"}" >/dev/null 2>&1; then
    echo "$sig" > "$state_file"
  fi
done

exit 0
