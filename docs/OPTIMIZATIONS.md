# Portable Allwinner-v2X improvements on MStar Y23

Implemented on `master`, starting from MStarX `ff1407f`, using the net changes in
Allwinner-v2X `bcef7ff..2540e84` as the reference. Verification date: 2026-10-06.
This is an implementation record, not a claim that Allwinner vendor patches are
portable. Builds remain Y23-only. No release was published and the test camera
was not flashed or given persistent replacement scripts/libraries.

## Implemented behavior

- Native ONVIF/discovery logs and rotation use `/tmp/yi-service-logs`, a separate
  128 KiB tmpfs with 16 inodes. Native writers verify its filesystem type and
  total byte/inode capacity before opening or rotating logs. Failed/full mounts
  use `/dev/null`; a legacy-path symlink alone is insufficient for rotation.
- Shell boot, Wi-Fi, FTP, thumbnail and timelapse logs have 64 KiB/200-line
  bounds. Optional `rmm` thread diagnostics have a serialized 64 KiB bound.
- Configuration CGI work and native MQTT configuration updates share a process
  lock. Large temporary work requires mounted, writable SD storage. Backup is
  now `config.tar.bz2`: compressed size <=64 KiB, each file <=64 KiB, total
  configuration <=256 KiB and <=32 regular files. Restore rejects traversal,
  links, devices, duplicates, unknown entries, truncated archives and excessive
  decompression. Cleanup traps remove owned temporary files. Existing legacy
  `.7z` backups are not accepted by the new restore endpoint; create a new backup
  before upgrading. Flash replacement is atomic per file, not a transaction
  across all settings or a guarantee against power loss.
- `service.sh` owns RTSP daemons/grabbers, recording and shared IPC consumers.
  Start/stop/recovery operations are serialized. Repeated starts are idempotent;
  toggles, explicit-stop markers, camera switch and privacy state govern recovery.
  `all start` respects disabled MQTT and other service toggles. The watchdog
  remains alive with RTSP disabled and recovers optional services. SSH children
  are not mistaken for duplicate listeners. Listener checks work without IPv6.
- One-shot `oom_score_adj` policy protects the vendor core, networking and SSH
  listener, and makes optional services and temporary helpers more disposable.
  The watchdog reapplies it; there is no resident RAM reaper. Existing CPU-tick
  stall detection, local media initialization and IPC queue optimizations remain.
- Standard RTSP remains the default. The experimental minimal go2rtc module,
  toolchain dependency, UI option and packaged binary were removed at the user's
  request. Existing optional-backend compatibility and missing-binary fallback
  remain, but this build supplies no go2rtc binary.
- The packaged standard server uses its FIFO-only CLI (no upstream `-i` option),
  and finds vendor audio libraries under `/home/ms`.
  Standard PCM/G711/AAC choices remain. Grabber stdout buffers are 4 KiB with
  valid lifetimes, fixing the old dangling stack buffer and pointer-sized buffer.
- `RTSP_BACKCHANNEL` is the public setting. Legacy `ONVIF_AUDIO_BC` migrates and
  mirrors it. G711 and AAC talkback are retained for the standard server; physical
  talkback still needs validation. The alternative server advertises no reverse
  audio support. Speaker-disabled configurations do not advertise talkback.
  G711 RTP now uses the correct 8 kHz clock independently of the 16 kHz speaker
  PCM rate, with explicit PCMU/PCMA SDP mappings and signed A-law decoding.
  DESCRIBE uses a preview sink without opening the speaker FIFO or acquiring its
  lock. Each backchannel has one client owner; busy/unavailable SETUP returns
  503. TEARDOWN/TCP disconnect closes the sink, sockets and lock. A missing FIFO
  reader fails promptly rather than blocking the RTSP event loop.
