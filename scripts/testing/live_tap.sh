#!/usr/bin/env bash
# ==============================================================================
# live_tap.sh — Tier-1 live transcription tap + Tier-3 --once extraction
# ------------------------------------------------------------------------------
# Converts rtpengine pcap recordings (recording-method=pcap, recording-format=eth)
# to G.711u 16 kHz mono WAV files for the Native Vosk ASR spool watcher — zero
# Python, reusing the certified tshark -> awk -> xxd -> ffmpeg extraction chain
# (see docs/REALTIME_AUDIO.md and docs/LIVE_DEMO.md S4).
#
# Extraction chain (per packet, certified byte-parity vs the retired Python
# baseline): tshark fields (ip.src, udp.dstport, data.data) -> awk keeps only
# RTP (even UDP dstport; RTCP odd ports dropped; PCMU payload type 0 via the
# RTP header byte; 12-byte RTP header stripped) -> xxd -r -p -> ffmpeg mulaw.
# Audio is grouped into one stream per rtpengine PROXY PORT (udp.dstport; one
# per call leg). rtpengine rewrites BOTH directions to the same source IP
# (its eth0 / the proxy source), so source-IP grouping would merge caller and
# callee into one mangled stream. Port-based grouping keeps each side separate
# so Vosk transcribes them independently and they can be labeled caller/callee
# (e.g. live-<stem>-30000-N.wav = one side, live-<stem>-30020-M.wav = the other).
#
# Modes:
#   daemon  Poll PCAP_DIR every POLL_SECS (default 1s). Reads only NEW packets
#           (frame.number > last seen), appends them to the per-leg streams of
#           each active recording, and muxes a leg into a WAV chunk whenever
#           CHUNK_SECS (default 4s) of new audio accumulates. Chunks are dropped
#           into the Vosk spool root as live-<stem>-<srcip>-<n>.wav for
#           MID-CALL transcription (Tier 1; NativeVoskService polls every 3s).
#           A recording whose pcap has been idle for IDLE_FINALIZE polls is
#           flushed (final partial chunk) and retired.
#   --once  Extract every leg of ONE completed pcap into <stem>-<srcip>.wav in
#           the Vosk spool root (Tier-3 post-call fallback, replaces
#           pcap_to_wav.py). Prints the written paths; exits 1 on no audio.
#
# Prerequisites (Step-1 tool check): tshark, xxd, ffmpeg. Requires GNU awk.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PCAP_DIR="${PCAP_DIR:-${PROJECT_DIR}/state/spool/pcaps}"
SPOOL_DIR="${SPOOL_DIR:-${PROJECT_DIR}/state/spool}"
TAP_DIR="${TAP_DIR:-${SPOOL_DIR}/tmp/live_tap}"
POLL_SECS="${POLL_SECS:-0.5}"
CHUNK_SECS="${CHUNK_SECS:-2.5}"
IDLE_FINALIZE="${IDLE_FINALIZE:-2}"

for tool in tshark xxd ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "[-] live_tap.sh: '$tool' not found (Step-1 prerequisite)" >&2
        exit 1
    }
done

usage() {
    cat <<EOF
Usage:
  $0 daemon                      Tier-1 live watcher (foreground)
  $0 --once <recording.pcap>     Tier-3 post-call extraction into the spool

Env: PCAP_DIR, SPOOL_DIR, TAP_DIR, POLL_SECS, CHUNK_SECS, IDLE_FINALIZE
EOF
    exit "${1:-0}"
}

tap_id() {
    printf '%s' "$(basename "$1" .pcap)" | tr -c 'A-Za-z0-9._-' '_'
}

