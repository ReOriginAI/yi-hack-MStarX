# Y23 Cloud-Path Findings

> Live observations from the Yi MStar Y23 at `192.168.1.26`, collected 2026-09-17 before and after a local-only reboot. These findings are intended to guide conservative cloud ablation. They distinguish confirmed observations from hypotheses; no vendor process or IPC edge should be removed solely from this document without a live validation test.

The companion [proprietary binary network and resource audit](Y23_BINARY_NETWORK_AND_RESOURCE_AUDIT.md) distinguishes direct Internet code from local logging/IPC sockets and records the current per-thread `rmm` CPU evidence.

## Summary

The live process layout strongly separates the MStar media core from the Yi cloud/network edge:

```text
rmm        = hardware/media core
cloud      = lightweight IPC/control/cloud coordinator
p2p_tnp    = P2P/network edge
oss*       = upload/network edge
mp4record  = separate local recording path
```

The supported `DISABLE_CLOUD=yes` path now launches no Yi cloud/P2P/upload binary. `p2p_tnp`, `oss`, vendor `watch_process`, and both transient and resident `cloud` have been removed while retaining the local media core. The proprietary bootstrap was reduced to one directly generated `MID4 -> MID1` `0x71` time-ready message containing the current epoch. Dispatch mirrors only to active local consumer `_2` and filters six confirmed `rmm -> MID4` vendor-event opcodes. Both video RTSP endpoints passed `DESCRIBE`, `SETUP`, `PLAY`, and live RTP receipt after cold reboots with this implementation.

## Local-only reboot checkpoint

The camera rebooted with:

```text
DISABLE_CLOUD=yes
REC_WITHOUT_CLOUD=yes
MQTT=no
RTSP=yes
RTSP_STREAM=both
RTSP_AUDIO=aac
ONVIF=yes
NTPD=yes
```

At roughly two minutes uptime the vendor process set was:

```text
present: dispatch rmm mp4record
absent:  cloud p2p_tnp oss watch_process
```

`oss_fast` and `oss_lapse` were not present on this Y23 in either observed configuration.

### Memory result

PSS and private memory are the useful measures here because the Yi processes share the approximately 1.7 MiB `/dev/fshare_frame_buf` mapping. Adding RSS values would count that mapping repeatedly.

| Process | Cloud-enabled PSS | Local-only PSS | Local-only private | Result |
| --- | ---: | ---: | ---: | --- |
| `dispatch` | 323 KiB | 339 KiB | 292 KiB | retained |
| `rmm` | 11,198 KiB | 11,812 KiB | 11,324 KiB | retained |
| `mp4record` | 257 KiB | 257 KiB | 164 KiB | retained by `REC_WITHOUT_CLOUD=yes` |
| `cloud` | 295 KiB | absent | - | removed after direct `0x71` replacement |
| `p2p_tnp` | 811 KiB | absent | - | removed |
| `oss` | 959 KiB | absent | - | removed |
| `watch_process` | 140 KiB | absent | - | removed |

The removed helpers plus `cloud` account for approximately **2,219 KiB PSS / 1,984 KiB private memory** using the observed process samples. Whole-system `MemAvailable` measured 15,508 KiB after the final no-cloud reboot versus 13,528 KiB in the original cloud-enabled baseline, a 1,980 KiB increase. The small changes in retained-process PSS and cache state show why this should be treated as a measured range rather than an exact allocation ledger.

If local SD recording is not wanted, setting `REC_WITHOUT_CLOUD=no` should also avoid the approximately 283 KiB PSS `mp4record` process. That is a separate feature decision, not cloud ablation.

### CPU result

During a ten-second idle sample after the reboot:

```text
rmm          38.2% of one CPU
rRTSPServer   1.25%
dispatch      0.42%
mp4record     0.21%
cloud         0.00% at sample resolution
```

The earlier cloud-enabled sample attributed only about 0.43% CPU to `p2p_tnp`, with `oss`, `watch_process`, and resident `cloud` below the sample resolution. The ablation therefore has a meaningful RAM, socket, privacy, and attack-surface benefit, but only a modest idle CPU benefit. Final no-cloud `rmm` CPU was approximately 35.8% of one CPU over ten seconds, so `rmm` remains the dominant CPU target.

### Functional checkpoint

Confirmed after the reboot:

