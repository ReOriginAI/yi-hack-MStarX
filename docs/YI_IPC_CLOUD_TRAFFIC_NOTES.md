# Yi IPC and Cloud Traffic Analysis Notes

> Work in progress. This document records observed/reverse-engineered Yi MStar IPC and cloud behavior before any ablation work. The goal is to separate local camera functions from Yi cloud/P2P/upload-only paths so later optimizations can be made conservatively.

## Scope

Current target: Yi MStar `y23`.

This document focuses on Yi-owned control, telemetry, event, P2P, and upload traffic involving the stock binaries such as `rmm`, `dispatch`, `cloud`, `p2p_tnp`, and `oss*`.

It intentionally does **not** yet treat RTSP, ONVIF, frame-buffer sizing, encoder memory, or general media optimization as part of the cloud-ablation analysis.

No process or IPC path should be removed solely from the classifications below until confirmed on a live camera.

## IPC transport

The central POSIX message queue is:

```text
/ipc_dispatch
```

There is also a worker queue used by some configuration commands:

```text
/ipc_dispatch_worker
```

Known message header layout:

```c
struct {
    int   dstMid;
    int   srcMid;
    short mainOp;
    short subOp;
    int   msgLength;
};
```

Known module IDs from existing reverse engineering:

```text
MID_P2P      = 1
MID_RMM      = 2
MID_CLOUD    = 4
MID_DISPATCH = 4
MID_RCD      = 0x10
```

`MID_CLOUD` and `MID_DISPATCH` both being `4` is important: `dispatch` is the transport/router process, while module ID 4 is also used as the logical cloud-side endpoint in the protocol.

The locally generated `ipc_cmd` control messages commonly use source ID `8`; this source ID is not given a symbolic name in the current source.

## Observed IPC routes

### Local control messages to RMM

Many low-level camera controls are sent as source `8` to destination `2` (`RMM`):

```text
camera switch on/off
LED on/off
recording mode
IR on/off
rotation
microphone on/off
baby-cry detection enable/disable
sound detection enable/disable
sound sensitivity
```

These should currently be considered local/core behavior rather than cloud-only behavior.

### Local control messages to MID 1

A second group of camera controls is sent as source `8` to destination `1`, which the existing code names `MID_P2P`:

```text
motion sensitivity
PTZ movement
PTZ presets
PTZ cruise
human detection enable/disable
vehicle detection enable/disable
animal detection enable/disable
AI motion detection enable/disable
face detection enable/disable
motion tracking enable/disable
```

This is an important distinction: the logical IPC destination `MID_P2P=1` must **not** yet be assumed to mean that the standalone `p2p_tnp` network process is required. yi-hack-MStar local-only mode does not start `p2p_tnp`, but local IPC commands addressed to MID 1 are still part of the control system.

Therefore:

```text
MID_P2P logical destination != proven dependency on p2p_tnp process
```

## RMM detection/event messages

Known `rmm` event packets split into at least two families.

### RMM -> MID 1

```text
0x007c  motion start
0x007d  motion stop
0x00ed  older human-detection event
```

These appear to be general/P2P-facing event notifications. They should be preserved until local motion/recording dependencies are mapped.

### RMM -> MID 4

Known event messages addressed to module 4:

```text
0x7006  body/person detection
0x7007  vehicle detection
0x7008  animal detection
0x7009  motion detection
0x6002  baby crying
0x6004  sound detection
```

These are strong candidates for the Yi cloud alert/event pipeline because they target module 4 and correspond closely to cloud event/upload behavior.

A future conservative ablation experiment should preferentially target these MID-4 event copies before touching the MID-1 motion/event notifications.

## Cloud API command map

The existing `cloudAPI_fake` implementation is especially useful because it documents the API operations expected by the proprietary Yi binaries.

Known cloud API commands:

