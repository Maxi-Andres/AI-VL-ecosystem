# Transport: native SDK vs ROS2 — decision record

**Status:** open, deliberately deferred. Written 2026-08-27.
**Decision to take:** migrate AI-VL's robot transport from `unitree_ros2` (rclpy) to
`unitree_sdk2` (native, via its Python binding), and delete the ROS2 path unless the ROS2
tooling is actually being used.
**Not now:** this touches the code that moves robots. It goes after the P0 safety items.

## What is implemented today

The rule the code follows, without exception: **what runs on the robot uses the native SDK;
what runs on this PC uses ROS2.**

| Component | Runs on | Transport |
|---|---|---|
| `robot-telemetry-agent/src/telemetry_reader.cpp` | robot | native — `channel_subscriber.hpp` |
| `robot-command-relay/src/command_sender.cpp` | robot | native — `go2::SportClient` |
| `robot-video-pipeline/src/go2_jpeg_stream.cpp` | robot + PC | native — `go2::VideoClient` |
| `unitree_ros2/robot_executor/` | PC (devcontainer) | ROS2 — rclpy + `unitree_api` |
| `unitree_ros2/robot_camera_bridge/` | PC (devcontainer) | ROS2 — rclpy + `unitree_api` |

## Why native on the robot — this part is settled

1. **No runtime dependencies.** `build.sh` says it plainly: *"No cmake, no ROS2. Works
   unchanged on x86_64 and aarch64 because the SDK ships a static library for both."* The
   output is one static binary. Installing ROS2 Humble on the robot's Jetson would be a large,
   fragile footprint on the machine that has to walk around.
2. **The versions do not line up.** The robot is Ubuntu 20.04 with Python 3.8 — which is why
   everything deployed there is deliberately stdlib-only. ROS2 Humble targets 22.04 / Python
   3.10.
3. **The safety envelope wants the shortest stack.** `command_sender` is the last thing
   between the network and the robot's legs.

None of this is in question. The open decision is only about the PC side.

## The recorded decision was the opposite of what got built

`ROBOT_CONTROL.md` is unambiguous, and it even states an order:

- On `unitree_sdk2`: *"**Recommended transport.** High-level locomotion/gestures out of the
  box"*.
- On `unitree_ros2`: *"Choose this only if you want the ROS2 ecosystem; otherwise the SDK
  (esp. its Python binding) is cleaner for the Python AI-VL stack."*
- And the phase plan: *"a thin `RobotTransport` interface with two implementations:
  `unitree_sdk2` (Python, **now**) and `unitree_ros2` (added when Nav2 arrives, since Nav2 is
  ROS2-native)."*

So the plan was **SDK now, ROS2 later when Nav2 needs it.** What exists is ROS2 now and no SDK
transport at all. (`ROBOT_CONTROL.md` also contradicts itself on this: §121 calls unitree_ros2
"the execution layer on the real G1" while §140 draws the arrow through `unitree_sdk2`.)

### Why it happened

Not a considered reversal — the path of least resistance:

- **`unitree_sdk2_python` is not installed on this machine.** Verified 2026-08-27. So the
  recommended transport had no working Python entry point, and ROS2 was the only Python route
  actually available.
- The devcontainer Unitree ships was already built, with `cyclonedds_ws` and the
  `unitree_api` / `unitree_go` message packages compiled. Zero setup to start talking.
- AI-VL is Python end to end, so rclpy sat naturally next to FastAPI.

## What the split costs today

1. **The command vocabulary is defined twice.** `go2_commands.py` + `g1_commands.py` (api_id
   tables, clamps, `DANGEROUS_SKILLS`) and `command_sender.cpp` (SportClient dispatch table,
   clamps, dead-man). Two allowlists and two clamp implementations that can drift — and
   already have: the fail-open defaults (`SAFE_MODE=False` at
   `robot_executor_service.py:89`, `continuous=True` at `go2_commands.py:127` and
   `g1_commands.py:279`) exist only in the ROS2 half. The native half is the stricter one.
2. **Capability asymmetry.** The ROS2 executor covers G1 and Go2; the native relay is
   **Go2-only** (`go2::SportClient`). So the itinerant path — the one that works once the
   robot leaves the subnet — does not support the G1 at all, which is the robot on the
   wireless VLAN.
3. **Work reimplemented that the SDK gives for free.** The executor's own docstring admits
   it: each request carries a unique `header.identity.id` and waits for the matching
   `/api/*/response`, *"this is what the official Unitree clients do — see
   base_client.hpp"*. That is `SportClient`'s job.
4. **The privileged container exists because of ROS2.** `privileged: true`,
   `network_mode: host` and a mounted `/var/run/docker.sock`, hosting an unauthenticated HTTP
   service that moves robots. That is the price of the devcontainer, and nothing else needs
   it.
5. **On the itinerant path ROS2 contributes nothing.** With a robot's transport set to
   `relay`, the executor only POSTs HTTP and the DDS publishing happens natively on the robot.
   Same for video: `camera_sources.HttpStreamSource` states it *"needs no ROS entities and no
   DDS at all"*. So on the path that is the project's future, the ROS2 dependency is dead
   weight.

## The migration is an addition, not a rewrite

The abstraction the recorded decision called for **was built**. `robot_executor_service.py`
has a `RobotTransport` ABC with four implementations —`Go2Ros2Transport`, `G1Ros2Transport`,
`RelayTransport`, `UnsupportedRobotTransport`— selected in `_get_transport()` by a small
if/elif on mode and robot. A native implementation is two more branches. Nothing above it
changes: not the HTTP layer, not the backend, not the frontend.

### Feasibility: the SDK has the high-level clients for both robots

```
go2/sport/sport_client.hpp          what command_sender already uses
go2/video/video_client.hpp          what go2_jpeg_stream already uses
g1/loco/g1_loco_client.hpp          G1 locomotion
g1/arm/g1_arm_action_client.hpp     G1 arms — the manipulation north star
g1/audio/g1_audio_client.hpp        the G1 "say" skill
```

Everything the ROS2 executor does for the G1 exists natively. The gap is the Python binding,
not the capability.

### Order of work

1. Install `unitree_sdk2_python` and prove one round trip: a `StandUp` on the Go2 with
   `DRY_RUN` off, from the host, no container.
2. Add `Go2SdkTransport` alongside `Go2Ros2Transport`, selected by a new
   `GO2_TRANSPORT=sdk` value. Keep both paths live and switchable from the Robot page.
3. Same for `G1SdkTransport` using `g1_loco_client` + `g1_arm_action_client` + audio. This is
   also what unblocks G1 support on the itinerant relay path.
4. Collapse the duplicated command tables: one source of truth for verbs, clamps and the
   dangerous-skill set, shared by the executor and the relay.
5. Delete the ROS2 transports, and with them the devcontainer — which closes the privileged
   container finding for free.

Steps 1-3 are additive and reversible; nothing is removed until step 5.

## What would justify keeping ROS2

The criterion `ROBOT_CONTROL.md` already states: *only if you want the ROS2 ecosystem.*
Concretely — rviz for visualization, `ros2 bag` for recording sessions, Nav2 for autonomous
navigation (the phase plan's stated reason to add ROS2 later), or the `go2_visualization`
URDF work. If those are in real use, keeping both transports behind the existing abstraction
is legitimate; the duplicated command vocabulary from cost 1 still has to be fixed either
way.

If they are not in use, the ROS2 dependency is being paid for without being collected.
