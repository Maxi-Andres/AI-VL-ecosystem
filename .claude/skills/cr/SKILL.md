---
name: cr
description: >-
  Code review of all uncommitted changes across the AI-VL ecosystem. Discovers
  uncommitted files in the root and the three app repos (AI-VL-core, AI-VL-backend,
  AI-VL-frontend), then reviews each against that repo's conventions, the ecosystem
  goals, the shared best-practices standard, and code duplication. Reports findings
  grouped by repo, ranked by severity — it does NOT commit or edit. Invoke with
  `/cr` (optionally `/cr <repo>` or `/cr staged` to scope).
---

# /cr — AI-VL code review

Review **uncommitted** work across the ecosystem before the user commits. Read-only:
report findings; never `git commit`/`git push`, and don't edit files unless the
user explicitly asks you to apply fixes afterward.

## Scope (args)

- `/cr` — review every repo that has uncommitted changes (root + the three app repos).
- `/cr <repo>` — only that repo (e.g. `/cr AI-VL-frontend`).
- `/cr staged` — only staged changes (`git diff --cached`) in each repo.

The app repos are sibling directories under the ecosystem root and are git-ignored
here, but **each is its own git repo** — run git inside each one.

## 1. Discover the changes ("the repos that correspond")

For each repo path in `.` (root), `AI-VL-core`, `AI-VL-backend`, `AI-VL-frontend`:

```bash
git -C <repo> status --porcelain           # anything to review?
git -C <repo> diff                          # unstaged
git -C <repo> diff --cached                 # staged
```

Skip repos with a clean tree. For untracked files, read them in full (no diff base).
List up front which repos have changes and what files, so the user sees the scope.

## 2. Read the changed files and their diffs

Read the actual changed regions (and enough surrounding code to judge them). Note
each file's repo — the rules differ per repo.

## 3. Review against the layered checklist

Load **`references/best-practices.md`** (in this skill dir) — it is the review
standard, with per-repo rules and severities. Apply, in order:

1. **Ecosystem directives (blocking):** English-only (+ `FIX.txt` exception in
   core), no `git commit`/`push` introduced, the network-by-port boundary (no
   cross-app imports/paths; frontend→backend only; backend knows iacore only via
   `IACORE_URL`).
2. **Repo-specific invariants:** frontend (bun-not-npm, effect cleanup,
   one-frame-in-flight, `config.ts` is the only URL source, container/
   presentational, Tailwind theme in `index.css`); backend (single-file `app.py`,
   shared `httpx.AsyncClient` + lifespan, no blocking calls in `async def`, no model
   deps); iacore (don't block the event loop, lazy-import heavy deps, `service.py`
   is the only networked surface, the VLM→VLA JSON contract, `PROJECT_ROOT` paths).
3. **General + stack best practices:** everything else in the reference.
4. **No duplication:** does the new code reimplement something that already exists?
   Check within the diff, and against the codebase with `search_code` /
   `search_graph` on the affected repo's project. Flag divergence from the shared
   sources of truth (`vlm_common.py`, `types.ts`, `config.ts`, the proxy helpers).
5. **Goals compliance:** the change serves the live-video industrial-inspection PoC
   (valid JSON contract for the VLA stage, latency awareness, independently
   deployable tiers) and doesn't quietly break a cross-tier contract.

For duplication and contract checks, prefer the live codebase-memory graph over
assumptions; if the code changed structurally, note that a reindex may be needed
(the SessionStart/Stop hook handles it).

## 4. Report

Group findings **by repo**, most-severe first, each as:

- `path:line` — **[blocker|warn|nit]** one-line issue → concrete fix.

End with a short per-repo verdict (e.g. "AI-VL-frontend: 1 blocker, 2 warns" /
"AI-VL-backend: clean") and an overall summary. If a repo is clean, say so. Do not
restate the whole diff — only what needs attention.

If the user then asks to apply fixes, make the edits in the working tree and
re-review, but still leave committing to the user.

## Complement

For deep correctness/bug hunting on a single diff, the built-in `/code-review`
skill is heavier and more adversarial; `/cr` is the fast ecosystem-wide gate that
also enforces *these* project conventions. Use both when the change is risky.
