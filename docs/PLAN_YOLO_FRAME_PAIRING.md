# Plan — YOLO must never slow the drive view, and boxes must match their frame

**Status: §4 items 1-5 BUILT and proven 2026-09-22; items 6-7 still designed only.** Written
2026-09-16 from a live session with the Go2 on LTE, two machines attached (one on `/drive`, one
on `/live`). Every number here is measured, not estimated; the method is next to each one.

> ### What landed 2026-09-22 — the backend half, with no robot involved
>
> `POST /api/detect` (bounded at 2 MB), `Conn.wants_boxes`, `Hub.wants_boxes()` /
> `fanout_raw()` / `fanout_annotated()`, and a `ws_robot_cam` that **fans out raw first and
> never awaits detection** — at most one in flight, later frames skipped. Plus item 5:
> `useRobotCameraView` now sends `{ boxes }` (per connection) instead of `{ enabled }`
> (shared), so `/drive` can no longer switch detection off for `/live`.
>
> Proof is in `AI-VL-backend/tests/test_yolo_frame_pairing.py` — 7 tests, no network, no GPU,
> no robot: iacore is stubbed by a fake that can be held open mid-detection, which is what
> makes "the raw path did not wait" observable instead of merely asserted.
>
> **The tests were checked by breaking the code on purpose**, because a green suite proves
> nothing about a bug it cannot see:
>
> | mutation applied to `app.py` | what went red |
> |---|---|
> | put the awaited detection back in the producer | `raw_viewer_gets_the_frame_before_detection_resolves` (3.4 s, fails — does not hang) |
> | remove the one-in-flight cap | `annotated_frame_is_the_one_that_was_detected`, `second_frame_is_skipped_while_a_detection_is_in_flight` |
> | gate the producer on shared `enabled` again | those two plus `raw_viewer_gets_the_frame...` |
>
> **Items 6-7 (pair in the BROWSER for the H.264 transport) were deliberately NOT built**, and
> not for lack of time: §7 below, requested the same day, says the analysed frame must follow
> the live selection for the VLM too, and warns that solving it once per consumer produces two
> frame-grab paths that drift. Building §3.2 now means building the half that §7 replaces.
> Design them together.

> Written in English because this repo's `CLAUDE.md` declares English for everything except
> `AI-VL-core/FIX.txt`. Say the word and it moves to Spanish as a declared exception.

## 1. The requirement, as the operator stated it

1. **`/drive` has priority and is never slowed down**, whichever transport it uses (MJPEG or
   H.264). Nothing anyone does elsewhere may add latency to it.
2. With YOLO **off**, `/live` shows exactly what `/drive` shows, at the same latency.
3. With YOLO **on**, the `/live` picture must be **held back until its own boxes are ready**,
   so the operator never sees a box that belongs to a different frame. `/live` gets slower —
   that is intended and accepted.
4. `/live` receives a frame **only when that frame's detection is ready**.
5. None of this touches `/drive`.

## 2. How it works today, and why it does not satisfy that

### 2.1 YOLO sits in the producer, ahead of the fan-out

`AI-VL-backend/app.py:791` (`ws_robot_cam`):

```python
det = empty
if hub.config.get("enabled"):
    r = await client.post("/detect", content=data, params=_detect_params(hub.config))
    det = r.json()
hub.fanout(data, det)          # nobody gets the frame until /detect answers
```

There is ONE producer and every monitor hangs off it, `/drive` included
(`ControlPage.tsx:102` → `useRobotCameraView` → `/ws/view`). So turning YOLO on anywhere
delays the frame for everyone.

**Measured** (third read-only viewer on `/ws/view`, latency from the robot's own capture stamp
to arrival, 20 s per state, robot on LTE):

```
YOLO on :  14.10 fps   p50 110.0 ms
YOLO off:  16.10 fps   p50  98.2 ms
                       -> +12 ms with YOLO on
```

**12 ms is not perceptible**, and the operator correctly reported `/drive` "feeling the same".
The coupling is nonetheless real and it scales with the work: `/detect` on a 480x270 frame
costs ~12 ms, on 1080p ~25 ms (measured directly against iacore, 5 runs each). Raise the MJPEG
resolution or load the GPU and the drive view pays for it, with nothing in the UI explaining
why.

### 2.2 Opening `/drive` switches YOLO OFF for everyone

`useRobotCameraView.ts` seeds the shared flag on connect:

```js
ws.onopen = () => { ws.send(JSON.stringify({ enabled: enabledRef.current })); };
```

and `/drive` passes `enabled = false` (`ControlPage.tsx:102`,
`useRobotCameraView(true, false)`). `hub.config["enabled"]` is a single shared value any client
may overwrite, so **the drive machine reconnecting turns detection off on the live machine.**

### 2.3 The boxes do not describe the picture you are looking at