| Command | Yi name | Observed role |
|---:|---|---|
| `136` | `CMD_do_syntime` | Time synchronization |
| `137` | bind | Device binding |
| `138` | `CMD_do_login_v4` | Device/cloud login |
| `139` | reset | Cloud/device reset path |
| `140` | upgrade | Firmware upgrade path |
| `141` | `CMD_do_tnp_on_line` | TNP/P2P online registration |
| `142` | `CMD_do_get_dev_info` | Device information/capabilities |
| `143` | region | Region lookup/configuration |
| `301` | firmware MD5 | Firmware integrity metadata |
| `304` | `CMD_do_update_event_v4` | Event registration/update |
| `306` | `CMD_do_gen_presigned_url_v5` | Request JPG/MP4 upload destination/credentials |
| `311` | check DID | Device-ID check |
| `411` | `CMD_do_event_upload` | Event-upload transaction/finalization |
| `412` | information report | Device/status reporting |
| `413` | log upload | Diagnostic-log upload |
| `414` | data upload | Generic data upload |
| `415` | upload | Additional upload path |

Commands beyond the seven named `CMD_*` entries above were recovered from command construction and strings in the proprietary `cloud` binary. Their broad roles are statically identified, but their exact request/response contracts still require live observation. The current fake handles only `136`, `138`, `141`, `142`, `304`, `306`, and `411` explicitly.

This naturally divides the Yi cloud interaction into two groups.

### Control/provisioning/status plane

```text
136  time sync
138  login
141  TNP registration
142  device information/capabilities
```

### Event/upload plane

```text
304  event registration/update
306  presigned media upload URL generation
411  event upload transaction
```

The event/upload plane is likely one of the cleanest future ablation boundaries. However, `cloudAPI` is not the only possible network edge: the `cloud` binary also contains a direct MiIO socket path for `ot.io.mi.com` / `ott.io.mi.com`.

## Probable Yi event upload flow

Based on the known IPC events and cloud API arguments, the current working model is:

```text
rmm detection
    |
    v
dispatch / Yi event routing
    |
    v
cloud
    |
    +--> 304  register/update event
    +--> 306  obtain media upload URL/password
    +--> oss / oss_fast / oss_lapse
    |       `--> upload JPG/MP4
    `--> 411  event-upload completion/notification
```

The proprietary `cloud`, `rmm`, and `oss*` binaries are closed, so not every arrow above is directly source-confirmed. The command names and accepted parameters nevertheless strongly support this interpretation.

## Telemetry / metadata exposed to Yi cloud machinery

The fake cloud API parses the following parameters from proprietary Yi callers:

```text
uid
version
mac
ssid
ip
signal_quality
packetloss
p2pconnect
p2pconnect_success
tfstat
EventTime
EventStat
pic_url
video_url
pic_pwd
video_pwd
type
sub_type
key
keySec
url
```

This confirms that the Yi cloud-side machinery has access to at least:

```text
camera/device UID
firmware/version information
camera MAC address
connected Wi-Fi SSID
local IP address
Wi-Fi signal quality
packet-loss information
P2P connection state/success
SD-card state
cloud event metadata
upload URLs / upload credentials
```

### Wi-Fi password / PSK

The connected **SSID is explicitly passed** to the cloud API as `-ssid`.

No corresponding `-password`, `-psk`, `wifi_psk`, or `WIFI_PASSWORD` argument has been found in the cloud API interface.

The Wi-Fi PSK is separately handled by the local Wi-Fi configuration path (`wifi_psk=` / `WIFI_PASSWORD`) and written into the camera's Wi-Fi configuration storage.

Current conclusion:

```text
SSID                 confirmed exposed to Yi cloud machinery
Wi-Fi PSK/password   no evidence of transmission found so far
```

`-key` and `-keySec` must not be assumed to be Wi-Fi credentials. They appear in the cloud/API credential path and have not been linked to the stored Wi-Fi PSK.

Because `rmm`, `cloud`, and `p2p_tnp` are proprietary binaries, static source review cannot prove that the Wi-Fi PSK is never transmitted by another private code path. Live socket/network observation is required to close that question definitively.

## Yi Internet destinations blocked by local-only mode

The existing blacklist includes these hostname families:

```text
api.xiaoyi.com
api.xiaoyi.com.tw
api.eu.xiaoyi.com
api.us.xiaoyi.com

log.xiaoyi.com
log.xiaoyi.com.tw
log.eu.xiaoyi.com
log.us.xiaoyi.com

hch.xiaoyi.com

ot.io.mi.com
ott.io.mi.com
yicamera-router.mi-ae.com.sg
tnpmastercn.xiaoyi.com
openapi.kuaipan.cn
api-content.dfs.kuaipan.cn
familymonitor-interface-test.mi-ae.com.sg
```

