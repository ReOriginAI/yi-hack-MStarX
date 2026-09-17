# MStarX Future Optimization Roadmap

This document is a **forward-looking plan** for `yi-hack-MStarX`, with the Y23 platform as the first validation target. Nothing in the roadmap should be treated as implemented until it is represented in tracked source/build/install code and verified on hardware.

The roadmap is based on the 28 fork-only commits in `ReOriginAI/yi-hack-Allwinner-v2X` (`upstream/master..master`, reviewed 2026-09-17). The goal is to port the *optimization strategy*, not blindly copy Allwinner-specific patches or binary offsets.

## What the Allwinner v2X fork optimized

The important optimization/reliability work in the fork can be grouped into these areas:

1. **Vendor `rmm` ablation**
   - model-specific `rmm` patches bypassed irrelevant AI/raw-analysis/tracking work while preserving video/audio/media initialization.
   - VIPP/channel use was reduced where live testing proved extra paths unnecessary.

2. **Kernel allocation pressure**
   - y623 received a VE debugfs allocation patch to avoid fragile high-order contiguous allocations.
   - this is Allwinner-specific and is a lesson to inspect allocator behavior on MStar, not a patch to copy directly.

3. **Lightweight local motion**
   - replaced heavier vendor/local motion paths with cheaper model-specific sources where practical.
   - motion was decoupled from cloud behavior and made optional for NVR/Frigate-heavy deployments.

4. **Minimal embedded go2rtc**
   - built a smaller Yi-specific go2rtc configuration rather than carrying unnecessary generic features.
   - used direct producer pipes and hardened stream lifecycle handling.

5. **Streaming producer fixes**
   - fixed `h264grabber` producer I/O and lock behavior around malformed frames.
   - avoided unnecessary process churn and accidental buffering behavior.

6. **go2rtc memory control**
   - added a Go runtime soft memory limit.
   - later profiling identified per-consumer queues and TCP backpressure as additional memory targets.

7. **Singleton service ownership**
   - ensured RTSP, motion, recorder, and IPC helper processes have one owner and one live instance.
   - used executable identity/locking rather than trusting stale PID files.

8. **Dispatch IPC fan-out reduction**
   - reduced the normal mirrored message-queue set after proving most queues were unused.
   - kept an explicit diagnostic mode for the full fan-out.

9. **Local-only boot / cloud removal**
   - stopped launching unnecessary vendor cloud processes.
   - retained or reimplemented only the vendor-side boot edges required for encoded media and local control.

10. **Kernel-led OOM policy**
    - removed an aggressive resident userspace reaper.
    - used `oom_score_adj` to protect `rmm`, Wi-Fi/SSH, dispatch, and the watchdog while making restartable helpers expendable.

11. **Lightweight watchdog recovery**
    - restarted configured expendable services after OOM/failure instead of rebooting the whole camera whenever possible.

12. **Static watermark removal**
    - removed the vendor logo without disabling the useful timestamp OSD.

13. **Strict disabled-service behavior**
    - e.g. MQTT disabled means no hidden MQTT helper continues to run.

14. **Wi-Fi soft recovery**
    - preferred reconnect/reconfigure paths that do not unnecessarily tear down the hardware/SDIO path.
    - added maintenance failover behavior for recovery.

15. **Atomic firmware upgrades**
    - made WebUI upgrades transactional, validated packed handlers, cleaned stale Factory state, and kept model state deterministic.

16. **Memory-aware defaults and documentation**
    - documented low-pressure Frigate/go2rtc defaults and separated local motion/recording workloads from NVR workloads.

### Fork-history landmarks

The optimization-heavy commits include:

- `d75ae06` — major y623 low-memory/viability work
- `d4324ed` — y623 `rmm` patch correction
- `a9f5206` — go2rtc direct-pipe/lifecycle work, `h264grabber` fixes, motion pressure guards, singleton hardening
- `2ee4e90` — additional low-memory work, VE debugfs patch tooling, Wi-Fi maintenance failover
- `97b7bc1` — permanent vendor-logo removal
- `24148fb` — kernel-led OOM policy replacing the aggressive reaper
- `d58fa58` — go2rtc memory limiting
- `c3e7bc8` — hardened local-only boot and dispatch IPC
- `3932d0c` / `899180d` — Wi-Fi reconnect/configuration hardening
- `4ea7ea9`, `c16d2aa`, `4ec47a2` — safer/atomic firmware upgrade handling
- `95b9b4d` — deterministic release integration of the y623 kernel allocation fix

The other fork-only commits include audio/backchannel features, build workflow changes, documentation, cleanup, versioning, and updater fixes; they are useful context but are not all performance optimizations.

## MStarX optimization principles

For Y23, prefer these rules:

- **Ablate edges, not whole closed binaries, until dependencies are proven.**
- **Preserve `rmm`, Wi-Fi, SSH, dispatch, and any required frame-buffer bootstrap path.**
- **Measure PSS/private memory, allocator pressure, socket queues, CPU, and restart behavior; do not optimize from RSS alone.**
- **Make restartable services expendable before touching essential media/control processes.**
- **Every vendor-binary patch must be model/firmware gated and reversible.**
- **A disabled feature must result in no hidden worker remaining alive.**
- **Do not copy Allwinner binary offsets, VE patches, or queue assumptions onto MStar.**