YOLO always runs on the bridge's MJPEG frames, whatever transport `/live` displays. With the
H.264/WHEP transport the picture goes **browser ↔ mediamtx directly** and never enters the
backend — `RobotCameraStage.tsx` says so in its own docstring: *"this only moves the PICTURE
off that path"*.

So the two halves come from different sources, measured the same afternoon:

| | age on arrival |
|---|---|
| picture (H.264 over WHEP) | **~349 ms** |
| boxes (computed on the MJPEG) | **~89 ms** |

**260 ms apart.** The bboxes are normalized so they land geometrically, but they describe a
moment ~260 ms newer than the frame they are drawn on: a walking person's box sits **ahead of
them**. Confirmed visually by the operator.

## 3. The design

Two delivery paths out of one producer. The rule is **pairing on the annotated path, immediacy
on the raw path**:

```
frame arrives at /ws/robot-cam
   |
   +--> raw viewers      (drive, and live with YOLO off)  -> fan out IMMEDIATELY
   |
   +--> annotated viewers (live with YOLO on):
          if a detection is already in flight -> SKIP this frame entirely
          else -> detect(frame) as a task; when it answers, fan out (that same frame, boxes)
```

Consequences, all intended:

* `/drive` never waits for anything. If nobody asked for boxes, `/detect` is never called at
  all — the 12 ms disappears rather than being tolerated.
* Annotated viewers receive **fewer** frames (the detection rate), each paired with its own
  boxes. That is the "`/live` gets slower" the operator asked for, and it is self-limiting: at
  12-25 ms per detection the ceiling is well above the camera's 14 fps, so expect a delay of
  about one detection, not a rate collapse.
* Skipping rather than queueing keeps the annotated path fresh. A queue is how latency
  accumulates — the same rule `_put_latest` and `mjpeg_server.Latest` already follow.

### 3.1 Intent becomes per connection

`hub.config["enabled"]` stops driving the producer. Each `/ws/view` connection declares
`boxes: true|false` (default **false**), and the producer detects only while at least one
connection wants boxes. `/drive` declares nothing and can no longer change anyone's state.

The rest of the shared config (`model`, `conf`, `imgsz`, `classes`) stays shared — that part
is a feature.

### 3.2 The H.264 case must be paired in the browser

The backend cannot hold back a WebRTC picture it never sees. So with the H.264 transport,
`/live` pairs locally:

* **YOLO off** — show the `<video>` element directly. Identical to `/drive`.
* **YOLO on** — grab the frame being displayed, send it for detection, and when the boxes come
  back **draw that same grabbed frame plus its boxes on the canvas**, hiding the live video.
  The video keeps playing underneath; the operator sees analysed frames at the detection rate.

`useDetectionSocket.ts` already implements the hard half of this — it grabs from a `<video>`,
downscales to `imgsz` before encoding, and keeps exactly **one frame in flight**
(`useDetectionSocket.ts:137-158`). Reuse that pacing.

### 3.3 ⚠️ Do NOT reuse `/ws/detect` for it

`ws_detect` (`app.py:692`) ends with `hub.fanout(data, d)`: **it fans the frames it receives out
to the monitors**. Uploading WHEP frames through it would push the live machine's grabs onto
the drive machine's screen, replacing the robot picture. A detect-only endpoint is required.

## 4. The work

**Backend (`AI-VL-backend/app.py`)**

1. `POST /api/detect` — JPEG body in, boxes out. No fan-out, no session state, **bounded body**
   (the engineering standard §2 already flags `/detect` for reading unbounded bodies).
2. `Conn` grows `wants_boxes`; `/ws/view` accepts `{"boxes": bool}` and never lets a viewer
   write the producer's detection state through `enabled`.
3. `Hub.fanout_raw(frame)` and `Hub.fanout_annotated(frame, det)` replace the single
   `fanout`; both keep the one-frame-deep `_put_latest` discipline.
4. `ws_robot_cam` stops awaiting: fan out raw, then launch at most ONE detection task and fan
   out the annotated pair when it resolves.

**Frontend**

5. `ControlPage.tsx` — declare `boxes: false`, stop seeding `enabled`.
6. `LivePage.tsx` — with MJPEG, subscribe as an annotated viewer (server pairs). With H.264 and
   YOLO on, pair locally against the WHEP `<video>` through `POST /api/detect`.
7. `RobotCameraStage.tsx` — expose the video element ref so the page can grab from it, and
   render the analysed still instead of the live video while YOLO is on.

**Tests** (each names the bug it catches)

8. `test_drive_viewer_does_not_change_detection_state` — §2.2.
9. `test_producer_does_not_detect_when_nobody_wants_boxes` — the 12 ms, and the fail-open risk.
10. `test_raw_viewer_gets_the_frame_before_detection_resolves` — the whole point of §3.
11. `test_annotated_frame_is_the_one_that_was_detected` — the 260 ms desync, §2.3.
12. `test_second_frame_is_skipped_while_a_detection_is_in_flight` — never queue.