There is also a set of hard-coded `47.x.x.x` destinations rejected in disabled-cloud mode.

Hostname names are useful hints (`log`, `tnpmaster`, Kuaipan storage, etc.), but individual endpoint roles should be verified by live socket/DNS observation rather than inferred solely from naming.

## Startup comparison: cloud enabled vs disabled

### Cloud enabled

The normal Yi process set includes:

```text
dispatch
rmm
mp4record
cloud
p2p_tnp
oss
oss_fast
oss_lapse
watch_process
```

### Cloud disabled

yi-hack-MStar intentionally omits:

```text
p2p_tnp
oss
oss_fast
oss_lapse
watch_process
```

but still starts:

```text
dispatch
rmm
cloud
```

and optionally `mp4record`.

This is strong evidence that the standalone `p2p_tnp` and `oss*` processes are not required for the basic local media pipeline.

`watch_process` is also absent, though that is a supervision decision rather than a protocol dependency.

## The former local `cloud` dependency is removed

The proprietary `cloud` binary mixed remote behavior with one required local state transition. Instrumented startup captured CloudAPI operations `136`, `138`, and `142`, followed by cloud-to-RMM messages `0x71`, `0x92`, `0x8c`, and `0x94`.

Staged cold boots then isolated the dependency:

1. without cloud-origin IPC, `/dev/fshare_frame_buf` remained at index zero;
2. a dynamically generated `0x71` current-epoch message made the buffer advance immediately;
3. `0x92`, `0x8c`, and `0x94` were not required for local media startup.

The disabled-cloud path now generates `0x71` directly and launches neither transient nor resident `cloud`. This preserves the required local state transition without retaining Yi login, reporting, upload workers, MiIO code, or CloudAPI subprocesses.

## Resolved `0x71` message: set system/RTC time

`ipc_cmd -x` sends this packet:

```text
dstMid    = 1
srcMid    = 4
mainOp    = 0x0071
subOp     = 0x0071
msgLength = 0
```

with four trailing bytes:

```text
a1 0e 9a 5e
```

The payload is the little-endian Unix epoch `1587154593`, or `2020-04-17 20:16:33 UTC`.

Static analysis traces the same packet through `cloud` and `dispatch`:

1. `cloud::yi_sync_time` runs CloudAPI command `136` and parses the returned epoch;
2. `cloud_set_time` sends `MID4 -> MID1`, opcode/sub-opcode `0x71`, with that four-byte epoch;
3. the dispatch handler formats and executes `/home/base/tools/rtctool -s time ...`;
4. dispatch logs `DISPATCH_SET_TIME` and sets the time-ready fields in `/tmp/mmap.info`.

The 2026-09-17 local-only reboot showed this exact sequence:

```text
transient cloud command 136 -> correct 2026 time
ipc_cmd -x                -> stale 2020 time
resident cloud command 136 -> correct 2026 time
```

The old resident `cloud` was repairing the static replay. `system.sh` now constructs the packet with `date +%s`, writes the epoch in little-endian form, sends it through `ipc_cmd -f`, and waits for the frame index to advance. CloudAPI command `136` no longer launches its own one-shot `ntpd`; the configured NTP service has sole ownership of network time synchronization.

This implementation passed repeated cold reboots, advancing frame-buffer checks, and high/low RTSP `DESCRIBE`/`SETUP`/`PLAY` with live RTP. A WAN-disconnected cold boot is still required to validate RTC/time behavior when configured NTP cannot reach its server.

## `dispatch` should not currently be treated as cloud-only

`dispatch` is the central Yi IPC router and is used by many local camera controls.

Removing `dispatch` wholesale would likely break:

```text
camera control
IR/LED state
motion sensitivity
PTZ
presets/cruise
AI configuration
microphone/sound controls
recording configuration
other Yi-local IPC operations
```

Current direction should therefore be:

```text
keep dispatch
    |
    +--> identify unnecessary producers
    +--> identify unnecessary consumers
    +--> suppress cloud/P2P-only event routes
    `--> reduce observation/multiplex overhead