## Phase 0 — Baseline and dependency map

Before changing boot behavior, build a repeatable Y23 baseline.

### Observe these vendor processes

- `rmm`
- `cloud`
- `dispatch`
- `p2p_tnp`
- `oss`, `oss_fast`, `oss_lapse` where present
- `mp4record`

For each process record:

- executable and loaded libraries
- threads and file descriptors
- mapped shared memory/device files
- POSIX/System V message queues
- sockets, DNS activity, and destinations
- child processes / `system()` / `exec*()` activity
- CPU, RSS, PSS/private dirty where available
- behavior when RTSP high/low/audio, snapshot, ONVIF, recording, and speaker/backchannel are exercised

### Required dependency questions

Prove, rather than assume:

- which `cloud` operation starts or enables `/dev/fshare_frame_buf`
- which `cloudAPI` commands are required for local media versus telemetry/cloud state
- which dispatch MIDs have real consumers on Y23
- what the observed `MID4 -> MID1 opcode 0x71` path does
- whether `p2p_tnp` has any local-media side effects beyond remote P2P
- whether each `oss*` process is purely an upload path
- which `mp4record` dependencies are SD-recording-only versus cloud-event-only

Deliverable: `docs/y23-vendor-dependency-map.md`.

## Phase 1 — Selective vendor edge ablation

The first optimization target is not "kill cloud"; it is "remove unnecessary cloud/P2P/upload work while preserving required local bootstrap behavior."

### Candidate LD_PRELOAD shim

Because the vendor programs are dynamically linked, evaluate a small process-aware preload library that can selectively intercept:

- `connect`
- `getaddrinfo`
- `mq_send`
- `system`
- `execve` / related exec entry points where imported

Rules:

- default pass-through
- process-specific allow/deny behavior
- message-content filters for IPC, not blanket queue suppression
- fail-safe behavior if the shim cannot classify a call
- verbose diagnostic mode for live tracing before any no-op mode is enabled

Initial candidate no-op edges, **only after live proof**:

- `rmm -> MID4` cloud/event notifications
- telemetry-only `cloud -> cloudAPI` calls
- `p2p_tnp -> remote sockets`
- `oss* -> upload sockets/files`

Preserve until decoded/reimplemented:

- `rmm` encoder/frame/audio initialization
- dispatch local control routing
- the `cloud` frame-buffer bootstrap
- required local `cloudAPI` calls
- `MID4 -> MID1 opcode 0x71`

## Phase 2 — Local-only boot

After Phase 1 identifies the exact required edges:

1. reimplement the minimal frame-buffer/bootstrap operation currently supplied by `cloud`, or retain a tiny bootstrap invocation if reimplementation is unsafe;
2. do not launch `p2p_tnp` or upload-only `oss*` workers by default;
3. launch `mp4record` only when local recording is configured;
4. keep dispatch and `rmm` alive;
5. ensure the stock/vendor init path cannot start duplicate copies behind yi-hack.

Success criteria:

- RTSP high and low streams remain stable
- audio capture and speaker/backchannel remain stable
- snapshot and ONVIF remain functional
- local recording works when enabled
- camera stays usable without Internet/DNS
- no vendor P2P/upload sockets appear in local-only mode

## Phase 3 — Singleton lifecycle and process ownership

Port the Allwinner singleton lessons before chasing smaller memory savings.

Planned work:

- atomic lock around start/stop operations
- verify executable identity before killing a PID
- collapse duplicate `rmm`/dispatch/helpers rather than spawning around them
- one owner for `mp4record`; track whether motion or persistent-recording mode started it
- one owner per IPC queue consumer
- watchdog checks actual service health, not only "PID exists"

This should be implemented before aggressive OOM testing so recovery does not create duplicate workers.

## Phase 4 — Kernel-led OOM policy and recovery

Avoid a resident userspace reaper unless profiling proves the kernel cannot meet the requirement.

Candidate policy:

- strongly protect `rmm`
- strongly protect Wi-Fi/DHCP and SSH recovery access
- protect dispatch and the watchdog
- make RTSP/go2rtc producers restartable
- make local motion/recording more expendable
- make HTTP/ONVIF/MQTT/snapshot/transcoding/TTS helpers progressively more expendable

Exact `oom_score_adj` values must be tuned from Y23 behavior; do not copy the Allwinner values mechanically.

The watchdog should restart configured expendable services after OOM without rebooting the camera unless the essential media core is irrecoverable.

## Phase 5 — Streaming memory and backpressure

If go2rtc is adopted on MStarX, carry over the strategy rather than only the 12 MiB soft limit.

Investigate:

