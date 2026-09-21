# Plan — YOLO must never slow the drive view, and boxes must match their frame

**Status: designed, NOT implemented.** Written 2026-09-16 from a live session with the Go2 on
LTE, two machines attached (one on `/drive`, one on `/live`). Every number here is measured,
not estimated; the method is next to each one.

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
