# Tech stack — what we use, what it does, why, and what else there is

One page for "what is this built on". Each piece says what job it does, why it was chosen,
and which alternatives exist or were tried. It covers both halves of the workspace: the
AI-VL app (this repo and its three child repos) and the robot side (`robot-ecosystem/` and
the `unitree_ros2` fork). Written 2026-10-16 from the code, not from memory; where a doc and
the code disagree, the code won and the disagreement is listed at the end.

Measured model choices (VLM, speech-to-text, text-to-speech) have their own file with every
number: [`AI-VL-core/docs/MODEL_BENCHMARKS.md`](../AI-VL-core/docs/MODEL_BENCHMARKS.md).

```
 phone / PC browser ──HTTPS+WS──▶ backend :8443 ──HTTP──▶ iacore :8001 ──▶ llama-server :8081 (VLM)
   React UI                       FastAPI gateway        YOLO, Whisper,     Ollama :11434 (fallback)
      │                                 │                Piper, VLM client
      │ WebRTC (WHEP)                   │ HTTP
      ▼                                 ▼
 mediamtx :8889 ◀── SRT bridge ◀── robot video        robot_executor :8090 ──HTTP+UDP──▶ relay :8092 on the robot
                                   (GStreamer, HW H.264)                                  └─ C++ senders ─DDS─▶ Unitree services
 Splunk :8088 ◀── HEC ── telemetry agent on the robot (C++ reader + Python shipper)
```

The rule behind the whole layout: **DDS stays short and local, HTTP goes long and routed.**
Measured on a Go2: 122 DDS topics visible from the robot's own subnet, 2 from a routed one.
So everything that speaks DDS runs on the robot, and only HTTP, UDP, SRT and HTTPS cross the
network (`robot-splunk-docs/RED-Y-DDS.md`).

---

## 1. Frontend — `AI-VL-frontend`

| Technology | Job | Why | Alternatives |
|---|---|---|---|
| React 19 + TypeScript 6 | The UI: Live, Drive, Robot, Video, Joints pages | Typed props across a large UI; `any` is banned at the boundary | — |
| Vite 8 | Dev server (:5173) and production build | Fast builds. No dev proxy: "Vite's WebSocket proxy is unreliable for our binary frame stream" | — |
| Bun | Package manager and runner | Project rule: bun only, never npm (pre-commit and CI enforce it) | npm, pnpm |
| Tailwind CSS v4 | Styling; theme as CSS `@theme` tokens, no config file | Utility classes, one theme source | — |
| React Router 7 | Routes `/`, `/drive`, `/robot`, `/video`, `/joints` | Joints is lazy-loaded so the drive pad never pays for a 3D engine | — |
| Tabler icons | Every icon | Project rule: icons, never emojis | — |
| three.js 0.169 + urdf-loader 0.12.3 (pinned exactly) | The G1 in 3D, posed live from its joint state | Loads Unitree's URDF directly. Meshes are decimated by `scripts/build_g1_model.py` (the full set is ~100 MB, too heavy over LTE) | — |
| Vitest 4, ESLint 10 | Unit tests (8 files, 44 cases), lint | — | — |

Browser APIs it relies on:
- **getUserMedia + MediaRecorder** record the camera and the voice (webm/opus or mp4/aac; Whisper decodes both).
- **Web Speech API** listens for the wake word "robot" only. On Chrome/Safari this is cloud-backed; the command itself is transcribed locally by Whisper.
  - Alternatives: a local wake-word engine (openWakeWord, Porcupine) would keep even this offline.
- **WebCodecs `VideoDecoder`** decodes the all-intra H.264 drive stream onto a canvas. 0.7 ms per frame, no jitter buffer.
- **WebRTC (WHEP)** plays the 1080p H.264 from mediamtx. This is the only path that skips the backend.
- **Gamepad API** for a physical controller.

Three video transports, picked per robot in the UI:

| Transport | Bitrate | Delay | Notes |
|---|---|---|---|
| **MJPEG over WS** (default) | ~8.9 Mbps per viewer | lowest on a clean link | "the path that has always worked"; retired for the Go2 |
| **H.264 over WHEP** | 1.4 Mbps once; mediamtx fans it out | ~300 ms jitter buffer | — |
| **Intra H.264 over WS** | ~4.2 KB per frame vs ~9 KB for JPEG | no jitter buffer | — |

---

## 2. Backend gateway — `AI-VL-backend`

