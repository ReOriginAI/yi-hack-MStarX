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
- **Treat removal of vendor-only network code, telemetry, retries, and message routes as a goal even when the measured CPU/RAM saving is small.**
- **A local-only build should not merely block Yi/Xiaomi calls; it should avoid launching their producers and should not accumulate messages for absent consumers.**
- **Do not copy Allwinner binary offsets, VE patches, or queue assumptions onto MStar.**

## Phase 0 — Baseline and dependency map

Before changing boot behavior, build a repeatable Y23 baseline.

Status on 2026-09-17: the cloud-enabled and `DISABLE_CLOUD=yes` idle baselines are recorded in `CLOUD_PATH_FINDINGS.md`. The validated local-only boot removes `cloud`, `p2p_tnp`, `oss`, `watch_process`, and disabled MQTT workers; generates the sole required `0x71` state transition locally; filters confirmed cloud-directed event packets; and retains high/low RTSP and snapshots. Dispatch now mirrors only to the active `_2` consumer. `MemAvailable` improved by roughly 2.0–2.2 MiB from process ablation, before the optional motion-analysis saving. The full functional and offline-boot matrix is not complete.

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

Resolved or partially resolved:

- `MID4 -> MID1 opcode 0x71` sets the system/RTC time from a four-byte Unix epoch;
- the former `ipc_cmd -x` packet contained a stale April 2020 epoch; `system.sh` now generates the same message with the current epoch;
- an instrumented boot captured transient `cloud` operations `136`, `138`, and `142`, followed by IPC `0x71`, `0x92`, `0x8c`, and `0x94`;
- staged cold boots proved that `0x71` alone activates `/dev/fshare_frame_buf`; neither transient nor resident `cloud` is now launched with `DISABLE_CLOUD=yes`;
- CloudAPI fake command `136` no longer launches a duplicate one-shot NTP client; configured time synchronization is owned by `system.sh`;
- before MQTT gating, mirror-queue consumers were `_1` (`mqttv4`) and `_2` (`ipc2file`); with `MQTT=no` now enforced, only `_2` has a live consumer;
- disabled-cloud dispatch now opens only `/ipc_dispatch_2`; a diagnostic/full-fanout mode remains available when `IPC_MULTIPLEX_QUEUES` is unset or `all`;
- exact `rmm -> MID4` event packets `0x7006`-`0x7009`, `0x6002`, and `0x6004` are consumed before proprietary dispatch routing, while module-1 local event traffic is retained;
- the unnamed high-CPU `rmm` thread is `motion_proc`; a hash-gated, opt-in preload can omit it when motion events and motion-triggered recording are not wanted;
- `p2p_tnp`, `oss`, and `watch_process` are not needed to bring up the observed local high/low RTSP paths;
- only `oss` exists on the observed Y23; `oss_fast` and `oss_lapse` were absent.

Still prove, rather than assume:

- correct RTC/time behavior during an Internet-disconnected cold boot
- whether optional features consume dispatch mirror queues `_3` through `_9`
- whether `p2p_tnp` has any local-media side effects beyond the paths already tested
- whether `oss` is purely an upload path across event and recording workloads
- which `mp4record` dependencies are SD-recording-only versus cloud-event-only
- which `rmm -> MID4` messages and upstream computations can be removed while preserving selected local event features

Working deliverables: `docs/CLOUD_PATH_FINDINGS.md`, `docs/YI_IPC_CLOUD_TRAFFIC_NOTES.md`, and `docs/Y23_BINARY_NETWORK_AND_RESOURCE_AUDIT.md`.

### Strict disabled-service finding

`MQTT=no` is now authoritative in both startup and the watchdog. `system.sh` does not launch `mqttv4`/`mqtt-config`, and `wd.sh` neither recreates them nor allows a stray instance to persist. The previously observed worker used about 201 KiB PSS / 152 KiB private memory and was the sole consumer of `/ipc_dispatch_1`. After more than one watchdog interval on the validation boot, both processes remained absent and only queue `_2` had a live consumer.

## Phase 1 — Selective vendor edge ablation

The first optimization target is not "kill cloud"; it is "remove unnecessary cloud/P2P/upload work while preserving required local bootstrap behavior."

The supported `DISABLE_CLOUD=yes` path has completed the process-level portion of this phase: transient/resident `cloud`, `p2p_tnp`, `oss`, and vendor `watch_process` were absent after repeated reboots, while the local media core remained alive. Measured removed-process cost was approximately 2,219 KiB PSS / 1,984 KiB private memory before the separate MQTT saving. Treat this as a successful checkpoint, not final proof, until the full validation matrix and WAN-disconnected boot pass.

### Implemented dispatch preload controls

`ipc_multiplex.so` now has two opt-in production controls:

```text
IPC_MULTIPLEX_QUEUES=2
IPC_MULTIPLEX_DROP_CLOUD_EVENTS=1
```

