# Y23 Proprietary Binary Network and Resource Audit

> Static analysis and live measurements from the Yi MStar Y23 at `192.168.1.26`, collected 2026-09-17 with `DISABLE_CLOUD=yes`. This is an ablation guide, not proof that every runtime path has been observed. Static reachability shows what a binary *can* do; syscall tracing or a packet capture is still needed to prove what it does during every operating state.

## Answer in brief

Yes. The proprietary binaries contain network and message paths that are unnecessary for a local-only camera, but they fall into three different categories:

1. `cloud`, `cloudAPI_real`, `p2p_tnp`, and `oss` contain genuine remote-network implementations. None is launched in the current local-only boot.
2. `dispatch`, `rmm`, and `mp4record` import socket functions, but their identified socket call sites are local logging or interface inspection rather than hidden Internet clients.
3. `rmm` sends cloud-directed event messages. The six confirmed routes are now filtered before proprietary dispatch handling, and unused mirror queues are no longer created. As predicted, this did not materially change idle CPU. The larger resource opportunity is preventing optional motion, JPEG, audio, or other analysis work that produces messages and media in the first place.

The direct-network process ablation and confirmed `rmm -> MID4` routing ablation are complete for the supported local-only path. The strongest remaining CPU target is optional work inside `rmm`.

Resource recovery is only one success criterion. Even where measured CPU/RAM savings are small, vendor-only code and messages should still be removed from the local-only profile to reduce telemetry exposure, remote attack surface, background process churn, WAN-dependent failure modes, and ambiguity about what the device is doing. The desired end state is not merely “cloud calls fail”; it is that Yi/Xiaomi network-capable components are not launched and vendor-directed event routes are not produced.

## Audit method and limits

The camera binaries were copied to a temporary analysis directory and inspected with ELF metadata, strings, symbols, relocation tables, and ARM/Thumb disassembly. Call sites were checked to distinguish local sockets from Internet sockets instead of treating every `socket()` or `sendto()` import as evidence of remote traffic.

The live camera was also inspected through `/proc`, per-thread CPU counters, mappings, file descriptors, POSIX message queues, and a temporary read-only IPC listener. No persistent camera file or configuration was changed during this binary audit.

This analysis can establish that:

- a binary has code capable of DNS, TCP, UDP, HTTP, or HTTPS communication;
- a particular call site uses `AF_UNIX` versus `AF_INET`;
- a process has a live Internet socket at the moment sampled;
- an IPC route is active during a measured interval.

It cannot establish that an unobserved conditional path never runs. A cold boot without Internet, event generation, settings changes, error paths, and long-duration operation still need dynamic observation.

## Binary boundary summary

| Binary | Direct remote-network capability | Current local-only state | Finding |
| --- | --- | --- | --- |
| `cloud` | **Yes** | Absent | Implements direct MiIO UDP/TCP plus API/login/report orchestration; no longer used for local bootstrap |
| `cloudAPI_real` | **Yes** | Replaced by wrapper | Full HTTP/HTTPS client; not selected while `DISABLE_CLOUD=yes` |
| `p2p_tnp` | **Yes** | Absent | P2P/relay/LAN discovery, remote media/control, TCP/UDP listeners and clients |
| `oss` | **Yes** | Absent | Aliyun OSS/Azure Blob upload client with HTTP/TLS stack |
| `dispatch` | Not found in inspected call sites | Resident | Internet-looking URL strings are routing/config data; identified IPv4 socket is used for interface `ioctl()` inspection |
| `rmm` | Not found in inspected call sites | Resident | Identified datagram socket sends only to the local logging socket |
| `mp4record` | Not found in inspected call sites | Resident | Identified datagram socket sends only to the local logging socket |
| `watch_process` | Not found | Absent | Local logging and process restart/reboot supervision |

“Not found” is deliberately narrower than “impossible.” It means the analyzed binary did not expose a direct Internet implementation through its imports and inspected call sites. Traffic could still be delegated to another process through IPC.

## `cloud`: direct network code is present but no longer launched

The inspected `cloud` binary imports and calls:

```text
socket
connect
gethostbyname
send
sendto
recv
recvfrom
```

Named code and strings identify both UDP and TCP MiIO paths:

```text
miio_create_udp_socket
miio_create_tcp_socket
miio_udp_send / receive
miio_tcp_send / receive
ot.io.mi.com
ott.io.mi.com
```

