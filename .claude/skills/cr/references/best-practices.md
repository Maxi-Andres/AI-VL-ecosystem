# AI-VL code best practices (the /cr review standard)

Curated for **this** ecosystem — not a generic checklist. Rules are grounded in the
actual code (a stateless single-file backend gateway, a modular `src/` iacore, a
React-hooks frontend). Skip anything that doesn't apply to a small PoC (no DB
layers, no repository pattern, no API versioning here).

Severity legend used by `/cr`: **[blocker]** breaks a hard rule or is a real bug ·
**[warn]** should fix · **[nit]** optional polish.

## 0. Cross-cutting (every repo)

- **[blocker] English-only — absolutely everything**: comments, docstrings,
  identifiers, user-facing strings, config keys, shell/PS scripts, docs. The sole
  exception is `AI-VL-core/FIX.txt`. Spanish belongs in chat only.
- **[blocker] Never introduce `git commit` / `git push`** (in code, scripts, or by
  running it). The user commits.
- **[blocker] The network boundary**: the three apps talk by URL/port, never by
  file path. No cross-app Python import or filesystem reference. Frontend talks
  only to the backend; backend reaches iacore only via `IACORE_URL`.
- **[warn] DRY / no duplication**: before adding a helper, check it doesn't already
  exist. Search the graph (`search_code`, `search_graph`) and the diff. iacore
  centralizes shared logic in `src/vlm_common.py`; the frontend contract lives once
  in `src/types.ts`; the backend URL lives once in `src/config.ts`. Reimplementing
  any of these is a finding.
- **[warn] Small, focused changes**: one concern per commit-worthy chunk; delete
  dead code rather than commenting it out; no stray debug prints/`console.log`.
- **[warn] No secrets / hosts hardcoded**: configuration comes from env
  (`.env.example`) or the single config module, never inlined.
- **[nit] Naming & clarity**: descriptive names, match surrounding style, comment
  the *why* not the *what*.
- **[warn] Keep code-intelligence fresh**: after structural changes, the
  reindex hook refreshes codebase-memory — don't reintroduce hand-maintained
  endpoint/layout tables in the docs.

## 1. Python — iacore (`AI-VL-core`) & backend (`AI-VL-backend`)

- **[blocker] Don't block the event loop.** A FastAPI `async def` handler must not
  call blocking I/O or heavy CPU work directly. Options: declare the handler `def`
  (FastAPI runs sync handlers in a threadpool), wrap the blocking call in
  `await run_in_threadpool(...)`, or use an async client.
  *Known gap:* iacore's `service.py` endpoints (`/vlm`, `/vlm/stream`, `/detect`,
  `/transcribe`, `/speak`) are `async def` but the work uses blocking
  `requests.post(...)` (`src/vlm_common.py`) and in-process Ultralytics — a long VLM
  call (15–25 s) currently stalls the whole service. Flag new code that repeats this.
- **[warn] Reuse one HTTP client with timeouts.** Backend does this right: a
  module-level `httpx.AsyncClient` with explicit `httpx.Timeout(...)` created in the
  `lifespan` and closed with `await client.aclose()`. Don't create a client per
  request; always set timeouts (never unbounded).
- **[warn] Validate external input with Pydantic models**, not raw `payload: dict`
  (both `service.py` and `app.py` take `dict` today) — typed request models catch
  malformed input at the edge and document the contract.
- **[warn] Lazy-import heavy/optional deps** (`ultralytics`, `faster_whisper`,
  `piper`) inside the function that needs them, so the other paths run without them
  — iacore already relies on this; keep it.
- **[warn] Resource safety**: use context managers (`with requests.post(..., stream=True) as r`),
  no bare `except:` (catch specific exceptions), and prefer `logging` over `print`
  in `service.py` (prints are fine in the CLI `menu.py`).
- **[blocker] Preserve the VLM→VLA JSON contract**: keys `objects`/`type`/
  `description`/`reading`/`confidence`/`bbox`, the `type` enum, and scope `all`.
  Both detection paths must emit the same shape; bboxes normalized 0–1.
- **[warn] Paths resolve from `PROJECT_ROOT`**, not from `src/`.

## 2. TypeScript / React — frontend (`AI-VL-frontend`)

- **[blocker] bun only** — `bun install|add|run`. Never `npm`/`yarn`.
- **[warn] Type the boundary, no `any`**: TS is strict — keep it. Backend-contract
  types live in `src/types.ts`; extend them there rather than inlining shapes.
- **[blocker] Every effect cleans up**: each `useEffect` that subscribes must return
  a cleanup — every `addEventListener` has a matching `removeEventListener`, every
  socket/`getUserMedia` stream/`AbortController` is closed on unmount. Leaks and
  "setState on unmounted component" come from missing cleanup.
- **[warn] One concern per effect**: don't bundle unrelated side effects into one
  `useEffect`; split them so deps and cleanup stay honest.
- **[warn] Async/fetch discipline in hooks**: track loading + error, cancel in
  flight on unmount/param change, and guard against races. The detection socket's
  **one-frame-in-flight** rule (`useDetectionSocket`) is the canonical example —
  don't queue unbounded frames.
- **[warn] Custom hooks**: name `use*`, return a typed tuple/object, keep them
  focused and reusable; obey the rules of hooks (no conditional hooks).
- **[warn] Container vs presentational**: state and wiring in `LivePage`/
  `MonitorPage`; `components/live` and `components/ui` stay presentational.
- **[blocker] One source for the backend URL**: `src/config.ts`. Never hardcode a
  host or point at iacore. Tailwind theme stays in `src/index.css` `@theme` (no
  `tailwind.config.js`).

## 3. Docs & scripts

- **[warn] CLAUDE.md stays short** — always-on directives only; reference/lookup
  material goes to a skill or the codebase-memory graph.
- **[blocker] Shell/PowerShell launchers in English**, robust (`set -u`, guard
  external commands, never fail a session silently in the wrong direction).

## Sources

Curated and filtered against this codebase from:
- [FastAPI production best practices (2026)](https://dev.to/apaksh/building-production-ready-apis-with-fastapi-in-2026-the-complete-playbook-5hlb) · [async/httpx practices](https://pratikpathak.com/fastapi-async-production-practices/) · [Auth0 FastAPI best practices](https://auth0.com/blog/fastapi-best-practices/)
- [React 19 hooks guide](https://reactuse.com/blog/react-19-hooks-guide/) · [Custom hooks best practices](https://dev.to/austinwdigital/mastering-custom-react-hooks-best-practices-for-clean-scalable-code-40b1) · [Handling side effects with custom hooks](https://oneuptime.com/blog/post/2026-01-24-handle-side-effects-custom-hooks/view)