```

rather than simply deleting `dispatch`.

## IPC multiplex routing and cloud-event filter

Historically, `dispatch` was started with an unconfigured preload:

```text
LD_PRELOAD=/home/yi-hack/lib/ipc_multiplex.so
```

The multiplex library intercepts every `mq_receive()` performed by `dispatch` and mirrors each received message into nine queues:

```text
/ipc_dispatch_1
/ipc_dispatch_2
...
/ipc_dispatch_9
```

Each mirror queue is configured for:

```text
64 messages
512 bytes per message
```

Nominal payload capacity alone is therefore:

```text
9 * 64 * 512 = 294,912 bytes (~288 KiB)
```

excluding kernel/POSIX mqueue bookkeeping.

Every received IPC message can also result in nine `mq_send()` attempts. Unused full mirror queues still cause attempted nonblocking sends that return `EAGAIN`.

This multiplex layer is useful for analysis, but it is itself a possible RAM/CPU optimization target later. It is not a Yi cloud protocol requirement.

Live descriptor inspection before strict MQTT gating found:

```text
/ipc_dispatch_1 -> mqttv4
/ipc_dispatch_2 -> ipc2file
/ipc_dispatch_3 through _9 -> no live consumer
```

After startup and watchdog logic were corrected to honor `MQTT=no`, `mqttv4` remained absent and `_1` also had no consumer. Disabled-cloud startup now uses:

```text
IPC_MULTIPLEX_QUEUES=2
IPC_MULTIPLEX_DROP_CLOUD_EVENTS=1
LD_PRELOAD=/home/yi-hack/lib/ipc_multiplex.so
```

Only `/ipc_dispatch_2` is opened. Unset/`all` queue configuration retains the former nine-queue diagnostic mode. This removes eight unused queue objects and eight nonblocking sends per dispatch message; the nominal payload-capacity reduction is 256 KiB, not a claim of exactly 256 KiB resident recovery.

The event filter consumes only exact `MID2 -> MID4` packets whose main/sub opcode matches one of:

```text
0x7006 body/person   0x7007 vehicle   0x7008 animal
0x7009 motion        0x6002 baby cry  0x6004 abnormal sound
```

A synthetic classifier test and a real-dispatch test dropped all six packets while preserving adjacent `MID2 -> MID1 0x00ed` local detection traffic. Repeated cold boots retained frame-buffer startup, recorder initialization, and both video streams. `rmm` CPU remained about 35.9%, confirming that this is vendor-route cleanup rather than an upstream analysis optimization.

## Current ablation confidence map

### Strong cloud/remote-only candidates

```text
oss
oss_fast
oss_lapse
p2p_tnp process
CloudAPI 304 / 306 / 411 event-upload flow
CloudAPI 138 login
CloudAPI 141 remote TNP registration
Wi-Fi/P2P/device telemetry collection for Yi cloud
```

These paths remain removal targets even if an idle sample attributes little CPU or RAM to them. Eliminating vendor-only telemetry, destinations, retries, credentials, and dormant remote-control surfaces is an explicit local-only firmware requirement, separate from performance optimization.

### Implemented cloud-event filter

```text
RMM -> MID4 0x7006 body/person events
RMM -> MID4 0x7007 vehicle events
RMM -> MID4 0x7008 animal events
RMM -> MID4 0x7009 motion events
RMM -> MID4 0x6002 baby-cry events
RMM -> MID4 0x6004 sound events
```

### Preserve for now

```text
dispatch
rmm
source 8 -> RMM local control messages
source 8 -> MID1 local control messages
RMM -> MID1 motion/event messages
generated MID4 -> MID1 opcode 0x71 with the current epoch
MID_RCD (0x10) paths until mapped
```

## Next observational work on live y23

The active process baseline, process memory, idle CPU, shared mappings, idle sockets, `0x71` semantics, complete cloud bootstrap, and current mirror-queue consumers have now been collected. Remaining work before proprietary `rmm` patching is:

1. Validate an Internet-disconnected cold boot.
2. Observe DNS and outbound connections during boot, motion, sound, and SD recording.
3. Group IPC frequency by `(srcMid, dstMid, mainOp, subOp)`, including `MID_RCD=0x10`.
4. Determine which analysis/allocation branches can be removed while retaining any selected local motion/event behavior.
5. Close the Wi-Fi-PSK question with traffic observation.
6. Complete RTSP audio, snapshot, PTZ, ONVIF, speaker/backchannel, recording, and long-run validation.

The optional, hash-gated no-motion preload is already validated for RTSP/ONVIF-only use. Further `rmm` changes still require this mapping and matched A/B validation.