- Speaker upload, SD file playback and offline speech share an exclusive kernel
  lock with standard-server reverse audio. PCM is 16 kHz, mono, S16LE; WAV accepts
  8/16 kHz mono PCM16, and PCMU/8 kHz streaming expands to 16 kHz. Uploads/output
  are limited to 4 MiB on SD. Playback supports cancellation and bounded FIFO
  backpressure; CGI staging is serialized. Speech text is limited to 1024 bytes,
  with six voices, speed, pitch and gain controls. NanoTTS reads CGI text on stdin.
- Wi-Fi recovery escalates through reassociation, reconfiguration, supplicant
  restart and an optional maintenance profile. It leaves wlan0 up and avoids the
  old six-failure reboot loop. Maintenance access is disabled by default and has
  UI controls. Configuration parsing handles BOM/CRLF, rejects duplicate/NUL/
  invisible-character inputs, and preserves MStar's erase/write/readback sequence
  for its exact 64 KiB `conf` partition, with an SD backup.
- Upgrade metadata uses `ReOriginAI/yi-hack-MStarX`. Checksums, SD/free-space gates,
  locks, archive allowlists, Y23 image sizes and JFFS2 magic are checked before
  publishing boot flash triggers. Configuration preservation is bounded and
  serialized. `fw_upgrade.sh?get=prepare` validates/stages without publishing
  triggers or rebooting. Full flashing still requires a working recovery route.

## Build and SD companion

The existing pinned Linaro GCC 4.8.3 toolchain, base firmware 0.5.7 and Jefferson
0.4.7 checks remain. The target compiler was compile/link tested with its 32-bit
host dependencies, and all native modules were built. New sources:

| Module | Reproducibility / placement |
| --- | --- |
| NanoTTS | `gmn/nanotts` commit `d8b91f3`, source SHA256, target compiler, static Pico; SD |
| storage tools | repository C source; small `archive_check` and `speaker` binaries in flash |
| BusyBox | packaged body-reading/compression/checksum/timeout/compare/`wc` applets |

Build output includes `y23_VERSION.tgz` (exactly `sys_y23` and `home_y23`),
`y23_VERSION_sd.tgz`, and `y23_VERSION.sha256`. The packer rejects images exceeding
Y23 partitions: sys <=1,966,080 bytes and home <=12,779,520 bytes. The SD companion
keeps offline speech and voice data off internal flash. The web
upgrader updates the flash bundle; update the matching SD companion separately.

On a camera already running the matching flash build, verify both downloaded
archives against the checksum manifest on the host. Copy/extract the SD companion
under the **mounted** `/tmp/sd` so its files land in `/tmp/sd/yi-hack` for offline
TTS. Development artifacts still use repository VERSION 0.5.7;
a future release must deliberately set VERSION and its matching tag.

## Live verification and measured limits

Test camera: `.26`, Y23, Linux 3.18.30, MemTotal 60,824 KiB, no swap. Test files and
large work were staged under a private directory on mounted SD. Streaming and
privacy tests briefly interrupted RTSP/recording, with timed rollback and an
explicit final restoration. SSH and Wi-Fi remained available; persistent camera
configuration and flash payloads were not replaced.

Verified with the rebuilt binaries and BusyBox on the camera:

- High/low RTSP video and AAC with the rebuilt standard server, including
  DESCRIBE, SETUP and PLAY. These are transport checks, not video-quality or
  frame-rate benchmarks.
- Offline synthesis produced 49,152 bytes of PCM and playback/upload/TTS CGI
  calls completed with zero playback gain. Physical speaker/backchannel acoustics,
  echo cancellation and microphone sound quality were not assessed.
- Repeated/concurrent RTSP starts, explicit-stop protection, privacy on/off, one
  recorder, disabled MQTT, RTSP-disabled watchdog survival and daemon-loss
  recovery. Portable tests also cover existing optional-backend fallback,
  quoted credentials, shared IPC ownership and privacy preserving stop intent.
- Config save/restore and JSON updates against an isolated SD configuration tree.
  IPC commands in the restore fixture were stubbed to avoid changing camera controls.