## 5. How to verify it is done

* Robot moving, `/drive` and `/live` side by side, YOLO **off**: both must look identical.
* Turn YOLO on in `/live`: `/live` visibly slows; the drive view's latency must not move —
  measure it, do not eyeball it (the tool is in §6).
* Someone walking, YOLO on, H.264 selected: **the box must sit on the person, not ahead of
  them**. That is the regression test for §2.3.
* Reload `/drive` while `/live` has YOLO on: detection must stay on.

## 6. Measuring it

`robot-ecosystem/robot-video-pipeline/tests/video-bench/yolo_cost.py`: attaches a third read-only viewer to `/ws/view`,
reads the robot's COM capture stamp out of each JPEG (survives the bridge's pass-through at
`quality=0`/`native`), reports capture→arrival latency, toggles the flag, and restores whatever
it found. Point it at the drive-class viewer and the number must not move when YOLO goes on.

Robot-side video numbers and link state for the same session live in
`robot-ecosystem/robot-splunk-docs/MEDICIONES.md`.

---

## 7. Requested 2026-09-22 — every consumer analyses THE PICTURE ON SCREEN

**Status: requested, not designed.** Raised by the operator while §1-§6 were being built, and it
is a superset of §2.3 rather than a separate wish: *"quiero poder elegir qué imagen usa YOLO,
tiene que ser la que está seleccionada en el live, y eso para todo igual, para VLM también."*

### What it asks for

Today **the source of the analysed frame is fixed in the code, not chosen by the operator**.
`/live` lets you pick a transport (MJPEG or H.264/WHEP), and that choice moves only the
PICTURE. Every consumer keeps eating the bridge's MJPEG whatever is on screen:

| consumer | what it analyses today | where |
|---|---|---|
| YOLO (live path) | always the bridge MJPEG | `app.py` `ws_robot_cam` → `_detect` |
| VLM ("ask about this frame") | always the bridge MJPEG | `useRobotCameraView.getLastFrameBlob()` |
| YOLO (phone path) | the phone's own camera | `/ws/detect` — correct already, different producer |

So with H.264 selected the operator is looking at one picture and asking questions about
another. §2.3 measured that gap at **260 ms** for the boxes; for the VLM it is worse in kind,
because a VLM answer describes a frame nobody ever saw and nothing on screen contradicts it.

### The requirement, stated so it can be tested

1. The transport selected in `/live` is the **single source of truth** for what gets analysed.
2. YOLO boxes describe that picture. (§3.2 already gets this right for the H.264 case; the
   point here is that it stops being a special case and becomes the rule.)
3. The VLM is asked about **that same picture** — the frame the operator is looking at when
   they press the button, not the freshest MJPEG blob the hook happens to hold.
4. Switching transport switches every consumer with it, with no reconnect and no stale frame
   surviving the switch.
5. `/drive` is unaffected, exactly as in §1.

### Why it is not just "do §3.2 twice"

§3.2 pairs YOLO against the WHEP `<video>` inside `LivePage`. Doing the same for the VLM would
put a second frame-grab path in a second component, and the two would drift. The shape that
does not rot is **one grab, many consumers**: a single "current displayed frame" source in the
live page — whichever transport produced it — that both the detection pairing and
`getLastFrameBlob()` read from. `useRobotCameraView` already owns `lastBlobRef` for the MJPEG
case; the H.264 case needs the same thing fed from a canvas grab, behind the same accessor, so
callers never learn which transport they are on.

### ✅ SETTLED 2026-09-22 — ONE selector. What you see is what gets analysed.

Asked whether the analysis source should be selectable apart from the displayed one, the
operator answered: *"yo diría que sea un solo selector, lo mismo que ves en la pantalla."*

So this is a decision, not an open question, and it is the cheaper half of the fork:

* There is **no per-consumer source setting**, no "analyse MJPEG while showing H.264", and no
  second dropdown anywhere in the UI. Anything that offers one is out of scope.
* The transport selector in `/live` is the ONLY input. YOLO and the VLM follow it; neither has
  a source of its own to disagree with.
* That makes "the boxes describe another picture" and "the VLM answered about a frame nobody
  saw" **unrepresentable** rather than merely avoided — there is no state in which the
  displayed frame and the analysed frame can differ, so no test has to police the gap.
* Practical consequence for the build: `getLastFrameBlob()` and the detection pairing must
  read the SAME "current displayed frame", fed by whichever transport is active. One grab,
  many consumers. A caller must never be able to learn which transport it is on — if it can,
  the two paths will drift again the first time someone adds a third consumer.

The measurement in §6 applies unchanged: whatever is built, `/drive`'s latency must not move.
