# Codex handoff: current MStarX implementation state

Updated 2026-10-06 after implementation, reversible Y23 camera tests, and removal
of the new go2rtc build/package at the user's request. The user has authorized
further feature work and reversible debugging on `.26` in this session.

## Goal, authorization and working state

The user wants portable post-fork features and optimizations from
ReOriginAI/yi-hack-Allwinner-v2X adapted to this MStar repository. Work on
**master** and preserve unrelated changes. The original inspection-only handoff
has been superseded: source, build scripts, tests and documentation now contain
implementation changes. Do not treat historical Allwinner comparisons as proof
that hardware-specific patches are portable.

- Target: `/home/ubuntu/tmp/yi-hack-MStarX`, origin
  `https://github.com/ReOriginAI/yi-hack-MStarX.git`.
- Current branch/HEAD: `master` / `ff1407f`. The implementation is **uncommitted**,
  with modified tracked files and new untracked helpers, modules, tests and docs.
  No implementation commit, push or release was made. Preserve this worktree;
  do not reset it or remove untracked source files as build cleanup.
- Reference: `/home/ubuntu/tmp/yi-hack-Allwinner-v2X`, origin
  `https://github.com/ReOriginAI/yi-hack-Allwinner-v2X`, HEAD `2540e84`.
  Fork baseline `bcef7ff`; first custom commit `794956f`.
- Use local history as the primary reference: `git log --reverse
  bcef7ff..2540e84`, `git show`, and scoped net diffs. Check for later reversions.
- **Do not add/package go2rtc.** The user explicitly excluded it. Its new module,
  Go toolchain CI step, UI option and packaged binary were removed. Standard
  `rRTSPServer` remains the default. Existing optional go2rtc compatibility,
  safe credential quoting and missing-binary fallback remain; their presence in
  scripts/tests does not authorize adding the backend again.
- Camera tests temporarily interrupted streaming/recording, then restored the
  original services/settings. No full flash, persistent replacement scripts or
  libraries, Wi-Fi credential write, or release deployment was performed.

## Camera access and restored state

Test camera: `root@192.168.1.26`, model `y23`. Direct SSH was verified using the
login details supplied in the session; do not recover or store credentials.
Old cmlink workspace/session/terminal IDs from the inspection are unnecessary
and may be stale. The temporary SSH control master was closed after cleanup.
Use `ssh -n`/DEVNULL for read-only subprocesses so SSH cannot consume subsequent
commands. Keep embedded shell commands short. `rg` is available on the host;
use it first, with grep/find as a fallback. Avoid git pagers.

The final restoration used the camera's original binaries and configuration.
The vendor core, Wi-Fi/DHCP and SSH listener remained available during tests.
The original standard RTSP server, both grabbers, recorder, watchdog and local
services were restored; no cloud/MQTT/go2rtc process was left running. All 68
captured system/camera config keys matched the baseline. Temporary SD test files
and the speaker lock were removed; original OOM priorities were restored.
Recheck current live state before any further device work.

| Item | Recorded observation, 2026-10-06 |
| --- | --- |
| Installed model / hack version | y23 / 0.5.7; version does not identify fork commit |
| Kernel | Linux 3.18.30, vendor build March 2018, ARM GCC 4.8.3 |
| MemTotal / swap | 60,824 KiB / none |
| Host-captured baseline / final MemAvailable | 15,128 / 15,124 KiB; snapshots, not a benchmark |
| `/tmp` | tmpfs with 32,768 KiB maximum, not a preallocated 32 MiB |
| `/home` | JFFS2, 12,480 KiB total, 3,320 KiB free at restoration |
| `/tmp/sd` | `/dev/block/mmcblk0p1`, about 15 GiB free at baseline |
| Local services | dispatch, networking, log_server, HTTP, SSH, FTP, telnet, NTP, IPC, ONVIF notify, WSD, mDNS, cron |

The installed binary set differs from the repository's rebuilt binaries. The
original RTSP server reported a missing AAC FIFO during restoration; high/low
video was verified after rollback, while video + AAC passed with the rebuilt
standard server during staged tests. Do not infer installed fixes from source
or the version string. The installed TinyALSA hash differs from the new build;
its source-level idle-speaker fix was not verified as installed, and the new
library was not injected into `rmm`.