The first limits mirroring to active consumers. The second drops only the six confirmed `MID2 -> MID4` detection/event opcodes. A live classifier test dropped each cloud event, retained an adjacent `MID2 -> MID1` event, and a real-dispatch test showed the same behavior. High/low RTP and recorder initialization passed after repeated reboots. This cleanup did not measurably lower `rmm` CPU because it removes routing after analysis has already occurred.

A broader observation shim may still be useful for:

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

Remaining candidate no-op edges, **only after live proof**:

- telemetry-only `cloud -> cloudAPI` calls
- `p2p_tnp -> remote sockets`
- `oss* -> upload sockets/files`

Preserve until decoded/reimplemented:

- `rmm` encoder/frame/audio initialization
- dispatch local control routing
- the `MID4 -> MID1 opcode 0x71` time-ready transition, with a current epoch

## Phase 2 — Local-only boot

Current state and implementation order:

1. **Done for the supported local-only path:** do not launch `p2p_tnp`, `oss`, or vendor `watch_process`.
2. **Done:** generate the `0x71` packet with the current epoch instead of replaying the captured 2020 payload.
3. **Done:** replace the complete transient-cloud bootstrap with the single required local IPC state transition.
4. **Done:** omit resident `cloud`, saving about 309 KiB PSS / 260 KiB private memory and removing the final direct-network-capable Yi process.
5. Launch `mp4record` only when local recording is configured; the observed process cost about 283 KiB PSS.
6. Keep dispatch and `rmm` alive and ensure the stock/vendor init path cannot start duplicate copies behind yi-hack.
7. **Done:** gate `mqttv4` and its watchdog behavior on `MQTT=yes`.

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

Implemented for the supported disabled-cloud/MQTT-off profile. `_1` was consumed only by `mqttv4`, `_2` by `ipc2file`, and `_3` through `_9` had no live consumer. `IPC_MULTIPLEX_QUEUES=2` now creates and mirrors only `_2`; an unset value or `all` preserves full diagnostic fan-out. The intended configurations are:

```text
MQTT enabled:  mirror queues _1 and _2
MQTT disabled: mirror queue _2 only
diagnostic:    mirror queues _1 through _9
```

The queue reduction removes eight unused queue objects and eight send attempts per received message. The former nominal payload capacity was 288 KiB for nine queues versus 32 KiB for one, but kernel accounting and whole-system noise prevent treating the 256 KiB difference as exact resident-RAM recovery.

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

### First Y23 result: optional base-motion worker

Runtime `pthread_create` tracing identified `motion_proc` at Thumb callback `0x000113c5` in the exact Y23 `rmm` build with SHA-256 `90276937d77850e31d3ad585121d91ca1ce11e754e1c895691df54c7a4a90969`. The opt-in `rmm_optimizations.so` suppresses only that callback, and `system.sh` refuses to enable it unless `/home/app/rmm` has MD5 `598c74819e607648abb0c3402fda957f`.

A matched 20-second cold-boot A/B measured:

| State | `rmm` CPU | `rmm` PSS | `rmm` private | `MemAvailable` |
| --- | ---: | ---: | ---: | ---: |
| motion worker enabled | 36.15% | 11,833 KiB | 11,372 KiB | 15,864 KiB |
| motion worker omitted | 27.45% | 10,708 KiB | 10,252 KiB | 16,844 KiB |

Both RTSP video streams delivered live RTP, ONVIF returned HTTP 200, and `mp4record` initialized main, sub, and AAC inputs with the worker omitted. The cost is loss of motion events and motion-triggered recording, so `DISABLE_MOTION_ANALYSIS` defaults to `no` and requires a reboot. The deployed camera remains at `no` because its selected configuration uses motion recording.

## Phase 8 — Motion and local recording separation

Treat motion detection, local SD recording, and external NVR/Frigate workloads independently.

Goals:

- **Done as an opt-in mode:** allow RTSP/ONVIF with no local motion worker
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

1. **Validate an Internet-disconnected cold boot and complete the local feature matrix**
2. **Remove upstream work that exists only for disabled vendor-event features while retaining selected local motion behavior**
3. **Singleton ownership and duplicate-process prevention**
4. **Kernel-led OOM priorities + watchdog recovery**
5. **Streaming/backpressure memory bounds**
6. **Targeted `rmm` branch/allocation ablation, especially the audio/AEC path**
7. **Motion/recording specialization**
8. **Wi-Fi and upgrade hardening**

The current static binary boundary, idle IPC sample, and `rmm` thread/memory profile are recorded in [Y23_BINARY_NETWORK_AND_RESOURCE_AUDIT.md](Y23_BINARY_NETWORK_AND_RESOURCE_AUDIT.md). They show that message suppression by itself is a small optimization; optional subsystem initialization and allocation are the higher-value targets.

The main objective is the same as the successful Allwinner work: keep the smallest stable local media/control core, make everything else optional or restartable, and require live measurements before claiming a resource optimization.
