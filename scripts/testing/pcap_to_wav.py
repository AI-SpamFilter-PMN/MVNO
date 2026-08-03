#!/usr/bin/env python3
"""Extract G.711 (PCMU) audio from an rtpengine .pcap recording and write a
16-bit 8kHz mono WAV into state/spool/ for the Native Vosk ASR watcher.

rtpengine on this stack runs with recording-method=pcap, recording-format=eth,
so the capture contains full Ethernet frames. This script parses the RTP
streams (both directions), decodes u-law payloads, and interleaves the two
legs by capture time.

Usage:
    python3 scripts/testing/pcap_to_wav.py <call-*.pcap> [out.wav]

Exit 0 and prints the output path on success.
"""
import struct
import sys

ETH_HDR = 14


def _iter_packets(path):
    with open(path, "rb") as fh:
        magic = fh.read(4)
        if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
            endian = "<"
        elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
            endian = ">"
        else:
            raise SystemExit("not a classic pcap file")
        fh.seek(24)
        while True:
            hdr = fh.read(16)
            if len(hdr) < 16:
                break
            ts_sec, ts_usec, incl_len, _ = struct.unpack(endian + "IIII", hdr)
            data = fh.read(incl_len)
            if len(data) < incl_len:
                break
            yield ts_sec + ts_usec / 1e6, data


def _rtp_frames(pkt):
    data = pkt[ETH_HDR:]
    if len(data) < 34 or data[0] >> 4 != 4:
        return
    ihl = (data[0] & 0x0F) * 4
    proto = data[9]
    if proto != 17:
        return
    udp = data[ihl:]
    if len(udp) < 8:
        return
    rtp = udp[8:]
    if len(rtp) < 12 or rtp[0] >> 6 != 2:
        return
    payload_type = rtp[1] & 0x7F
    if payload_type != 0:
        return
    seq, rtp_ts = struct.unpack(">HI", rtp[2:8])
    yield seq, rtp_ts, rtp[12:]


def ulaw_decode(byte):
    byte = ~byte & 0xFF
    sign = byte & 0x80
    exponent = (byte >> 4) & 0x07
    mantissa = byte & 0x0F
    sample = (((mantissa << 3) + 0x84) << exponent) - 0x84
    if sign:
        sample = -sample
    return struct.pack("<h", sample)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".wav"

    legs = []
    for cap_ts, pkt in _iter_packets(src):
        for seq, rtp_ts, payload in _rtp_frames(pkt):
            if not payload:
                continue
            legs.append((cap_ts, payload))

    if not legs:
        raise SystemExit("no PCMU RTP payloads found in %s" % src)

    legs.sort(key=lambda f: f[0])
    pcm = b"".join(b"".join(ulaw_decode(b) for b in payload) for _, payload in legs)
    if not pcm:
        raise SystemExit("empty audio after decode")

    with open(dst, "wb") as out:
        out.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
        out.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16))
        out.write(b"data" + struct.pack("<I", len(pcm)) + pcm)

    import os

    os.chmod(dst, 0o777)
    print(f"[+] WAV extracted: {dst} ({len(pcm) / 16000:.1f}s audio)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