## Read before further changes

Start with this repository's `docs/OPTIMIZATIONS.md`: it records implemented
behavior, tests, measurements and limitations. `docs/FUTURE_OPTIMIZATIONS.md`
now has a current-state notice, but its estimates/vendor proposals remain
historical planning material. Also read:

- Allwinner `docs/OPTIMIZATIONS.md` for reference behavior and measured limits.
- `docs/CLOUD_PATH_FINDINGS.md`.
- `docs/Y23_BINARY_NETWORK_AND_RESOURCE_AUDIT.md`.
- `docs/YI_IPC_CLOUD_TRAFFIC_NOTES.md`.
- `docs/Y23_AUDIO_PATH_OPTIMIZATION.md`.
- `CONTRIBUTING.md`, `.github/workflows/build.yaml` and the affected source.

Older audio notes describe `RTSP_AUDIO=yes`. Current packaged defaults are
`RTSP_AUDIO=no`, `RTSP_ALT=standard`, `RTSP_BACKCHANNEL=NONE`; check source and
live settings before changing behavior.

## Implemented additions and fixes

| Area | Current implementation / important paths |
| --- | --- |
| Bounded logs | `log_store.sh`, `bounded_log.sh`, ONVIF `path.patch`: native logs rotate inside `/tmp/yi-service-logs`, 128 KiB tmpfs / 16 inodes, verified filesystem/capacity and fail-closed fallback; shell logs 64 KiB / 200 lines; optional serialized 64 KiB `rmm` diagnostics |
| Shared runtime/config work | `runtime.sh`, `config_work.sh`, `restore_config.sh`, `upload.sh`, native MQTT `config.c`: exact config parsing, BusyBox PID matching, stale-lock handling, serialized writes, verified mounted SD staging, cleanup traps |
| Config backup/restore | `save.sh`, `load.sh`, `set_configs.sh`, native `archive_check`: strict regular-file allowlists, traversal/link/device/duplicate/truncation rejection, decompression bounds and per-file rollback handling |
| Lifecycle/privacy | `system.sh`, `service.sh`, `privacy.sh`, `wd.sh`: serialized idempotent starts/stops, RTSP/grabber/recorder ownership, shared IPC ownership, toggle enforcement, explicit-stop/privacy protection; `all start` respects MQTT off |
| Watchdog/OOM | Watchdog singleton survives RTSP off and recovers optional services; TCP checks tolerate absent `/proc/net/tcp6`; one-shot `oom_policy.sh` protects vendor/network/SSH listener and makes optional services disposable; no resident RAM reaper |
| Standard RTSP | Rebuilt FIFO-only CLI omits unsupported upstream `-i`; vendor audio library paths include `/home/ms`; 4 KiB grabber stdout buffers fix dangling stack-buffer and pointer-size bugs |
| Backchannel | Public `RTSP_BACKCHANNEL` migrates/mirrors legacy `ONVIF_AUDIO_BC`; standard G711/AAC support retained, alternative backend advertises no reverse audio; speaker-disabled settings suppress advertisement |
| Speaker/TTS | Native `speaker` helper, standard-server sinks and `SpeakerLock.hh` share a kernel playback lock; bounded upload/file/TTS CGI, cancellation/backpressure, UI speed/pitch/gain/stop/six voices; pinned NanoTTS/Pico on SD |
| Wi-Fi | `configure_wifi.sh`, `wifi_failover.sh`, CGI/UI: BOM/CRLF-aware strict parsing, exact 64 KiB `conf` partition gate, SD backup, staged erase/write/readback; soft recovery escalation and optional maintenance profile, default off |
| Upgrade | Own ReOriginAI release feed, `firmware_check.sh`, `restore_upgrade.sh`, CGI: checksums, locks, mounted SD/free-space gates, archive/layout/magic/size validation, bounded config preservation; `get=prepare` stages without flash triggers/reboot |
| Build/package | Y23 size gates, checksum manifest, offline-speech SD companion, required BusyBox applets and extracted-firmware checks; incremental www compilation fixed with `ln -sfn` |