# Extract new RTP packets (frame.number > $2) from pcap $1 into per-src-IP hex
# streams under $3 and record the highest frame number in $3/.maxframe.
# stdout: highest frame number seen (0 when no new frames).
extract_new() {
    local pcap="$1" min_frame="$2" dir="$3"
    tshark -r "$pcap" -Y "frame.number > ${min_frame}" \
        -T fields -e frame.number -e ip.src -e udp.dstport -e data.data 2>/dev/null \
        | awk -v d="$dir" '
            BEGIN { max = 0 }
            $2 != "" && $3 % 2 == 0 && $4 != "" {
                h = substr($4, 1, 24)          # CLI/rtp 12-byte header as hex
                pt = substr(h, 3, 2)           # RTP payload type byte (hex)
                # Store the payload type as decimal for the codec-aware decoder.
                # PT 0=G.711u (PCMU), 8=G.711a (PCMA), 9=G.722, 96/111=Opus.
                ptdec = strtonum("0x" pt)
                # Only keep audio payload types we can decode (below); store the
                # first-seen PT per leg so mux_leg picks the right decoder.
                if (ptdec + 0 != ptdec + 0 || ptdec < 0) next
                if (ptdec != 0 && ptdec != 8 && ptdec != 9 && ptdec != 96 && ptdec != 111) next
                # LEG GROUPING: rtpengine (recording-method=pcap) rewrites BOTH
                # directions to the same source IP (its own eth0 / the proxy
                # source 10.89.0.1), so grouping by ip.src collapses caller and
                # callee into ONE mangled stream (Vosk -> empty/single-word).
                # udp.dstport is the rtpengine per-leg PROXY port (one per call
                # side), so it uniquely separates the two directions for
                # per-side transcription + caller/callee labeling. RTCP even
                # (>base) pairs are excluded by the modulo-2 RTP-only gate.
                if (! (($3) in seentype)) seentype[$3] = ptdec
                print substr($4, 25) >> (d "/" $3 ".hex")
                if ($1 > max) max = $1
            }
            END {
                if (max > 0) print max > (d "/.maxframe")
                for (port in seentype) print seentype[port] > (d "/" port ".pt")
            }'
    cat "$dir/.maxframe" 2>/dev/null || echo 0
}

# Mux hex stream (skipping the first $2 hex chars, i.e. already-chunked audio)
# to a 16 kHz WAV at $3. Returns 0 if a WAV was written, 1 if there was no new
# audio. 16 kHz output: the certified transcription evidence (2026-08-06) shows
# the 8 kHz PCMU-native WAV decodes identically but transcribes EMPTY in Vosk,
# while the 16 kHz resample yields the spoken words (Vosk model is 16 kHz).
mux_leg() {
    local hex="$1" off="$2" out="$3"
    # Payload type for the decoder: 0=G.711u (PCMU), 8=G.711a (PCMA), 9=G.722,
    # 96/111=Opus. Falls back to PCMU/mulaw when the leg has no recorded PT (legacy).
    local ptfile="${hex%.hex}.pt"
    local pt=0
    [ -f "$ptfile" ] && pt="$(cat "$ptfile" 2>/dev/null || echo 0)"
    [ "$(wc -c < "$hex")" -gt "$off" ] || return 1

    # Codec-aware decode to 16 kHz mono for the Vosk 16 kHz model. NOTE: the
    # g722 / opus demuxers already know their sample rate (16k / 48k native), so
    # no -ar is passed to the INPUT (ffmpeg errors "Option sample_rate not
    # found"); only the OUTPUT -ar 16000 resamples. -ac 1 forces mono.
    local dec
    case "$pt" in
        8)  dec="-f alaw -ar 8000" ;;              # G.711a (PCMA)
        9)  dec="-f g722" ;;                       # G.722 wideband (16 kHz native)
        96|111) dec="-f opus" ;;                   # Opus (48 kHz native -> resample; 96=Linphone, 111=baresip)
        *)  dec="-f mulaw -ar 8000" ;;             # G.711u (PCMU) / default fallback
    esac

    if tail -c +$((off + 1)) "$hex" | xxd -r -p | \
        ffmpeg -nostdin -loglevel error $dec -ac 1 -i pipe:0 -ar 16000 -y "$out" 2>/dev/null; then
        chmod 666 "$out" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Chunk a leg: write a WAV of the accumulated audio since the last chunk.
chunk_leg() {
    local dir="$1" ip="$2" force="$3"
    local hex="$dir/$ip.hex" seq off total newsecs
    [ -f "$hex" ] || return 0
    seq=$(cat "$dir/$ip.seq" 2>/dev/null || echo 0)
    off=$(cat "$dir/$ip.off" 2>/dev/null || echo 0)
    total=$(wc -c < "$hex")
    newsecs=$(( (total - off) / 2 / 8000 ))
    if [ "$force" = "1" ] || [ "$newsecs" -ge "$CHUNK_SECS" ]; then
        local stem out
        stem="$(basename "$(cat "$dir/.pcap.path" 2>/dev/null || echo unknown)" .pcap)"
        out="${SPOOL_DIR}/live-${stem}-${ip}-${seq}.wav"
        if mux_leg "$hex" "$off" "$out"; then
            echo "$(date +%H:%M:%S)  live chunk: $(basename "$out") (${newsecs}s audio)"
            echo "$((seq + 1))" > "$dir/$ip.seq"
        fi
        echo "$total" > "$dir/$ip.off"
    fi
}

