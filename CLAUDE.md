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

## Robot control (Unitree G1) — read `ROBOT_CONTROL.md`

There is an active goal to drive a **real Unitree G1** by voice through AI-VL.
Locomotion is already solved by the SDK; the **long-term north star is voice-driven
manipulation** ("lift the box onto the desk", "turn on the light switch", small
everyday tasks) — built as a growing **skill library**, starting from easy
grasp-and-place and escalating (mobile-manipulation, precise/contact tasks are harder).
Two layers, don't confuse them: a **transport** (how to talk to the real robot) and
**behaviors** (what it does). Three stacks are
**already installed** on this machine as sibling projects — inspect them directly:

- **`~/Desktop/unitree_sdk2`** — official Unitree **SDK** (recommended transport;
  Python binding = `unitree_sdk2_python`). Ships a **high-level G1 loco client**
  (`Move`, `StandUp`, `StopMove`, `WaveHand`, …) with balance/walk **built in**, plus
  arm/hand clients and gamepad remote. Locomotion & gestures need **no** LuckyEngine.
- **`~/Desktop/unitree_ros2`** — alternative ROS2 transport to the same robot
  (`/lowcmd`, `/lowstate`, `/dex3/*/cmd`). Use only if you want the ROS2 ecosystem.
- **`~/Documents/LuckyEngine`** — closed-engine MuJoCo **simulator** (NOT a transport,
  never touches the real robot). Optional: reusable RL policies, grasp blueprint,
  tuned offsets, sim test bench — mainly for advanced vision-guided grasping.

The plan: AI-VL is the brain — STT (exists) + a VLM **command interpreter** (text →
skill JSON) + **perception-3D** (YOLO bbox + depth + hand-eye → pelvis-frame pose) +
a thin **skill executor**. **Locomotion/gestures = built-in SDK calls** (easy);
**custom grasping = SDK arm/hand + own IK + AI-VL perception** (reuse LuckyEngine's
grasp FSM/offsets as blueprint). STT/TTS/VLM/YOLO already exist here.
**Full details, file pointers and roadmap: [`ROBOT_CONTROL.md`](ROBOT_CONTROL.md).**

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