Configuration backups now use `config.tar.bz2`: compressed <=64 KiB, each file
<=64 KiB, total <=256 KiB, <=32 regular files. The new restore endpoint rejects
legacy `.7z` backups; make a fresh compatible backup before deployment. Atomic
file replacement is not a transaction across all settings or protection against
power loss. `/home/yi-hack` is flash: large staging must use verified mounted
`/tmp/sd`, never an unmounted SD path or internal flash.

Speaker PCM is 16 kHz mono S16LE. WAV supports 8/16 kHz mono PCM16; the helper
can expand PCMU/8 kHz streaming to 16 kHz. Upload/output is limited to 4 MiB;
speech text to 1024 bytes. NanoTTS uses stdin for CGI synthesis. The packaged
BusyBox includes `wc`, head/fancy-head, bzip2/bunzip2, gzip/gunzip, sha256sum,
timeout and cmp; the original camera shell lacks some required applets.

## Existing MStar optimizations retained / exclusions

Preserve local cloud/P2P/upload ablation, working MStar IPC MID4-to-MID1 opcode
`0x71` activation with current epoch, `IPC_MULTIPLEX_QUEUES=2`, optional confirmed
cloud-event suppression preserving module 1 messages, and cumulative CPU-tick
stall detection with cached process/listener checks.

The exact-binary-gated `DISABLE_MOTION_ANALYSIS` remains feature-aware and off by
default. The camera's `rmm` matched MD5 `598c74819e607648abb0c3402fda957f`.
TinyALSA's existing `O_RDWR` speaker FIFO patch remains in source. No further
vendor motion/video/logo binary ablation was implemented.

Do not copy Allwinner offsets, Y623 VE/debugfs vmalloc/kernel patching, or Y28ga
IVA/NNA/PTZ/main-only recorder patches. Commit `3e16415` reverted human-only
changes back to `c7c6ada`; `b9c44fe` automatic AEC was reverted by `2260485`.
Do not resurrect those changes. Future vendor work requires exact hashes,
disassembly, measured benefit and a recovery plan.

Useful history references: lifecycle `a9f5206`, `c3e7bc8`; speaker/TTS `0439114`;
OOM `24148fb`; Wi-Fi `2ee4e90`, `899180d`, `3932d0c`; bounded storage/config
`03857c8`, `3560e80`, `2540e84`; upgrade `4ea7ea9`, `363d747`, `c16d2aa`,
`4ec47a2`. Minimal-go2rtc history is excluded from the deliverable by user choice.

## Build state and artifacts

Authoritative build: `.github/workflows/build.yaml`, `scripts/common.sh`,
`compile.sh`, `init_sysroot.sh`, `pack_fw.sh`. Preserve pinned Linaro
arm-linux-gnueabihf GCC 4.8.3-201404, base firmware 0.5.7/hash and Jefferson 0.4.7.
The compiler's 32-bit x86 runtime was resolved and a target compile/link smoke
passed; `--version` alone is insufficient. All native modules were built.
Submodules are initialized at their recorded commits and clean; module init
scripts apply required patches before compilation. Do not rebuild a cleaned
native dependency checkout without its init step.

New modules: repository-native `src/storage_tools` (`archive_check`, `speaker`
in flash) and `src/nanotts` (SD speech executable/Pico voices/licenses).
NanoTTS source is pinned to `d8b91f3d9d524c30f6fe8098ea7a0a638c889cf9` with SHA256
in its init script. No `src/go2rtc` module or Go build dependency remains.

Host-local build environment is `/tmp/mstar-port/build-env`, with relocated
compiler, 32-bit libraries and packaging tools under `/tmp/mstar-port`. It is a
session convenience, not a replacement for CI. If still available, source it
and use `set -e` when building. Full `scripts/compile.sh` removes/rebuilds
`build/`; do not use a selected-module build expecting it to preserve the rest
of the existing payload. `scripts/pack_fw.sh` was run under `fakeroot` locally.
Raw logs/baselines/settings under `/tmp/mstar-port` may contain credentials;
do not commit or publish them. GitHub Actions itself was not run this session.

