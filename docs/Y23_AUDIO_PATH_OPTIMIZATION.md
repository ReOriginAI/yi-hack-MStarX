# Y23 Audio-Path Optimization Notes

> Working notes for resource reduction in the retained local Y23 audio path. Changes in this file are not considered validated until a rebuilt firmware is tested on hardware.

## Current target

After cloud/P2P/upload ablation and the optional motion-worker optimization, one of the largest remaining named `rmm` CPU consumers is `AEC_BUF` at roughly 5–6% of one CPU in prior samples. The existing `ipc_cmd -I off` control only changes microphone volume; it does not stop the capture/AEC pipeline.

The next large optimization therefore remains: identify the exact `AEC_BUF` thread callback and determine whether it can be omitted when the selected feature profile does not require echo cancellation, microphone audio, local AAC recording, or speaker/backchannel coupling.

That binary-level change still requires a live A/B test and must not be guessed from strings alone.

## TinyALSA idle speaker FIFO finding

The patched TinyALSA playback path creates `/tmp/audio_in_fifo` for speaker/TTS/backchannel audio. The original implementation opens the FIFO read-only after using a temporary writer thread to unblock `open()`.

Once the temporary writer exits and no external speaker client is connected, `read()` sees EOF immediately. `fifo_read_thread()` then sleeps 10 ms and tries again. This creates an avoidable approximately 100 Hz wakeup loop for as long as the playback PCM remains open, even when no speaker audio is being used.

### Source change

`src/tinyalsa/Yihack_tinyalsa_idle_speaker.patch` now changes the internal FIFO descriptor from `O_RDONLY` to `O_RDWR` and removes the temporary writer-thread/join sequence from `pcm_create_snoop_fifo_in()`.

With an in-process writer endpoint kept open, the reader should block in the kernel while the FIFO is empty instead of repeatedly observing EOF. External writers such as `speaker.sh`, `speak.sh`, and RTSP/ONVIF backchannel producers can continue opening `/tmp/audio_in_fifo` and writing PCM normally.

The patch is applied after the historical Yi TinyALSA patch by `src/tinyalsa/init.tinyalsa`.

### Expected effect

This is intentionally a small optimization compared with `AEC_BUF` removal. Expected benefits are:

- eliminate the idle 10 ms polling wakeup in `fifo_read_thread`;
- remove one short-lived helper thread during PCM-output initialization;
- preserve the existing always-available `/tmp/audio_in_fifo` interface;
- avoid changing the proprietary `rmm` binary.

Do not assign a CPU or RAM saving until measured on the camera.

## Configuration inconsistency found

The shipped `system.conf` and `check_conf.sh` defaults currently contain:

```text
RTSP_AUDIO=yes
SPEAKER_AUDIO=yes
```

while the WebUI presents `RTSP_AUDIO=no` as `Disabled (default)` and the RTSP service has explicit codec handling for `no`, `pcm`, `alaw`, `ulaw`, and `aac` rather than `yes`.

This should be normalized, but it is a behavior/default migration decision rather than part of the TinyALSA FIFO fix. In particular, `SPEAKER_AUDIO` also supports the speaker/TTS endpoint, so changing it blindly could disable a feature that currently relies on `/tmp/audio_in_fifo` existing from boot.

## Live validation plan

When the Y23 terminal is available again:

1. Record the current build's idle thread wakeups/CPU with speaker/TTS configured but unused.
2. Rebuild with `Yihack_tinyalsa_idle_speaker.patch` and cold boot.
3. Confirm `/tmp/audio_in_fifo` exists and the TinyALSA FIFO reader remains blocked while idle.
4. Exercise `speaker.sh` and `speak.sh` and confirm PCM playback still works.
5. Exercise ONVIF/RTSP backchannel when configured.
6. Compare total `rmm` CPU and per-thread CPU before/after; expect only a small delta.
7. Separately map the `AEC_BUF` pthread callback and test an exact-hash-gated opt-out only for feature profiles that do not require the associated audio path.

The TinyALSA FIFO change should be reverted if it alters playback/backchannel semantics on the Y23 despite the expected POSIX FIFO behavior.