- `rmm`, both `h264grabber` producers, `rRTSPServer`, and ONVIF services stayed alive;
- `rtsp://192.168.1.26/ch0_0.h264` returned an H.264 high-stream SDP, accepted `SETUP`/`PLAY`, and delivered an interleaved RTP packet;
- `rtsp://192.168.1.26/ch0_1.h264` returned an H.264 low-stream SDP, accepted `SETUP`/`PLAY`, and delivered an interleaved RTP packet;
- both high- and low-resolution snapshot endpoints returned `200 OK` with `image/jpeg` after the final no-cloud boot;
- the ONVIF device-service HTTP endpoint returned `200 OK`;
- the shared frame-buffer bootstrap completed and `mp4record` received main, sub, and AAC initialization data.

Not yet passed:

- `RTSP_AUDIO=aac` was configured, but neither video SDP advertised an audio track and `ch0_2.h264` returned `404 Stream Not Found`;
- sustained RTP frame continuity, PTZ, authenticated ONVIF operations, speaker/backchannel, new local recording creation, long-run stability, and an Internet-disconnected cold boot still require explicit tests.

The audio result may be independent of cloud ablation, but it must remain a validation failure until a cloud-enabled control boot or a direct audio-path diagnosis proves otherwise.

### Final no-cloud bootstrap checkpoint

An instrumented cold boot captured the transient proprietary `cloud` sequence before removal:

```text
CloudAPI 136  time sync
CloudAPI 138  fake login
CloudAPI 142  device information

MID4 -> MID1  0x71/0x71  current epoch
MID4 -> MID1  0x92/0x01  four-byte zero payload
MID4 -> MID1  0x8c/0x01  no payload
MID4 -> MID1  0x94/0x01  no payload
```

A staged replay then proved that `rmm` did not fill `/dev/fshare_frame_buf` while no cloud-origin IPC was sent, but began filling it immediately after the current-epoch `0x71` message. The `0x92`, `0x8c`, and `0x94` messages were not required and were removed rather than retained as vendor-state replays.

The final startup path:

- constructs the `0x71` packet in shell with the live epoch;
- sends it through `ipc_cmd -f`;
- waits for the shared-frame index to advance;
- never starts the proprietary `cloud` executable in disabled-cloud mode;
- leaves NTP ownership with the normal `system.sh` service; CloudAPI fake command `136` no longer starts its own one-shot `ntpd` process.

At approximately two minutes uptime, `dispatch`, `rmm`, `mp4record`, both grabbers, and `rRTSPServer` were alive; the four vendor network processes were absent; the frame index advanced; and no external TCP connection was visible. The configured persistent NTP service remains an intentional, non-Yi network client.

The original deployed `system.sh`, `cloudAPI_fake`, and `wd.sh` are preserved on the camera at `/tmp/sd/yi-hack-backups/20260917T1721-cloud-ablation/` for recovery. The repository versions remain the source of truth for future firmware builds.

### Dispatch queue and event-routing checkpoint

The production disabled-cloud dispatch environment is:

```text
IPC_MULTIPLEX_QUEUES=2
IPC_MULTIPLEX_DROP_CLOUD_EVENTS=1
```

Descriptor inspection after a cold boot showed only `/ipc_dispatch_2`; `_1` and `_3` through `_9` were not opened. A real-dispatch injection test proved that exact `MID2 -> MID4` opcodes `0x7006`-`0x7009`, `0x6002`, and `0x6004` are consumed, while an adjacent `MID2 -> MID1 0x00ed` local event is preserved. Both RTSP streams and recorder bootstrap passed before and after the production switch. The pre-filter local-only files are backed up at `/tmp/sd/yi-hack-backups/20260917T1748-pre-ipc-filter/`.

This change removes vendor-only routing and unused queue capacity but did not materially reduce `rmm` CPU; the image/audio analysis occurs upstream.

### Optional motion-analysis ablation

Runtime tracing identified the unnamed ~6% CPU worker as `rmm::motion_proc`. A separate `rmm_optimizations.so` can suppress only its `pthread_create` callback for the exact inspected Y23 binary. `system.sh` verifies MD5 `598c74819e607648abb0c3402fda957f` before enabling it; other binaries fail safe and run normally.

