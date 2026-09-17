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
| `138` | `CMD_do_login_v4` | Device/cloud login |
| `141` | `CMD_do_tnp_on_line` | TNP/P2P online registration |
| `142` | `CMD_do_get_dev_info` | Device information/capabilities |
| `304` | `CMD_do_update_event_v4` | Event registration/update |
| `306` | `CMD_do_gen_presigned_url_v5` | Request JPG/MP4 upload destination/credentials |
| `411` | `CMD_do_event_upload` | Event-upload transaction/finalization |

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

The event/upload plane is likely one of the cleanest future ablation boundaries.

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

## `cloud` is not purely a cloud client

The `cloud` binary has at least one local side effect that yi-hack-MStar relies on.

Local-only startup briefly runs:

```sh
./cloud &
```

and waits for `/dev/fshare_frame_buf` to begin filling. It then kills `cloud` and sends an IPC message with `ipc_cmd -x`.

Afterward, local-only mode starts `cloud` again.

Therefore the current classification is:

```text
cloud = mixed local + cloud responsibilities
```

It is **not** yet safe to remove `cloud` wholesale.

The existing `cloudAPI_fake` approach already demonstrates a useful design pattern: retain proprietary local side effects while replacing external cloud transactions with local synthetic responses.

## Unknown `0x71` message

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

It is sent immediately after `cloud` has been used to start the shared frame buffer and then killed.

Its meaning is currently unknown.

Classification:

```text
MID4 -> MID1 opcode 0x71 = preserve until understood
```

This packet may be a cloud/P2P/local-buffer handshake and should not be ablated prematurely.

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

## IPC multiplex observation overhead

`dispatch` is currently started with:

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

### Strong candidates, but verify live first

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
cloud local initialization behavior
MID4 -> MID1 opcode 0x71
MID_RCD (0x10) paths until mapped
```

## Next observational work on live y23

Before any binary patching, collect:

1. Active Yi process list and RSS/CPU.
2. Outbound sockets by process (`cloud`, `p2p_tnp`, `oss*`, `rmm`, `dispatch`).
3. DNS requests and remote destinations.
4. IPC message frequency grouped by `(srcMid, dstMid, mainOp, subOp)`.
5. Traffic changes during idle, motion, sound, app/P2P connection, and SD recording.
6. Any traffic involving `MID_RCD=0x10`.
7. Whether the Wi-Fi PSK ever appears in process arguments, plaintext buffers visible through ordinary diagnostics, or network payloads.
8. Exact dependency of the `0x71` message and `cloud` frame-buffer bootstrap.

Only after that mapping should `rmm`, `dispatch`, or their message paths be patched.