The disassembly shows an `AF_INET`/`SOCK_DGRAM` path using network port `8053` and an `AF_INET`/`SOCK_STREAM` path using port `80`. Additional strings expose Yi router and log-upload endpoints, including:

```text
http://yicamera-router.mi-ae.com.sg/v1/ipc/router
https://hch.xiaoyi.com:9443/upload/log
```

At the sampled idle point, `cloud` had only a local `AF_UNIX` datagram socket and no open Internet socket. That does not contradict the static result: the network paths are conditional or short-lived rather than continuously connected.

### Resident worker threads

After initialization, `cloud` creates four workers whose recovered function names are:

```text
msg_proc
panorama_capture_push_proc
yi_motion_push_proc
debug_log_report_proc
```

Three are plainly upload/report workers. The process then enters `yi_proc`, whose code covers login, device information, bind/DID checks, TNP-online state, reporting, retry loops, and IPC status handling. This remains a real cloud-control surface even when `cloudAPI` calls are intercepted.

The live cost is modest: approximately 309 KiB PSS / 260 KiB private memory and no measurable CPU during the idle sample. Its four 1 MiB worker-stack reservations are mostly virtual address space, not four MiB of resident RAM. Skipping individual upload threads would therefore bring less benefit than the virtual stack sizes suggest.

The cleaner end state has been implemented: the required current-epoch `0x71` transition is generated locally, and neither transient nor resident `cloud` is launched. No worker-level binary patch was required.

## `cloudAPI`: duplicate NTP ownership removed

The wrapper at `src/static/static/home/yi-hack/bin/cloudAPI` always selects `cloudAPI_fake` when `DISABLE_CLOUD=yes`. It does not fall back to `cloudAPI_real` for unhandled operation numbers.

The fake explicitly implements operations `136`, `138`, `141`, `142`, `304`, `306`, and `411`. Operation `136` formerly launched a blocking one-shot `ntpd` client before returning the epoch, duplicating the configured persistent NTP service.

That call has been removed. The fake now returns the current clock without creating a network process, while `system.sh` owns configured NTP synchronization. In normal disabled-cloud startup no CloudAPI operation is invoked at all because neither transient nor resident `cloud` is launched.

`cloudAPI_real` is a separate, remote-capable binary containing libcurl/TLS functionality and HTTP/FTP/API endpoints. It is not executed under the current disabled-cloud wrapper.

## `dispatch`, `rmm`, and `mp4record`: generic socket imports are misleading

All three binaries contain a common local logging client that uses:

```text
AF_UNIX
SOCK_DGRAM
/tmp/logsock
```

That accounts for the identified `socket()` and `sendto()` call sites in `rmm` and `mp4record`.

`dispatch` also creates an `AF_INET` datagram socket, but the inspected branch uses it with interface `ioctl()` request `SIOCGIFHWADDR` (`0x8946`). It does not send Internet traffic through that call site. Its remaining identified datagram sends belong to the same local logging client.

Consequently, removing these processes merely because they import socket functions would be incorrect:

- `dispatch` is part of local IPC transport and startup state;
- `rmm` is the hardware/media core;
- `mp4record` is the local recording process retained by `REC_WITHOUT_CLOUD=yes`.

If local SD recording is unwanted, avoiding `mp4record` is still a valid feature-level optimization. It is not evidence of hidden network activity.

## IPC message fan-out and cloud-event messages

The source interposer `src/ipc_cmd/ipc_cmd/ipc_multiplex.c` mirrors each message received by `dispatch` to nine queues. On the current boot:

```text
/ipc_dispatch_1  formerly consumed by mqttv4; unused with enforced MQTT=no
/ipc_dispatch_2  consumed by ipc2file
/ipc_dispatch_3 through _9  no consumer observed
```

A temporary listener on an unused mirror cleared 39 queued boot/backlog messages, then saw no new message during a 20-second idle interval. This establishes that idle IPC chatter was negligible in that sample.

Static analysis and existing protocol definitions show `rmm` cloud/event notifications to module 4 for:

```text
motion
person/body detection
vehicle detection
animal detection
baby crying
abnormal sound
cloud picture/index and capture events
```

These are good cloud-ablation boundaries, but dropping only the final `mq_send()` does not avoid the image, motion, JPEG, or audio analysis that produced the event. It mainly saves a sparse message copy. Module-1 local event/control traffic must also remain intact.