# One daemon cycle: adopt fresh recordings, extract new frames, chunk legs.
process_cycle() {
    for pcap in $(find "$PCAP_DIR" -maxdepth 1 -name '*.pcap' -size +0c -mmin -2 2>/dev/null | sort); do
        local id dir last max
        id="$(tap_id "$pcap")"
        dir="$TAP_DIR/$id"
        [ -f "$dir/.done" ] && continue
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            echo "$pcap" > "$dir/.pcap.path"
        fi
        last=$(cat "$dir/.maxframe" 2>/dev/null || echo 0)
        max=$(extract_new "$pcap" "$last" "$dir")
        if [ "$max" -gt "$last" ]; then
            for hex in "$dir"/*.hex; do
                [ -f "$hex" ] || continue
                chunk_leg "$dir" "$(basename "$hex" .hex)" 0
            done
        fi
    done
}

# Retire recordings whose pcap stopped growing (call ended): flush the final
# partial chunk of each leg, then mark the recording done so it is never
# re-adopted (the pcap stays fresh for -mmin -2 and would otherwise loop).
# .done state dirs are garbage-collected once their pcap is old or gone.
retire_idle() {
    local now grace
    now=$(date +%s)
    grace=$((IDLE_FINALIZE * POLL_SECS + 2))
    for dir in "$TAP_DIR"/*/; do
        [ -d "$dir" ] || continue
        case "$dir" in
            */once.*) continue ;; # --once dirs are managed by their own process
        esac
        local pcap age
        pcap=$(cat "$dir/.pcap.path" 2>/dev/null || true)
        if [ -f "$dir/.done" ]; then
            if [ ! -f "$pcap" ] || [ $(( now - $(stat -c %Y "$pcap") )) -ge 300 ]; then
                rm -rf "$dir"
            fi
            continue
        fi
        age=0
        [ -f "$pcap" ] && age=$(( now - $(stat -c %Y "$pcap") ))
        if [ -z "$pcap" ]; then
            # Orphaned state (e.g. a leaked temp dir): not a recording, drop it.
            rm -rf "$dir"
            continue
        fi
        if [ ! -f "$pcap" ] || [ "$age" -ge "$grace" ]; then
            for hex in "$dir"/*.hex; do
                [ -f "$hex" ] || continue
                chunk_leg "$dir" "$(basename "$hex" .hex)" 1
            done
            echo "$(date +%H:%M:%S)  retired: $(basename "$pcap")"
            touch "$dir/.done"
        fi
    done
}

daemon() {
    mkdir -p "$TAP_DIR" "$SPOOL_DIR"
    echo "live_tap daemon: polling ${PCAP_DIR} every ${POLL_SECS}s (chunk ${CHUNK_SECS}s, idle-finalize ${IDLE_FINALIZE} polls)"
    while true; do
        process_cycle
        retire_idle
        sleep "$POLL_SECS"
    done
}

once_mode() {
    local pcap="$1" stem written
    [ -f "$pcap" ] || { echo "[-] not found: $pcap" >&2; exit 1; }
    mkdir -p "$SPOOL_DIR" "$TAP_DIR"
    stem="$(basename "$pcap" .pcap)"
    ONCE_DIR="$(mktemp -d "${TAP_DIR}/once.XXXXXX")"
    trap 'rm -rf -- "$ONCE_DIR"' EXIT
    extract_new "$pcap" 0 "$ONCE_DIR" >/dev/null
    written=0
    for hex in "$ONCE_DIR"/*.hex; do
        [ -f "$hex" ] || continue
        local ip out dur
        ip="$(basename "$hex" .hex)"
        out="${SPOOL_DIR}/${stem}-${ip}.wav"
        if mux_leg "$hex" 0 "$out"; then
            dur=$(( $(wc -c < "$hex") / 2 / 8000 ))
            echo "[+] WAV extracted: ${out} (${dur}s audio)"
            written=1
        fi
    done
    [ "$written" -eq 1 ] || { echo "[-] no PCMU RTP payloads found in $pcap" >&2; exit 1; }
}

case "${1:-}" in
    daemon) daemon ;;
    --once) [ $# -eq 2 ] || usage 1; once_mode "$2" ;;
    *) usage 1 ;;
esac