Matched 20-second cold-boot samples measured 36.15% CPU / 11,833 KiB PSS with motion enabled and 27.45% CPU / 10,708 KiB PSS without it. High/low live RTP, ONVIF HTTP, and main/sub/AAC recorder initialization passed without the worker. Motion events and motion-triggered recording necessarily do not work, so `DISABLE_MOTION_ANALYSIS=no` remains the deployed default for the current motion-recording configuration. The pre-experiment recovery set is `/tmp/sd/yi-hack-backups/20260917T1903-pre-motion-ab/`.

## Live `cloud` process snapshot

Observed process:

```text
PID       925
command   ./cloud
binary    /home/app/cloud
PPID      1
threads   5
VmSize    6136 kB
VmRSS     1332 kB
VmHWM     1336 kB
VmData    4304 kB
VmStk     136 kB
VmLib     1444 kB
```

The mapped libraries were limited to standard runtime components:

```text
libc
libm
libpthread
libdl
librt
ld-linux
```

plus a read-only mapping of:

```text
/tmp/mmap.info
```

No MStar ISP, encoder, or other vendor media SDK shared libraries appeared in `cloud`'s mappings during this snapshot.

Four worker-thread stacks reserve roughly 1 MiB of virtual address space each, but total resident memory remained only about 1.3 MiB. The virtual stack reservations should therefore not be counted as equivalent physical-RAM use.

## `cloud` file descriptors

The meaningful descriptors were:

```text
0  -> /dev/null
1  -> /dev/null
2  -> /dev/null
3  -> socket:[1406]
4  -> /ipc_dispatch
5  -> /ipc_cloud
8  -> /dev/__properties__
```

The two important IPC objects are:

```text
/ipc_dispatch
/ipc_cloud
```

This confirms that `cloud` participates directly in the Yi IPC fabric and has a dedicated cloud-side queue.

## `cloud` socket is local, not Internet-facing

Socket inode `1406` appeared in `/proc/net/unix` and `netstat` as an unnamed:

```text
AF_UNIX
SOCK_DGRAM
```

At the observed idle point, `cloud` had no open TCP or UDP Internet socket.

This does **not** prove that `cloud` never opens one; a transient connection could occur during login, event handling, or state changes. It does show that blocking `connect()` or DNS inside `cloud` is probably not the highest-value first experiment.

Likely network work is instead delegated to, or more visible in:

```text
cloudAPI
p2p_tnp
oss
oss_fast
oss_lapse
```

## Shared frame buffer

The camera had an active shared frame buffer:

```text
/dev/fshare_frame_buf
size: 1,786,088 bytes
```

with associated semaphore objects:

```text
/dev/sem.fshare_read_lock
/dev/sem.fshare_read_notify_*
/dev/sem.fshare_write_lock
```

However, `/proc/925/fd` showed that `cloud` did **not** keep `/dev/fshare_frame_buf` open.

That favors this model:

```text
cloud
  |
  +--> IPC/API/control action
          |
          v
   another component creates/enables/uses fshare
```

over this one:

```text
cloud --> directly owns the frame-buffer mapping for its lifetime
```

The exact IPC/API operation that triggers the frame-buffer bootstrap is therefore a high-priority target to identify.

## Contrast with `rmm`

The live `rmm` process held direct media/hardware descriptors including:

```text
/dev/msys
/dev/mem
/dev/isp
/dev/i2c-1
/dev/mvip
/dev/mhvsp*
/dev/mscldma*
/dev/mmfe
/dev/snd/*
/tmp/audio_in_fifo
```

and IPC descriptors:

```text
/ipc_dispatch
/ipc_rmm
```

This is a strong structural separation. `rmm` is clearly the hardware/media core; `cloud` is much more lightweight and control-oriented. Selective cloud ablation should therefore avoid disturbing `rmm` until the cloud-side edges are mapped.

## Other Yi process boundaries seen live

The same descriptor sweep showed:

```text
mp4record -> /ipc_dispatch + /ipc_rcd + /tmp/record_event
p2p_tnp   -> /ipc_dispatch + multiple sockets
oss       -> /ipc_dispatch + socket
rmm       -> /ipc_dispatch + /ipc_rmm + hardware/media devices
cloud     -> /ipc_dispatch + /ipc_cloud + local UNIX datagram socket
```

Two implications follow:

1. `p2p_tnp` and `oss*` are stronger candidates for clean network-edge ablation than `cloud` itself.
2. Local recording should be analyzed through `MID_RCD` / `/ipc_rcd` rather than being assumed to be part of the cloud pipeline.

## Existing `cloudAPI` interception boundary