The mirror set is now reduced to actual consumers. With `MQTT=no` enforced in startup and the watchdog, disabled-cloud dispatch uses `IPC_MULTIPLEX_QUEUES=2`; descriptor inspection showed only `/ipc_dispatch_2`. Eight unused 64-by-512-byte queues represented approximately 256 KiB of nominal payload capacity, although kernel accounting and realized memory use must not be equated directly with that capacity. `mqttv4` remained absent beyond watchdog intervals.

`IPC_MULTIPLEX_DROP_CLOUD_EVENTS=1` also consumes only exact `MID2 -> MID4` events `0x7006`-`0x7009`, `0x6002`, and `0x6004`. Synthetic and real-dispatch injection tests dropped all six and preserved `MID2 -> MID1 0x00ed`. Both RTSP streams and recorder initialization passed after cold boots. Whole-`rmm` CPU remained about 35.9%, proving that final-message removal alone does not avoid upstream analysis.

## Where the CPU is actually going

`rmm` remains the dominant idle CPU consumer. A ten-second per-thread sample accounted for approximately 32.8% of one CPU in named or identifiable threads:

| Thread | Approximate CPU | Interpretation |
| --- | ---: | --- |
| `AEC_BUF` | 5.80% | Audio pipeline thread; whether active AEC can safely be avoided requires an A/B test |
| `motion_proc` (kernel thread name remains `rmm`) | 5.41% | Base motion-analysis worker; runtime callback tracing resolved it |
| `ISP_workqueue` | 4.55% | Core image pipeline |
| `VSPLV_BUF` | 4.39% | Video pipeline |
| `venc_get_videos` workers | 3.84% combined | Required encoder/output work for current streams |
| `ai_get_aacstream` | 1.73% | Audio input/AAC path, not “artificial intelligence” |
| remaining sampled threads | approximately 7% | ISP, video source, encoder, audio, IPC, and JPEG work |

The whole process varied around 33–38% of one CPU across samples. `cloud` was idle at sample resolution, so binary cloud removal is mainly a privacy, attack-surface, process-count, and small-RAM improvement—not the large CPU win.

Runtime `pthread_create` tracing mapped the motion worker to Thumb callback `0x000113c5` in this exact non-PIE binary. An opt-in preload suppressed only that callback. Matched 20-second cold-boot samples were:

| State | `rmm` CPU | PSS | Private | `MemAvailable` |
| --- | ---: | ---: | ---: | ---: |
| motion enabled | 36.15% | 11,833 KiB | 11,372 KiB | 15,864 KiB |
| motion omitted | 27.45% | 10,708 KiB | 10,252 KiB | 16,844 KiB |

The direct thread accounted for 6.10 percentage points; reduced downstream video-split work accounts for some of the larger 8.70-point process delta. Both video RTP streams, ONVIF HTTP, and main/sub/AAC recorder initialization passed. Motion events and motion-triggered recording are unavailable in this mode, so it is exposed as `DISABLE_MOTION_ANALYSIS`, defaults off, and is guarded by the exact `rmm` MD5 before preload activation.

Feature-message A/B tests also narrowed two false leads:

- disabling human, vehicle, animal, AI-motion, face, tracking, baby-cry, and abnormal-sound features left `motion_proc` near 6.0% and total `rmm` near 37.3%; this dispatch build rejected the four newer `0x103d`/`0x103f`-`0x1041` AI opcodes and accepted the older tracking/audio controls;
- `ipc_cmd -I off` changes microphone volume but does not stop the capture/AEC pipeline: `AEC_BUF` remained near 6.3%, all audio threads remained present, and total CPU was unchanged.

Neither control should be described as an analysis-thread or audio-pipeline disable switch.

Strings and internal routines in `rmm` confirm compiled-in work for:

```text
motion processing and frame differencing
foreground-pixel thresholds and morphology
baby-cry algorithms
sound/event handling
JPEG/snapshot initialization
human-detection event generation
audio capture, playback, and echo-cancellation paths
```

The current settings already disable baby crying and sound detection, and no specifically named worker proved those algorithms active. They should not be binary-patched on strings alone.

## Where `rmm` memory is going

The largest live PSS/private contributors were approximately:

| Mapping | PSS | Private | Note |
| --- | ---: | ---: | --- |
| heap | 2,432 KiB | 2,432 KiB | allocations made by media/analysis initialization |
| `/dev/fshare_frame_buf` | 1,676 KiB | 1,604 KiB | shared media buffer; proportional/private accounting needs care |
| anonymous mapping | 916 KiB | 916 KiB | likely media/algorithm state, exact owner unknown |
| anonymous mappings | 652 KiB + 616 KiB | same | likely buffers/state, exact owners unknown |
| `libCamAlgo.so` text | 544 KiB | mostly shared/code | algorithm implementation, not equivalent reclaimable heap |
| `rmm` text | 540 KiB | code | stripping strings would not recover the working buffers |

This distribution matters: most recoverable memory is heap, anonymous state, and buffers allocated during initialization. Removing message strings or a final send call will not free it. An effective patch must prevent an optional subsystem from being initialized or allocated.

## Recommended ablation order

1. **Completed:** replace the stale `ipc_cmd -x` payload with a dynamically generated current-epoch `0x71` message and give NTP synchronization one owner.
2. **Completed:** capture transient CloudAPI operations and IPC, prove `0x71` is the only required frame-buffer transition, and remove both transient and resident `cloud`.
3. Validate a cold boot with the WAN physically unavailable and complete the selected local feature matrix.
4. **Completed at the routing boundary:** remove confirmed `rmm -> MID4` vendor-only messages. Continue preventing disabled cloud-event producers from allocating or running.
5. **Completed for MQTT-off:** shrink dispatch mirroring to actual consumers; do not claim nominal queue capacity as exact resident saving.
6. Continue cold-boot `rmm` A/B tests, one feature at a time:
   - **completed:** motion/event analysis off versus on, exposed as a default-off option;
   - ONVIF snapshot/JPEG path off versus on;
   - speaker/backchannel path off versus on while preserving desired microphone audio;
   - local recording off versus on if SD recording is optional.
7. For every A/B test, compare per-thread CPU, PSS/private memory, mappings, both RTSP streams, desired audio, ONVIF, snapshot, recording, and long-run stability.
8. Only after a resource change is tied to one initialization branch should `rmm` be patched. Gate any patch by exact firmware hash and make it reversible.

Cloud cleanliness and performance should be tracked independently. A change may be required for the local-only firmware even when its CPU/RAM delta rounds to zero, provided it removes a confirmed vendor-only process, destination, credential flow, retry loop, or message route without damaging local operation.

The local-only acceptance test should ultimately require:

- no Yi/Xiaomi DNS queries or outbound destinations;
- no `p2p_tnp`, `oss*`, `cloudAPI_real`, or resident `cloud` process;
- no cloud login, registration, telemetry, upload, debug-report, or MiIO worker path;
- no `rmm` event messages addressed only to the removed cloud endpoint;
- no repeated retries or queue buildup caused by absent cloud consumers;
- all selected local RTSP, ONVIF, recording, snapshot, audio, speaker, and control functions still passing.

An observation-only preload tracer for `connect`, `sendto`, `mq_send`, `system`, `popen`, and `pthread_create` is a useful next tool. Start with `cloud` and `dispatch`; preloading the media-critical `rmm` process should wait until the tracer is proven low-overhead and recursion-safe.

## Binary hashes

These hashes identify the exact inspected samples:

```text
4392c9235235b67cf60f8d90056cefc44f51691308bbbb662e8634ba06df0bd3  cloud
43a23e6346a4f5c48d50cbecedb7a61e03a20161e077ac41ce740547793ccc37  cloudAPI_real
88d721e4648bf054b902ccaeda7b7ac337112a9bdcfeae8b4b3e167a2f8b6a03  dispatch
90276937d77850e31d3ad585121d91ca1ce11e754e1c895691df54c7a4a90969  rmm
9ba3c970db83e31dce91c2ceaf6b76eb838107b14437d0bf2936e2c95c0fc765  mp4record
793171fd19440842eb3223c3516f1d625d315e785d7b48e7fcf24bb80a6ee547  p2p_tnp
decfd9922a915feb77cf74ab6407016de93a4ab4b896896eeef26299f62c803b  oss
896167b09b99ef056e73eb1ccd548d9cedf1d1496225f3520ec6f558ae52f7c  watch_process
```

## Safety rule for future binary edits

Do not patch a networking import globally. `sendto()` is also the local log transport, `socket(AF_INET, SOCK_DGRAM)` is used for interface inspection, and IPC status messages can be required by local startup. Patch only a proven call path or, preferably, stop launching the whole optional process/subsystem at a documented boundary.
