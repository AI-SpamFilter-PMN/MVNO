# Real-Time Call Transcription — Tier 1 Live + Tier 3 Fallback

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
Audio path for the MVNO interception demo: rtpengine records calls as pcap,
`live_tap.sh` turns them into WAVs, and the Native Vosk ASR watcher transcribes
them **live, during the call** (Tier 1) — with a post-call extraction fallback
(Tier 3). Zero Python in the audio path.

## Architecture

```
caller ──RTP──▶ rtpengine ──RTP──▶ callee
                  │  (recording-method=pcap, recording-format=eth)
                  ▼
         state/spool/pcaps/<call>.pcap   (grows DURING the call)
                  │
        live_tap.sh daemon  (1s poll, 4s chunks, per-src-IP legs)
                  │   tshark → awk → xxd → ffmpeg (mulaw → 16 kHz WAV)
                  ▼
         state/spool/live-<call>-<srcip>-<n>.wav   (chunks mid-call)
                  │
         NativeVoskService  (3s spool poll, transcribes + archives)
                  ▼
         state/spool/archived/live-*.txt  +  AI transcript verdict
```

## Tiers

| Tier | Path | When the transcript lands | Requirements |
|---|---|---|---|
| **Tier 1** (this repo) | `live_tap.sh daemon` — incremental frames → 4s chunks | **Mid-call**: ~4-6s after each chunk is written; for calls > ~10s the first transcript appears while the call is still live | tshark, xxd, ffmpeg (Step-1 prerequisites — nothing new) |
| **Tier 3** (this repo) | `live_tap.sh --once <pcap>` — full-call extraction | Post-call: ~5-10s after BYE (pcap completes → ASR) | same |
| Tier 2 (documented, NOT enabled) | kernel-module `proc` method + `rtpengine-recording` daemon | Mid-call WAV at source | root + dkms kernel build + host /proc mount — breaks the rootless design, see below |

Tier 1 and Tier 3 share the same certified extraction chain, so they are
byte-parity audio paths (verified 2026-08-07: 15 live chunks = 71.64s vs
`--once` = 71s, 0.6s chunk-boundary quantization).

## Extraction chain (certified, zero Python)

Per packet: `tshark -T fields` (frame.number, ip.src, udp.dstport, data.data)
→ awk keeps RTP only (even UDP dstport; RTCP odd ports dropped; PCMU payload
type 0; 12-byte RTP header stripped) → `xxd -r -p` → `ffmpeg -f mulaw -ar 8000
-ac 1 -ar 16000`. Audio is grouped **per source IP** — no leg classification
heuristic is needed; Vosk transcribes each leg separately.

**16 kHz output is mandatory**: the 8 kHz PCMU-native WAV decodes identically
but transcribes empty in Vosk; the 16 kHz resample yields the words (certified
2026-08-06 evidence: `baresip-call-16k.txt`).

## Run it

```bash
# Tier 1 — live daemon (foreground; use nohup/systemd in production):
scripts/testing/live_tap.sh daemon
# env: PCAP_DIR, SPOOL_DIR, TAP_DIR, POLL_SECS (1), CHUNK_SECS (4), IDLE_FINALIZE (3)

# Tier 3 — one completed call, straight into the Vosk spool:
scripts/testing/live_tap.sh --once $(\ls -t state/spool/pcaps/*.pcap | head -1)

# Watch transcripts + verdicts land:
watch -n2 '\ls -t state/spool/archived/live-* 2>/dev/null | head'
```

### systemd --user unit (optional, rootless)

```
# ~/.config/systemd/user/mvno-live-tap.service
[Unit]
Description=MVNO live_tap Tier-1 transcription watcher
After=default.target
[Service]
Type=simple
WorkingDirectory=/path/to/MVNO
ExecStart=/path/to/MVNO/scripts/testing/live_tap.sh daemon
Restart=on-failure
[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now mvno-live-tap
journalctl --user -u mvno-live-tap -f
```

## Behavior notes

- Adoption: pcaps modified in the last 2 min with size > 0; historical pcaps
  are never auto-processed (use `--once`).
- Retire: a recording whose pcap stops growing for `IDLE_FINALIZE` polls is
  flushed (final partial chunk) and marked done; state dirs are GC'd once the
  pcap is 5 min old. Concurrent calls are handled via per-call state dirs.
- Silence: rtpengine only records when RTP flows — a silent leg produces no
  packets and no chunks; a paused call (no packets mid-call) is retired early.
- Sample rate / chunk cadence are env-tunable; transcript latency is bounded
  by the 3s Vosk spool poll + ASR time (~1-3s), independent of the capture path.

## Latency budget and optional tuning (NOT applied — kept certified)

System floor (both tiers): 3s Vosk spool poll + 1-3s ASR = ~4-6s post-speech.
Tier 1 adds ≤ chunk size (4s) + capture lag: end-to-end ~8-15s after speech.

Optional snappier tuning (rootless, 2-line Java change + rebuild image):
`NativeVoskService` `@Scheduled(fixedDelay = 3000)` → `1000` and the
`file age > 3000ms` guard → `1000ms`; keep `POLL_SECS=1`. This was deliberately
NOT folded into the certified baseline (kept the proven 3s values); apply only
if the demo needs sub-5s transcripts.

## Tier 2 — kernel-module proc route (documented future work, NOT enabled)

The only way to get WAV-at-source mid-call without polling pcaps is
`recording-method=proc` + the packaged `rtpengine-recording` daemon
(`output-format=wav, resample-to=16000, output-mixed=true`). It requires the
`xt_RTPENGINE` kernel module: dkms build against the host kernel, `insmod`,
host nftables RTP redirection, and mounting host `/proc/rtpengine` into the
rtpengine container (`daemon/recording.c` proc_init: "kernel table not open"
without it; `recording-daemon/stream.c` reads `/proc/rtpengine/%u/calls/...`).

Why it was rejected for this repo:
- Requires root (dkms/insmod) — violates the rootless container mandate.
- The entire prize is ~1-3s of capture latency; both paths pay the same 3s
  Vosk poll + ASR floor, and ASR accuracy is identical (same relayed payloads).
- Every teammate machine needs a kernel build for its exact kernel version.
- Verified empirically 2026-08-06: a custom `mr26.1.1.5` image with the proc
  method + recording daemon produced zero WAVs without the kernel module.

CachyOS/Arch build sketch if ever needed: install `dkms`, `linux-headers`,
build `xt_RTPENGINE` from the rtpengine `mr26.1.1.5` source tag, `modprobe`,
then switch `rtpengine.conf` to `recording-method=proc` and deploy the
recording daemon container. The retired WS2 artifacts (Dockerfile,
`rtpengine-recording.conf`, `docker/spool/wavs` mounts) are recoverable from
git history if this path is ever pursued.