| Technology | Job | Why | Alternatives |
|---|---|---|---|
| FastAPI 0.139 + Uvicorn 0.49 | The one origin the browser talks to: `/api/*` REST, `/ws/*` WebSockets, the built SPA | Python like iacore; async fan-out. "Start with FastAPI, split out a Kotlin gateway later" (`AI-VL-core/docs/ARCHITECTURE.md` §3) | Kotlin/Spring (deferred) |
| httpx | Calls iacore, the robot executor and the camera bridge | Async, keep-alive | — |
| Self-signed TLS (OpenSSL in `run.sh`) | HTTPS so a phone may use its camera and mic over the LAN | Browsers only allow getUserMedia on HTTPS or localhost. The cert is regenerated when the IP changes | A reverse proxy (not needed) |

Design points:
- **It never decodes video.** It relays bytes; the robot encodes and the browser decodes. There is no OpenCV or PyAV here.
- Each viewer gets a newest-frame-only queue (`maxsize=1`), so a slow phone drops frames instead of falling behind.

---

## 3. AI core — `AI-VL-core` (iacore)

| Technology | Job | Why | Alternatives |
|---|---|---|---|
| **Ultralytics YOLO** (8.4, `yolo11s.pt`, 320 px, class `person`) | Boxes on the live stream, many frames per second | Fast, closed-vocabulary, runs on the GPU next to the VLM. Same JSON contract as the VLM | RT-DETR (transformer detector); YOLO-World or Grounding DINO for open vocabulary (here that job is the VLM's); TensorRT export for the Jetson ("seguime" plan) |
| **Qwen3-VL 4B Instruct** (Q4_K_M GGUF) | Looks at a frame and answers in Spanish; detects as JSON; interprets spoken commands | Best of 9 candidates measured on this card: 0.6 s to the first word, 8/8 facts, 8/8 commands, 4.5 GB | Measured and rejected: Qwen3-VL 2B/8B, Gemma 3 4B, InternVL3 8B, MiniCPM-V 4.5, SmolVLM2 (see MODEL_BENCHMARKS) |
| **llama-server** (llama.cpp, the copy Ollama ships) | Serves the VLM on 127.0.0.1:8081; `run.sh` starts and stops it with the app | Keeps the vision encoder on the GPU: 6.8 s → 0.6 s per question | Ollama alone (encoder on CPU); vLLM (much heavier, more VRAM) |
| **Ollama** 0.30.6 | Fallback VLM server, the CLI tools' server, and the source of the llama-server binary and CUDA 12 libraries | Already installed by `install.sh`; simple model pulls | — |
| **faster-whisper** (CTranslate2), model `small`, GPU int8 | Speech-to-text for every spoken command and question | 2.6 % WER on Argentine speakers in 0.16 s with 482 MB; the old `base` on the CPU erred 8 % | Parakeet TDT 0.6B v3 (CPU, 0.21 s, 4.4 %; plan B); Whisper large-v3-turbo (same accuracy, 2.6× the VRAM); browser speech recognition (cloud) |
| **Piper** (piper-tts 1.4, 5 Spanish voices) | Text-to-speech, sentence by sentence | Local, CPU, 0.1-0.4 s per sentence. The current voice `es_AR-daniela-high` is the only Argentine one but the least intelligible (34 % vs 6-9 %): **replacement under review** | Kokoro (installed, 3 Spain-accent voices, 0.6 s); Kyutai Pocket TTS (0.32 s on GPU); Qwen3-TTS (4 s, too slow here); Chatterbox (3.5-4 GB, does not fit); browser `speechSynthesis`; the robot's own speaker |
| **Kokoro** (kokoro-onnx 0.4.7) | Second local TTS engine, picked by voice name | A notch more natural than Piper | — |
| **The robot's ear** (`ear_common.py`, WS `/ws/ear`) | Alexa-style listening through the G1's own microphone: cuts the stream into phrases by energy, transcribes them, and answers "Bender, …" | Simple energy gate tuned to the measured fan noise (RMS ~0.008 vs speech 0.05-0.11) plus Whisper's own VAD and the "Bender" hotword; no extra model | A trained wake-word model on the robot (openWakeWord), which would also catch "pará" without the link; Unitree's own on-robot ASR (`rt/audio_msg`) |
| **Command interpreter** (`command_common.py`) | Spoken text → one skill JSON (`{skill, params, say}`) per robot | Uses the same VLM. The output is forced by a JSON grammar (llama-server) or `format: json` (Ollama), then validated: unknown skills become `unknown` and params are coerced to their declared type | A small text-only model with function calling; rules or regexes (brittle with free speech) |
| PyTorch 2.12 (CUDA 13) | Under Ultralytics | Pulled in by Ultralytics | — |

Wiring decisions worth knowing:
- **Lazy imports.** Each heavy dependency is imported only when its path runs, so YOLO works without Whisper and so on.
- **Warm-up at startup.** iacore loads Whisper, Piper and the VLM in the background. A fresh app used to take ~9 s on its first question.
- **One backend switch.** `config.json` `vlm_backend` decides between llama-server and Ollama; the env `VLM_BACKEND` overrides it.

---

## 4. Launchers — this repo

| Technology | Job |
|---|---|
| `linux/install.sh` | Installs Python, Bun and Ollama if missing; builds the venvs. Downloads Whisper, the Piper and Kokoro voices, the Ollama model, and the VLM GGUF + vision projector from Hugging Face. |
| `linux/run.sh` | Detects the LAN IP, makes the cert, builds the frontend, then starts the VLM server, iacore (:8001) and the backend over HTTPS (:8443). Ctrl+C stops all three, which frees the GPU. |
| `linux/run-with-robot.sh` | Also starts the ROS2 devcontainer, then the robot executor (:8090) and the camera bridge (:8091) inside it. |
| `win/*.ps1` | The Windows versions. They do not start llama-server yet, so Windows runs the VLM on Ollama. |

---

## 5. Talking to the robots

| Technology | Where | Job | Why | Alternatives |
|---|---|---|---|---|
| **Unitree SDK2** (C++, v2.0.0, static) | Go2 Jetson, G1 PC2 | Native DDS client: typed messages, sport/loco/arm/audio/video clients | One static binary, no runtime dependencies. "Putting ROS2 on the robot is invasive and fragile" (`robot-splunk-docs/PLAN.md`) | unitree_sdk2_python (recommended on paper, not installed, unused) |
| **CycloneDDS** 0.10.2 (bundled) | robots | Unitree's internal bus | It is what the robots speak; bound to `eth0`, BEST_EFFORT | Bridging DDS over the network: L2 tunnel (rejected: two robots share `.161`), zenoh-bridge-dds or eProsima DDS Router (kept on file for RViz/Nav2 if ever needed) |
| **ROS2 Humble** (devcontainer on the PC) | PC only | Hosts the robot executor and the camera bridge, plus legacy DDS transports and RViz tools | It was prebuilt when the Python SDK was missing. **Commands no longer go through it**: both robots use the relay. Plan: an SDK transport, then drop ROS2 unless RViz, bags or Nav2 earn it (`docs/TRANSPORT_SDK_VS_ROS2.md`) | The SDK transport |
| **robot-command-relay** (Python 3.8 stdlib HTTP + C++ senders) | robots, port 8092 | The only way commands reach a robot from outside | Safety on the robot itself: bearer token, rate limit, verb allowlist with no passthrough, velocity clamp, dead-man in the C++ sender (1 s), stop on EOF, audit log | A pull design, where the robot polls HQ with no inbound port (recommended in `ARQUITECTURA-REMOTA.md`, not built) |
| **UDP teleop** (port 8097, HMAC-SHA256) | PC ↔ robot | `move` and `stop_move` only, 40-byte signed datagrams | Every HTTP command cost a new TCP connection: 178 ms median over Starlink, and a lost SYN costs a second | HTTP for everything (kept for the other verbs) |
| **G1 arm control** through `rt/arm_sdk` | G1 PC2 | Arms, waist and fingers from the Joints page while the robot's own controller keeps it balanced | All limits live in `joint_ctl_core.hpp`, testable without the SDK: ramps, velocity/acceleration limits, stall guard, release at 75 °C | `rt/lowcmd` (full body; legs only with the robot hanging) |
| **BrainCo Revo 2 hands** over Modbus RTU | G1 PC2, FTDI `/dev/ttyUSB1-2`, 460800 baud | Read and move the 6 fingers of each hand | Their own protocol. Reads are function 04; writes are only registers 1022-1033 | — |
| **Robot audio** | robots | Speak through the robot: Go2 `audiohub` megaphone mode, G1 SDK `AudioClient` | No extra hardware | A USB speakerphone (Go2 audio plan) |
| **G1 microphone** | G1 PC1 → PC2 | PC1 streams the mic array to multicast `239.168.123.161:5555` (16 kHz s16le) only in the voice service's mic mode (voice API 1008, which the SDK does not wrap); the relay switches it and serves `/audio/listen` and `/audio/mic/stream` | The multicast never leaves the robot's internal network, so the relay carries it out, and only while asked | Unitree's app "Voice Assistant" toggle (manual); the Go2's mic, WebRTC only |

---

## 6. Video

| Technology | Where | Job | Why / alternatives |
|---|---|---|---|
| videohub `GetImageSample` (SDK) | both robots | 1080p JPEG frames from the head camera | The native H.264 DDS topic matches but never delivers a sample. The Go2's RTP multicast (`230.1.1.1:1720`) is an option without re-encoding, but loses the bitrate knobs |
| **GStreamer 1.16 + `nvv4l2h264enc`** | robots | Hardware H.264 for the recorder/remote stream and the all-intra drive branch | The Jetson has no ffmpeg but has the hardware encoder. H.265 was rejected: the consumers cannot decode it |
| `mjpeg_server.py` (stdlib) | robots, :8093 | MJPEG `/stream`, H.264 `/h264` (TCP or UDP with XOR parity), snapshots | UDP because TCP over Starlink gave 10 stalls of 250-916 ms in 150 s |
| `camera_source.py` | robots, :8094 | Switches between head camera, RealSense colour and RealSense depth (one at a time) | librealsense on the Go2, V4L2 on the G1 |
| **SRT** + `srt-live-transmit` 1.5.4 bridges | robot → PC | Carries the H.264 over LTE | RTMP over TCP collapsed on a lossy link: 15 fps arrived as 1.9. A bridge is needed because the robot's libsrt 1.4.0 handshake is rejected by mediamtx |
| **mediamtx** v1.19 | PC | One source, many consumers: WebRTC :8889, RTSP :8554 | "Decouples the source from the consumer." Not pinned (`setup.sh` takes the latest release) |
| **aiortc** (WHEP reader) | PC, camera bridge | Feeds YOLO and the AI-VL view from WebRTC | ~200-350 ms. Reading the same stream over RTSP with OpenCV adds a fixed 2.4 s |
| **Frigate** 0.14.1 (Docker) | PC | NVR: 3 days of continuous recording of both robots | Its MJPEG is what the Splunk dashboard embeds |

---

## 7. Telemetry and monitoring

| Technology | Where | Job | Why |
|---|---|---|---|
| Telemetry agent (C++ reader → NDJSON → Python HEC shipper) | robots | Battery, IMU, temperatures, joints, pose, events | Reads the low-frequency `rt/lf/*` topics: same payload, 25× less traffic. Batches, disk spool, daily cap |
| **Splunk Enterprise** (on-prem, `192.168.20.200`) | HQ VM | Indexes `go2-robot-data` and `g1-robot-data`; Simple XML dashboards | HTTP Event Collector over HTTPS (self-signed). Dashboard Studio was rejected: no HTML panel for the video |
| **Cisco ThousandEyes** | agent containers on both robots + cloud | Path, loss and latency tests from the robot's point of view | `te-poller` copies the results into Splunk until the official integration is possible (it needs a public trusted endpoint) |
| Meraki Dashboard API poller | HQ | Network devices into Splunk | Same producer pattern as te-poller |

---

## 8. Network

| Technology | Job |
|---|---|
| Cisco IR1101 + Meraki MX (IKEv2 VPN) | The Go2's field router. The robot appears at HQ as `10.1.254.18`; LTE (Telefónica) or Starlink as uplink; GNSS for GPS |
| VLANs (20 servers, 51 "ROBOTS ONLY" Wi-Fi) | Separate segments. One per robot is mandatory if both must be reachable: both use `192.168.123.161` inside |
| Cisco CURWB | Planned wireless backhaul for the G1; **not yet validated with the cable unplugged** |
| Tailscale | Remote desktop to this workstation only. No robot traffic |

---

## 9. Engineering tooling

| Technology | Job |
|---|---|
| codebase-memory MCP | Code graph of all 11 repos for "who calls this"; reindexed after every edit |
| ruff | Python lint with security rules (target 3.11 in the app, 3.8 on the robot) |
| pre-commit | Private-key detection, 512 KB file limit, ruff/pytest or eslint/tsc/vitest |
| GitHub Actions | CI per repo: lint, tests, build; pip-audit as advisory |
| pytest / Vitest | Python and frontend tests; async and WebSocket tests always carry timeouts |

---

## 10. Known gaps and stale docs (2026-10-16)

- **Windows** still serves the VLM with Ollama: `win/run.ps1` pins `VLM_BACKEND=ollama` until it can start llama-server. `win/install.ps1` does not download the Piper/Kokoro voices or the GGUF.
- **Code defaults differ from config.json** in places:
  - YOLO: `yolov8n` in code vs `yolo11s` in config.
  - Whisper: `base`/CPU in code vs `small`/GPU from `run.sh`.
  - The launchers and config are what actually runs.
- **Python dependencies are not locked.** They are `>=` floors with no lock file. Only `bun.lock` pins the frontend; mediamtx and the ThousandEyes image are unpinned too.
- **Stale statements still in docs or comments:**
  - `TRANSPORT_SDK_VS_ROS2.md` says the relay is Go2-only.
  - `robot-video-pipeline/README.md` describes the old PC-side ffmpeg chain.
  - Several Go2 video docs still say RTMP where it now publishes SRT.
  - The relay velocity clamps differ between README, systemd units and env examples.
  - `run-phone.sh` is still referenced in two frontend files.
- **Design doc vs reality.** `AI-VL-core/docs/ARCHITECTURE.md` §6 proposes Redis, MongoDB and MinIO; none is built.