- Yi-specific minimal go2rtc build
- Go runtime soft memory limit
- smaller per-consumer video backlog
- bounded RTSP/TCP send buffering
- stale-frame dropping under slow-consumer backpressure
- direct producer pipes where they reduce copies/process glue
- stable behavior with Frigate dual-stream plus audio/backchannel

Measure latency and frame loss while reducing queues; a smaller buffer is not an optimization if it creates visible stutter.

For `h264grabber`, use PSS/private memory before deciding to merge processes. The Allwinner fork found that large RSS values can mostly be shared mappings.

## Phase 6 — Dispatch IPC reduction

Do not immediately copy the Allwinner "queue 2 only" behavior.

First:

1. trace queue creation and consumers;
2. map message IDs/opcodes under normal boot and each local feature;
3. identify queues that remain unused across representative workloads;
4. add a diagnostic/full-fanout mode;
5. reduce only queues that are proven unnecessary.

Expected benefit is primarily cleanup and reduced IPC churn, not a guaranteed large RAM/CPU win.

## Phase 7 — `rmm` internal work reduction

Only after Phase 0 tracing and binary analysis:

- identify AI/face/person/tracking/raw-analysis initialization that is unused by the intended local feature set;
- identify extra encoder/VI/VENC channels that are not consumed;
- identify background JPEG/snapshot paths that can be made on-demand;
- inspect model-specific large allocations and thread stacks;
- patch one edge at a time with firmware-signature checks.

The Allwinner success came from keeping the vendor media core while bypassing irrelevant branches. The same rule should guide MStarX.

Any `rmm` patch must include:

- exact supported firmware hash/signature
- original bytes check
- patched bytes
- automatic refusal on mismatch
- recovery path
- before/after RAM/CPU/functional measurements

## Phase 8 — Motion and local recording separation

Treat motion detection, local SD recording, and external NVR/Frigate workloads independently.

Goals:

- allow RTSP/ONVIF with no local motion worker
- allow local recording without requiring cloud event machinery
- start motion at a low idle polling/processing rate where possible
- temporarily increase sampling after motion evidence rather than continuously running the expensive path
- do not kill a recorder owned by a different feature

If the vendor IVA path is cheap and local, reuse it; if it is tightly cloud-coupled, evaluate a smaller local detector only after stream stability is solved.

## Phase 9 — Wi-Fi and maintenance recovery

Adopt the Allwinner reliability lesson:

- prefer soft reconnect/reconfigure over full interface/module teardown
- preserve SSH access whenever possible
- provide maintenance fallback when the configured WLAN cannot associate
- keep Wi-Fi credential loading deterministic and testable
- avoid recovery loops that repeatedly reset the hardware

## Phase 10 — Upgrade safety

Before distributing optimization builds:

- stage upgrades atomically
- verify model/firmware compatibility before replacing files
- validate required payload files before reboot
- remove stale upgrade/Factory state after success
- retain a deterministic rollback/reflash route
- add a packed-firmware test that verifies the actual upgrade handlers shipped

Performance work is not useful if an interrupted WebUI upgrade can strand the camera.

## Validation matrix

Every optimization should be tested against at least:

| Area | Test |
| --- | --- |
| Boot | cold boot and warm reboot, with and without Internet |
| Video | high stream, low stream, both simultaneously |
| Audio | capture plus speaker/backchannel |
| ONVIF | discovery, profiles, snapshot, events used by the fork |
| Recording | disabled, continuous/local, motion-triggered if supported |
| Network | DHCP renew, Wi-Fi reconnect, AP outage/recovery |
| Memory | idle, one stream, dual stream, dual stream + audio, Frigate slow-consumer case |
| Recovery | kill restartable services; confirm watchdog restores only the intended singleton |
| OOM | controlled pressure; confirm essentials survive and expendable services recover |
| Cloud ablation | verify no unintended P2P/upload/telemetry sockets |
| Upgrade | interrupted/stale-state cases where safely reproducible |

Record CPU, MemAvailable, PSS/private dirty, socket send queues, process count, and frame-drop/reconnect behavior.

## Things not to port blindly from Allwinner

- y623/y28ga `rmm` offsets or patch bytes
- the Allwinner VE debugfs `vmalloc` kernel patch
- the exact dispatch queue number assumption
- exact `oom_score_adj` values
- a belief that merging `h264grabber` workers necessarily saves meaningful private RAM
- a belief that a Go soft memory limit is a hard RSS cap
- any change justified only by RSS without PSS/private-memory evidence

## Priority order

1. **Dependency map and observational tracing**
2. **Selective network/cloud edge ablation**
3. **Singleton ownership and duplicate-process prevention**
4. **Local-only boot**
5. **Kernel-led OOM priorities + watchdog recovery**
6. **Streaming/backpressure memory bounds**
7. **Dispatch queue reduction after consumer mapping**
8. **Targeted `rmm` branch/allocation ablation**
9. **Motion/recording specialization**
10. **Wi-Fi and upgrade hardening**

The main objective is the same as the successful Allwinner work: keep the smallest stable local media/control core, make everything else optional or restartable, and require live measurements before claiming a resource optimization.
