---
name: cross-tier-feature
description: >-
  Step-by-step procedure for threading a capability through the three-tier AI-VL
  stack (frontend → backend → iacore) — e.g. adding a new endpoint, proxying a new
  route, or wiring a new inference feature end to end. Read this when a change
  touches more than one repo, when you add/modify an HTTP or WebSocket route, or
  when you need to keep the frontend→backend→iacore contract consistent. Explains
  where each piece lives and how to verify the contract against the live
  codebase-memory graph instead of a hand-maintained endpoint table.
---

# Adding a feature across the three tiers

The system is three independent git repos that talk **over the network by port,
never by file path**:

```
frontend (browser UI)  ──HTTP/WS──▶  backend (gateway)  ──HTTP──▶  iacore (inference)
 AI-VL-frontend                       AI-VL-backend                 AI-VL-core
```

iacore owns the models and the real work; the backend is a thin gateway/proxy plus
a live-session hub; the frontend talks **only** to the backend. A new capability
almost always flows in that order: implement it in iacore, expose it through the
backend, then consume it in the frontend.

## The contract is the codebase-memory graph, not a table

Do **not** re-introduce endpoint tables into the CLAUDE.md files — they drift. To
see the current routes and how they connect across repos, query the MCP graph:

- `get_architecture(project=…)` for the shape of one repo.
- `search_graph` / `search_code` to find a route handler or client call.
- `trace_path` to follow a call from the backend proxy into the iacore route
  (cross-repo HTTP edges are indexed).

If you changed code, re-index so the graph reflects it (the SessionStart/Stop hook
`reindex-if-needed.sh` does this automatically; or run it manually).

## 1. iacore — `AI-VL-core/service.py`

Add the route on the FastAPI app (`uvicorn service:app --port 8001`). Existing
routes: `/health`, `/options`, `/classes`, `/detect`, `/vlm`, `/vlm/stream`,
`/transcribe`, `/speak`, `/tts/voices`. Put the actual inference in `src/`
(`vlm_common.py` / `yolo_common.py` / `asr_common.py` / `tts_common.py`, lazy-import
heavy deps) and keep `service.py` as the only networked surface. Emit the shared
JSON contract where relevant (`objects`/`type`/`description`/`reading`/`confidence`/
`bbox`). For deep VLM/model tuning, read the `ollama-vlm-tuning` skill in that repo.

## 2. backend — `AI-VL-backend/app.py`

Add the matching proxy under `/api/*` (or a `/ws/*` relay). The backend holds **no**
model deps and must **not** import iacore's Python — it reaches iacore only via the
`IACORE_URL` env var with `httpx`. Existing surface: `/api/health`, `/api/options`,
`/api/classes`, `/api/vlm`, `/api/vlm/stream`, `/api/transcribe`, `/api/speak`,
`/api/tts/voices`, the `/ws/detect` producer + `/ws/view` monitor (a session Hub
fans one phone's frames out to N monitors), and an optional SPA catch-all when
`FRONTEND_DIST` is set. Follow the existing proxy helpers rather than hand-rolling
new httpx calls.

## 3. frontend — `AI-VL-frontend/src/`

Consume it through the backend only (never call iacore). Typical touch points:

- `src/api/backend.ts` — add the REST helper (or a hook under `src/hooks/` for a WS
  or streaming flow; `useDetectionSocket` keeps **exactly one frame in flight**).
- `src/types.ts` — add the shared contract type.
- `src/config.ts` — the single source of the backend URL; do not hardcode hosts.
  DEV talks to `http://<hostname>:8000`; PROD is same-origin (`""`), the backend
  serving the SPA + `/api` + `/ws`. Wire UI into the container `LivePage`
  (or `MonitorPage` for the read-only monitor) and keep `components/live` and
  `components/ui` presentational.

## 4. Verify end to end

Bring the stack up with the ecosystem launcher (`linux/run.sh` or `win/run.ps1`):
iacore on `:8001`, backend HTTPS on `:8443` serving the SPA + `/api` + `/ws`, and
the `/monitor` page. Exercise the new path in the browser (or with `curl` against
the backend), confirm the backend reaches iacore (`/api/health`), and check the
data round-trips. Re-index so the graph shows the new cross-repo edge.
