# Robot control — Unitree G1 via voice (design + environment)

Authoritative note for future Claude Code sessions. Explains **what robot tooling is
installed on this machine**, **where it lives**, and **the plan** to make the Unitree
G1 obey spoken commands ("grab the red can", "walk") using AI-VL as the brain.

> English only (repo convention). A Spanish narrative version for the user lives
> outside the repos at `~/Desktop/CONTROL_POR_VOZ_G1.md` — keep this English file as
> the source of truth for code work.

## Goal

Talk to the robot and have it act:
- *"grab the red can"* → locate it with the camera, compute **where to move the arm,
  distance, target pose and speed**, go, and grasp it with the hand.
- *"walk" / "come here" / "stop" / "turn right"* → locomotion.
- Spoken feedback via TTS.

## Long-term goal — a manipulation skill library

Locomotion is already solved by the SDK. The **long-term objective** is voice-driven
**manipulation** of everyday objects/fixtures, e.g. (user's own examples):

- *"lift the box and put it on the desk"* — pick up an object and place it somewhere.
- *"turn on the light switch"* — small, precise, contact-rich interaction.
- similar small everyday tasks, chosen by voice.

These are **NOT in the SDK** and are what we build. Reality check on scope, so the
plan stays honest:

- Open-ended "say any small task and it does it" is **frontier robotics** (learned
  VLA models). What's realistic is a **library of specific, calibrated skills** that
  grows over time — each skill is semi-bespoke.
- The tasks differ a lot in difficulty. A sane ladder:
  1. **Grasp a chunky object and place it at a fixed spot** — most accessible; a fat
     object tolerates centimeters of error. **Start here.**
  2. **"Box → desk"** — a full **mobile-manipulation** task: walk to object + grasp +
     walk to target + locate the surface + place. Several skills chained + navigation.
  3. **"Light switch"** — hardest of the three despite sounding trivial: millimeter
     precision on a tiny target, and it's a **force-controlled press**, not a grasp.
- The SDK's built-in arm poses (`g1_arm_action_example`) are **fixed choreographies** —
  they can't adapt to a variable object position. Adaptivity is exactly the gap we fill
  with perception-3D + IK.

So: treat the tasks above as the **north star**, but implement them as a growing skill
library, starting from the easy grasp-and-place and escalating.

## Two layers — don't confuse them

A common mix-up: "should I use the ROS2 SDK **instead of** LuckyEngine?" These are
**different categories**, not alternatives:

- **Transport / control layer** — how you talk to the *real* robot. Real choice:
  **`unitree_sdk2`** (or its Python binding) **vs `unitree_ros2`**. Both are official
  Unitree, both DDS. Pick one.
- **Behavior / skill layer** — *what* the robot does. Basic locomotion + gestures are
  **built into the SDK** (see below); custom vision-guided grasping is where you may
  reuse LuckyEngine.

**LuckyEngine never touches the real robot** — it is a simulator + trained assets, not
a control transport. So it is not an alternative to the SDK.

### Built-in G1 capabilities (no LuckyEngine, no custom RL needed)

`unitree_sdk2` ships a **high-level locomotion client** with the balance/walk
controller already inside (`include/unitree/robot/g1/loco/g1_loco_client.hpp`,
example `example/g1/high_level/g1_loco_client_example.cpp`):

- `Move(vx, vy, vyaw)` — walk with a velocity command (this is "walk here" / "come here").
- `StopMove()`, `StandUp()`, `Sit()`, `Squat()`, `BalanceStand()`, `HighStand()`/`LowStand()`.
- Gestures: `WaveHand()`, `ShakeHand()`. Arm control: `g1_arm7_sdk_dds_example.cpp`,
  `g1_arm_action_example.cpp`. Hand: `g1_hand_sdk_example.cpp` / `dex3/g1_dex3_example.cpp`.
- **Remote control ships with the robot** (physical joystick; SDK examples include
  `gamepad.hpp`) — nothing to build.

So voice locomotion ("come here", "stop", "sit", "wave") = STT → command interpreter →
one SDK loco call. **LuckyEngine is NOT involved.** It only matters for custom
**vision-guided grasping** of a specific detected object — and even there the SDK's arm
control + AI-VL perception + your own IK can do it; LuckyEngine stays an optional
blueprint / sim test bench.

## Installed tooling on THIS machine (external to the AI-VL repos)

All installed as sibling projects. **Read them directly** when working on robot
features — don't assume, inspect the code.

| Stack | Path | What it is | Use for |
|---|---|---|---|
| **unitree_sdk2** | `~/Desktop/unitree_sdk2` | Official Unitree **C++ SDK** (DDS). Has the **high-level G1 loco client**, arm/hand clients, audio client, gamepad, and low-level joint control. Python binding = `unitree_sdk2_python`. | **Recommended transport.** High-level locomotion/gestures out of the box (`Move`, `StandUp`, …); arm (`g1_arm7_*`), Dex3 hand, low-level `LowCmd` for custom policies. |
| **unitree_ros2** | `~/Desktop/unitree_ros2` | ROS2/DDS interface to the real G1 (alternative transport). Built workspace + examples. | Same robot, ROS2 flavour: `LowCmd`→`/lowcmd`, `LowState`←`/lowstate`, Dex3→`/dex3/*/cmd`. Choose this only if you want the ROS2 ecosystem; otherwise the SDK (esp. its Python binding) is cleaner for the Python AI-VL stack. |
| **LuckyEngine** | `~/Documents/LuckyEngine` | Closed-engine ("Hazel") **MuJoCo simulator** of the G1 doing walk + pick-and-place, plus trained assets. NOT deployable as-is; NOT a transport. | **Optional.** Source of reusable **RL locomotion policies (ONNX)** (only if you outgrow built-in locomotion), the **grasp state-machine blueprint**, tuned offsets/speeds, and a **sim test bench**. |

**Recommendation:** use **`unitree_sdk2` (Python binding) as the transport**, built-in
loco for movement/remote/gestures, and reserve LuckyEngine for advanced grasping / as a
sim test bench.

### Reusable assets inside LuckyEngine

- **Locomotion policies (ONNX, sim-to-real ready):**
  `Projects/Walking Pick and Place/Assets/ContentVault/Robots/UnitreeG1/Policies/{walker,croucher,rotator,right_reacher}.onnx`
  with `policy_descriptor.*.json` (observation layout) and `PolicyRegistry.yaml`.
  Their action = position targets for the G1's 29 actuated joints → **directly the
  `LowCmd` format**. Run with onnxruntime in a ROS2 node.
- **Grasp FSM (blueprint, not portable code):**
  `Projects/Walking Pick and Place/Assets/Scripts/Client/Source/Tasks/Subroutines/*.cs`
  (approach → reach → close → hold → retract) and tuned constants in
  `GrabUpDownTurnTasks.cs` / `Piper.cs` (hover height, grasp clearance, `ReachSpeed`,
  top-down palm orientation).
- **G1 MJCF model** (standalone MuJoCo test bench):
  `Projects/Walking Pick and Place/Assets/Robots/g1_description/g1_29dof.xml`.
- **Vision-based imitation-learning pipeline** (LeRobot/ACT, real-robot oriented):
  `Projects/Piper Pattern Stacking/tools/{train.py,export_onnx.py,lerobot_convert.py}`.

**Important caveats about LuckyEngine:** the "Hazel" engine is a **closed DLL**
(`.../Assets/Scripts/Binaries/Hazel-ScriptCore.dll`) — IK (`LimbIK`), MuJoCo physics
and ONNX inference run inside it; there is **no engine source** and **no hardware
bridge** (no CAN/serial/ROS2). In sim, object position is read as ground-truth from
the scene graph (`GrabUpDownTurnTasks.cs` `EffectiveGrabPosition()`), so it has **no
perception** — that gap is what AI-VL fills on the real robot.

## The plan (how the pieces connect)

AI-VL is the **brain/perception + language interface**; LuckyEngine provides **skills
and policies**; unitree_ros2 is the **execution layer** on the real G1.

```
🎤 voice
  → STT            (EXISTS: iacore /transcribe, backend /api/transcribe — faster-whisper)
  → Command interpreter (NEW: qwen3-vl with a JSON-skill prompt)
        text (+frame) → intent JSON, e.g. { "skill":"grab", "target":"red can" }
        The VL MODEL SELECTS which skill (from the LuckyEngine-derived skill set)
        and TRANSLATES the spoken request into that skill + params.
  → if the skill needs an object:
        Detection   (EXISTS: iacore /detect, backend /ws/detect — YOLO, bbox normalized 0..1)
        Perception-3D (NEW): bbox center + DEPTH + intrinsics → camera-frame point
                            → hand-eye extrinsics → PELVIS-frame 3D pose
  → Skill executor (NEW, thin — wraps the SDK):
        walk/turn/stop/sit/wave: BUILT-IN SDK loco client (LocoClient.Move / StandUp / …)
        grab (custom): pre-grasp → approach(IK + velocity profile) → close(Dex3) → lift
        → real G1 via unitree_sdk2 (loco client + arm/hand clients)
  → TTS feedback   (EXISTS: backend /api/speak)
```

So, restated in the user's words: **the VL model picks a LuckyEngine skill and
translates the spoken command into it, then that skill is executed through ROS2.**

### What already exists in AI-VL (do not rebuild)

- **STT** — `AI-VL-core/src/asr_common.py` → `/transcribe` (backend `/api/transcribe`).
- **TTS** — `AI-VL-core/src/tts_common.py` → backend `/api/speak`, `/api/tts/voices`.
- **VLM** — `AI-VL-core/src/vlm_common.py` (`query_vlm`, qwen3-vl via Ollama) → `/vlm`.
- **YOLO** — `AI-VL-core/src/yolo_common.py` → `/detect`, live `/ws/detect`. Returns
  `{"objects":[{type,description,confidence,bbox}]}`, **bbox normalized 0..1
  `[x_min,y_min,x_max,y_max]`** (`yolo_common.py:239`).
- Networked entrypoint: `AI-VL-core/service.py` (`:8001`); gateway `AI-VL-backend/app.py` (`:8443`).

### What is NEW (to build in AI-VL / a new ROS2 node)

1. **Command interpreter** — iacore module/endpoint (e.g. `command_common.py` +
   `POST /command`) that maps text (+optional frame) → intent JSON over a fixed skill
   schema (`grab`/`place`/`walk`/`turn`/`stop`/`describe`). Reuses `query_vlm`.
2. **Perception-3D** — bbox + depth + camera intrinsics + hand-eye extrinsics → 3D
   pose in the pelvis frame. Deprojection: `X=(u-cx)Z/fx`, `Y=(v-cy)Z/fy`, then
   `T_pelvis_camera · (X,Y,Z)`. **Needs the G1's depth camera model + calibration.**
3. **Arm motion planner** — target grasp pose = object + approach offset; distance =
   ‖grasp − current hand (FK from /lowstate)‖; **trapezoidal/quintic velocity profile
   with a Cartesian speed cap** (reuse `ReachSpeed`/`DriveTo` durations from the sim);
   **arm IK** for the 7-DOF arm (pinocchio / PyRoki / ik-geo, or the unitree arm
   example) — since `LimbIK` is inside the closed engine and can't be reused.
4. **Skill executor** — thin layer that maps an intent to SDK calls: locomotion/
   gestures go straight to the **built-in loco client** (`Move`, `StandUp`, `StopMove`,
   `WaveHand`, …); only `grab` runs the custom IK + velocity-profile motion via the
   SDK arm/hand clients. Enforces a watchdog + safe rest posture. Deploying a
   LuckyEngine `walker.onnx` at `LowCmd` level is a **later option**, only if the
   built-in walking isn't enough.

## Roadmap (phased)

0. **Prereqs (once):** build `unitree_sdk2` (or install `unitree_sdk2_python`); run the
   `g1_loco_client_example` to confirm connectivity and move the robot safely.
1. **Voice→intent:** `POST /command` (reuses `query_vlm`); loop transcribe→command→speak.
2. **Locomotion by voice (easiest win, no LuckyEngine):** wire `walk`/`turn`/`stop`/
   `sit`/`wave` to the built-in loco client (`Move`, `StandUp`, `StopMove`, `WaveHand`).
   "Come here / stop / wave" working end-to-end.
3. **Perception-3D:** bbox + depth + intrinsics + hand-eye → pelvis-frame pose (verify
   vs tape measure). Needs the G1 camera model.
4. **`grab` skill (custom, harder):** IK + velocity profile via SDK arm/hand clients;
   test in standalone MuJoCo (`g1_29dof.xml`) first, then on the secured robot. Reuse
   the LuckyEngine grasp FSM/offsets as the blueprint.
5. **Full integration + robustness:** chain everything; spoken error handling;
   (medium term) move fine grasping to LeRobot/ACT (`Piper Pattern Stacking/tools/`).

## Constraints

- **English only** everywhere in these repos; **never** `git commit`/`push` (user does it).
- Depth reliability is the biggest risk; if the onboard camera can't give trustworthy
  metric depth, favor the learning path (ACT) which doesn't rely on precise deprojection.
- The G1 falls: always keep a safe rest posture reachable; gate motion behind a watchdog.
