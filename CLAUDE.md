# CLAUDE.md

Guidance for Claude Code at the **ecosystem root** — the wrapper repo that holds
only the launchers (`linux/`, `win/`) and the top-level docs. The three apps are
**independent git repos**, each with its own CLAUDE.md, and are NOT part of this
repo:

```
frontend (browser UI)  ──HTTP/WS──▶  backend (gateway)  ──HTTP──▶  iacore (inference)
   AI-VL-frontend                     AI-VL-backend                 AI-VL-core
```

## Language: English only — absolutely everything

Everything in EVERY repo of this ecosystem is written in **English — absolutely
everything**: comments, docstrings, identifiers / function names, all user-facing
strings (menus, prints, CLI/argparse help, UI text), **the shell and PowerShell
launchers (`*.sh`, `*.ps1`)**, config keys, and the READMEs / docs. The user
converses in Spanish (Rioplatense) — that is fine for **chat only**; never put
Spanish into code, scripts, or docs. (The single exception is
`AI-VL-core/FIX.txt`, which must not be translated or touched.)

## Never commit

**NEVER run `git commit` or `git push`** in any repo. Make edits, verify, and
report — the user reviews and commits everything manually.

## Layout of this repo

- `linux/` — `install.sh`, `run.sh` launchers for Linux (run mode = phone/HTTPS).
- `win/` — the PowerShell equivalents (`install.ps1`, `run.ps1`).
- `certs/` — self-signed TLS certs generated per machine/IP (git-ignored).
- The three app repos are cloned as sibling directories and git-ignored here.

`run.sh` builds the frontend, then starts iacore (`:8001`) and the backend over
HTTPS (`:8443`) serving the SPA + `/api` + `/ws` on one origin, and opens the
server monitor (`/monitor`) in the local browser.

## Skills

- **`/cr`** — code review of all uncommitted changes across the four repos against
  the project conventions, goals, code duplication, and the shared best-practices
  standard (`.claude/skills/cr/references/best-practices.md`). Read-only; never
  commits. Run it before committing.
- **`cross-tier-feature`** — the procedure for threading a capability through the
  three tiers (frontend → backend → iacore): where each piece lives and how to keep
  the contract consistent. Read it whenever a change spans more than one repo or
  adds/modifies an HTTP/WS route.
- The iacore repo also ships an **`ollama-vlm-tuning`** skill for deep VLM/model
  tuning (VRAM, `qwen3-vl` checkpoints, `num_ctx`/`num_predict`, latency).

## Code intelligence (codebase-memory)

`.mcp.json` ships a local `codebase-memory-mcp` server that indexes all four repos
into a knowledge graph (functions, routes, cross-repo HTTP links). **Prefer it over
hand-maintained tables** for code structure/endpoints: `get_architecture`,
`search_graph`, `search_code`, `trace_path`. The graph is kept fresh automatically
by `.claude/hooks/reindex-if-needed.sh` (SessionStart/Stop; re-indexes a repo only
when its git signature changed). Setup and re-index details are in `README.md`.