Latest artifacts, rebuilt after the standard-backchannel batch (development VERSION still 0.5.7):

- `out/y23/y23_0.5.7.tgz`: 10,930,531 bytes; exactly `sys_y23`, `home_y23`.
- `out/y23/y23_0.5.7_sd.tgz`: 4,812,856 bytes; NanoTTS/voices/licenses, no go2rtc.
- `out/y23/y23_0.5.7.sha256`: both package checksums verified.
- Extracted sys/home image sizes: 1,763,232 / 9,556,716 bytes, below partition
  gates of 1,966,080 / 12,779,520 bytes. Repacking can change sizes/checksums.
- Latest flash package was extracted with Jefferson: RTSP binary matches the
  rebuilt payload, standard default, no Go
  binary/UI option, native helpers executable, CGI equal to source, minified UI
  equal to current compiled output. Earlier full extraction checked all helpers,
  static scripts, required BusyBox applets, native log paths and config keys.

These are development artifacts, not a published release or proof of a safe
full-flash upgrade. Set VERSION and matching tag deliberately for a release.
Install the matching SD companion under mounted `/tmp/sd` for offline TTS;
the web upgrader updates the flash bundle, not that companion.

## Verification completed and measurement limits

The original six suites passed locally: `scripts/tests/test_archives.py`,
`test_storage.py`, `test_config_api.py`, `test_platform_scripts.py`,
`test_speaker.py`, `test_lifecycle.py`. They cover archive/decompression bounds,
lock/cleanup/missing-SD behavior, config APIs, Wi-Fi/upgrade fixtures, speaker
formats/cancellation/exclusivity, and lifecycle/toggle/privacy/recovery behavior.
BusyBox ash syntax, JavaScript syntax, native builds and package checks passed.
After go2rtc exclusion, lifecycle tests, checksums and package extraction checks
were repeated successfully. The seventh suite, `test_rtsp_sink.py`, was added and passed during the
backchannel continuation; CI now invokes it too. Speaker/lifecycle tests were
repeated after the native changes. Documentation-only updates do not need a full
build.

Live reversible SD tests verified rebuilt standard high/low video + AAC,
concurrent starts/stop/privacy/recorder ownership/disabled features/recovery,
isolated config save/restore and JSON updates, and actual 128 KiB log mount/full
inode/fail-closed behavior. Offline synthesis produced 49,152 PCM bytes and
playback/upload/TTS completed at zero gain. Config restore fixtures stubbed IPC
commands to avoid changing camera controls. See `docs/OPTIMIZATIONS.md` for limits.

Recorded PSS: original standard server 859 KiB + two grabbers 111 KiB each
(1,081 KiB total); excluded experimental go2rtc fresh/warm idle 6,214/7,446 KiB,
active high-video/AAC 7,678 KiB + producers 364 KiB. Workloads were not matched,
and original standard services remained running during parallel-port Go probes.
Snapshots favor the default for RAM use but do not establish long-term stability
or controlled system memory savings. No quantified before/after RAM/CPU savings
have been established for the retained additions.

## Remaining work / safe continuation

1. Review the uncommitted implementation and current docs; continue on master
   without discarding unrelated work. Do not repeat completed ports or add Go.
2. Run checks appropriate to each subsequent change. CI records the seven suites,
   shell syntax, target compiler/build and extracted firmware/SD checks. Inspect
   minified/gzipped UI by its compiled output, not raw-source byte equality.
3. Hardware deployment validation remains: sustained multi-client/slow-consumer
   streaming and OOM recovery, physical microphone/speaker/standard G711/AAC
   talkback, sound quality and cancellation under real playback.
4. New ONVIF discovery/events need end-to-end deployment testing. Recording
   singleton behavior passed, but motion triggering and recording lookback need
   timestamped footage; do not claim the lookback issue fixed.