The current yi-hack initialization already preserves the original vendor binary as:

```text
/home/yi-hack/bin/cloudAPI_real
```

and bind-mounts the yi-hack replacement over:

```text
/home/app/cloudAPI
```

This is performed by `system_init.sh`.

That is an unusually useful probe point because we can observe or selectively synthesize API behavior without modifying the proprietary `cloud` binary first.

The current fake implementation explicitly handles:

```text
136  time synchronization
138  cloud login
141  TNP/P2P registration
142  device information
304  event registration/update
306  presigned media-upload URL generation
411  event-upload transaction/finalization
```

The event/upload operations `304`, `306`, and `411` are particularly attractive early no-op candidates once their live call pattern is confirmed.

Static analysis of the proprietary `cloud` binary exposes a wider command surface than the fake currently documents:

```text
136 time sync             137 bind
138 login                 139 reset
140 upgrade               141 TNP online
142 device information    143 region
301 firmware MD5          304 event update
306 upload URL            311 check DID
411 event upload          412 information report
413 log upload            414 data upload
415 upload
```

This does not mean all commands execute on every boot, but it means the fake's seven-command switch is not a complete inventory. Diagnostic logging should record the operation number while redacting signed URLs, keys, and other request material.

`cloudAPI` interposition is also not a complete network boundary. The `cloud` binary contains a direct MiIO path referencing `ot.io.mi.com` and `ott.io.mi.com`. Local-only mode already blocks those destinations, but a future “no remote sockets” assertion must observe `cloud` itself as well as the `cloudAPI` child.

## Resolved `0x71` bootstrap message

Static analysis resolves the packet sent by `ipc_cmd -x` as a time-setting message, not an unknown P2P handshake:

```text
dstMid    = 1
srcMid    = 4
mainOp    = 0x0071
subOp     = 0x0071
payload   = four-byte little-endian Unix epoch
```

`cloud` obtains the epoch through CloudAPI command `136`, constructs this message, and sends it to `dispatch`. The dispatch handler runs `/home/base/tools/rtctool -s time ...`, logs `DISPATCH_SET_TIME`, and marks two time-ready fields in `/tmp/mmap.info`.

The packet compiled into `ipc_cmd` contains:

```text
a1 0e 9a 5e -> 1587154593 -> 2020-04-17 20:16:33 UTC
```

The local-only reboot log proves the current ordering and its defect:

1. transient `cloud` used command `136` and set the correct 2026 epoch;
2. `ipc_cmd -x` immediately reset the clock to its captured April 2020 epoch;
3. the newly resident `cloud` ran command `136` again and restored the correct epoch two seconds later.

The resident process was therefore repairing a bootstrap bug. That dependency has now been removed: `system.sh` constructs the same packet with the current epoch, and a staged cold-boot test proved this message alone starts frame-buffer filling. Neither transient nor resident `cloud` is launched in disabled-cloud mode.

An Internet-disconnected cold boot is still required to prove RTC/time behavior without configured NTP, but NTP can no longer mask a dependency on Yi `cloud` because no Yi process runs.

## Recommended next probe order

1. **Validate an Internet-disconnected cold boot.** Confirm RTC/time behavior and frame-buffer startup without DNS or NTP availability.

2. **Complete the local feature matrix.** Test audio, snapshots, PTZ, ONVIF operations, speaker/backchannel, local recording output, and long-run stability.

3. **Completed at the routing boundary:** filter `rmm -> MID4` vendor-only routes without disturbing `rmm -> MID1` local events. Continue eliminating upstream analysis/allocation only where the associated local feature is disabled.

4. **Completed for the selected profile:** `MQTT=no` keeps `mqttv4` absent and dispatch mirrors only to `_2` (`ipc2file`). Full fan-out remains available for diagnostics.

## Validated local-only decomposition

The observed boot now uses this decomposition:

```text
rmm --> dispatch --> local controls and consumers
  ^
  `--- generated MID4 -> MID1 0x71 current-epoch/time-ready message

not launched: cloud, cloudAPI_real, p2p_tnp, oss*, watch_process
```

The remaining cloud-ablation work is inside retained boundaries:

```text
filter rmm -> MID4 vendor-only event messages (done)
avoid work/allocations that exist only to produce removed cloud events
remove unused dispatch mirror queues and retry paths (done for MQTT-off profile)
verify every selected local feature and a WAN-disconnected cold boot
```