- A later backchannel batch used a private SD protocol fixture linked to the
  production native classes: PCMU and PCMA each decoded ten packets into 6,400
  bytes of 16 kHz PCM; AAC decoded eight frames into 16,384 PCM bytes. Discovery
  while busy, rejected concurrent SETUP, TEARDOWN, abrupt TCP disconnect and 20
  alternating cleanup sessions passed; fixture descriptors remained 4 -> 4.
  The rebuilt production daemon on port 5557 also accepted 50 PCMU silence
  packets through `/tmp/audio_in_fifo` and closed playback descriptors after
  TEARDOWN. Original daemons/config were preserved and staged processes/files
  removed. These tests do not establish audible quality or long-term stability.
- Actual 128 KiB log-mount exhaustion, 15 files plus the directory inode, native
  fallback when inodes were exhausted, and fallback before/after the mount.

Recorded snapshots favor standard RTSP for RAM use. The original default server
used 859 KiB PSS plus 111 KiB for each video grabber (1,081 KiB total). The
experimental go2rtc build used 6,214 KiB PSS fresh idle, 7,446 KiB after disconnect,
and 7,678 KiB with a high-video/AAC client plus 364 KiB for its producers. PSS
accounts proportionally for shared pages. Workloads were not matched: the original
server reported a missing AAC FIFO, and standard services remained running during
parallel-port Go probes. These are process snapshots, not a controlled system RAM
benchmark or proof of long-term stability. The experimental Go build is excluded
from the current deliverable.

Baseline/final-restoration MemAvailable was 15,128/15,124 KiB. No controlled
before/after RAM or CPU savings have been established for the retained changes.
Long-running multi-client pressure, slow consumers and real OOM recovery still
need a sustained hardware soak.

The installed camera binary set differs from this repository's build. Its original
RTSP daemon reported a missing AAC FIFO during restoration; the rebuilt standard
server's PCM-to-AAC path passed. The installed TinyALSA hash also differs from the
new build, so the existing source-level idle-speaker patch was not claimed to be
installed or benchmarked. Its replacement library was not injected into `rmm`.

## Automated checks and remaining hardware work

Run `python3 scripts/tests/test_archives.py`, `test_storage.py`,
`test_config_api.py`, `test_platform_scripts.py`, `test_speaker.py`,
`test_rtsp_sink.py` and `test_lifecycle.py`; also check shell syntax with `busybox ash -n`. CI runs these
and checks the extracted firmware, helpers, config keys and SD companion. Live
RTSP/backchannel probes accept a host and optional port/SSH control socket.
`test_rtsp_sink.py` compiles the production PCM sink with a small live555 I/O shim
and verifies preview/exclusivity, interprocess locking, signed A-law, PCM rate,
missing/full FIFO, reader loss and cleanup. `rtsp_backchannel_server.cpp` and
`test_rtsp_backchannel_live.py` are hardware-only fixtures; do not ship them in
firmware. The live fixture requires an existing private SD output file and a
host with FFmpeg for generating silent AAC packets.

Firmware validation and upgrade preparation are tested with ordinary fixture
files; no full flash or Wi-Fi credential write/recovery escalation was executed
on `.26`. Those need a proven independent recovery route. New ONVIF discovery and
motion event delivery need an end-to-end deployment test; existing daemons were
kept running during the staged stream tests. SD recording singleton behavior was
checked, but motion triggering and recording lookback were not proven with
new timestamped footage. Do not claim the lookback issue fixed.

No Allwinner VE/debugfs, IVA/NNA/PTZ, recorder binary offsets, automatic AEC or
reverted human-only behavior was ported. The camera's `rmm` matches the existing
MStar MD5 gate `598c74819e607648abb0c3402fda957f`; the optional motion-analysis
ablation remains feature-aware and disabled by default. Additional vendor ablation
requires separate disassembly, exact hashes, measured benefit and recovery tests.