5. Wi-Fi credential writes, reconnect escalation and maintenance failover were
   fixture-tested, not exercised on the camera's sole access link. Establish an
   independent recovery route before disruptive network tests.
6. Full-flash upgrade/boot config restoration require MStar-specific validation
   and a proven recovery path. No flash occurred; do not use an unvalidated flash
   as the first deployment test. Stage reversible SD tests with backups and
   timed rollback, respecting the roughly 3.2 MiB free internal flash space.
7. Keep logs/uploads bounded, protect network/SSH/vendor processes and report
   actual measurements and limitations. No arbitrary process-killing RAM reaper
   or guessed vendor patch offsets.

## Latest continuation: standard backchannel (2026-10-06)

The user authorized further portable feature work and reversible debugging on
`.26`. Standard RTSP remains the backend; go2rtc remains excluded.

Completed this batch:

- Separate G711 network RTP clock (8 kHz) from speaker PCM rate (16 kHz), add
  explicit PCMU/PCMA SDP mappings, correct the G711 bandwidth estimate and signed
  A-law conversion.
- Side-effect-free discovery: G711/AAC preview sinks use `/dev/null` and never
  open the speaker FIFO or acquire/release playback ownership.
- Exclusive backchannel sessions: do not reuse one client's receiver for another
  client. Busy/unavailable SETUP returns 503 through `backchannel.patch`, applied
  at `init.rRTSPServer`; missing FIFO readers cannot block the event loop.
- Implement backchannel `deleteStream`: TEARDOWN/TCP disconnect closes media,
  RTP/RTCP sockets, destination state and the kernel playback lock.
- Add `scripts/tests/test_rtsp_sink.py` to CI. It exercises real PCM sink code
  with a small live555 I/O shim: interprocess exclusion, preview isolation,
  A-law sign, PCM rate, missing/full FIFO, reader loss and lock release.
- Build with the target compiler and check the new upstream patch against a
  fresh live555 archive. Hardware-only fixtures are
  `scripts/tests/rtsp_backchannel_server.cpp` and
  `scripts/tests/test_rtsp_backchannel_live.py`; they are not firmware payloads.
- On `.26`, a private SD protocol fixture using production native classes passed
  PCMU/PCMA (ten packets -> 6,400 PCM bytes each), AAC (eight frames -> 16,384 PCM
  bytes), repeated discovery while busy, concurrent SETUP rejection, TEARDOWN and
  abrupt TCP loss. Twenty alternating cleanup sessions left descriptors 4 -> 4.
- The rebuilt production daemon on alternate port 5557 passed 50 PCMU silence
  packets through `/tmp/audio_in_fifo`; playback descriptors closed afterward.
  The updated `backchannel_probe.py` supports stream/port selection, repeated
  DESCRIBE, interleaved RTCP and native-daemon FIFO verification.
- Original vendor/network/recorder/standard RTSP processes and camera settings
  were preserved. Private SD staging, temporary daemons/timer and speaker lock
  were removed. Original high/low video was rechecked. This batch
  recorded MemAvailable 15,180 KiB before / 15,100 KiB after cleanup; these are
  uncontrolled snapshots, not measured savings. No flash or persistent
  replacement occurred. Physical acoustic quality remains unverified.

## Next goals after this batch

1. Validate an external host go2rtc/browser client against the standard camera
   backchannel when such a host is available. No browser/WebRTC bridge was
   installed; protocol/capture tests alone do not prove that integration works.
2. Verify physical microphone/speaker/standard G711/AAC talkback quality and
   playback cancellation, then sustain multi-client/slow-consumer/OOM tests.
3. Stage native ONVIF discovery/events validation, followed by motion-triggered
   recording and timestamped lookback footage. Keep conclusions tied to evidence.
4. Wi-Fi credential/failover and full-flash/boot restoration tests still require
   an independent recovery route. Continue read-only/source/fixture work while
   that route is unavailable; do not guess vendor offsets or bypass flash gates.
5. Review/prepare the uncommitted implementation for a deliberate versioned
   release only when deployment validation is complete. Keep standard RTSP and
   the SD speech companion; do not add a Go daemon to the firmware.
