# SipClient ↔ MVNO — Integration Guide (drop-in for this repo's README)

> Intended for the **`AI-SpamFilter-PMN/SipClient`** repo maintainer (ITI
> Java/Maven/JavaFX SIP client). MVNO (`AI-SpamFilter-PMN/MVNO`) exposes a
> **standard RFC-3261 SIP registrar/proxy with digest auth and a PCMU media
> relay** — any compliant UA registers and calls with **zero MVNO-side
> changes**. Canonical contract: **`docs/INTEGRATION_CONTRACT.md`** in MVNO;
> end-to-end demo walkthrough: MVNO `docs/LIVE_DEMO.md` S15.

## Connection facts

| Item | Value |
|---|---|
| SIP server | `<mvno-host-IP>:5060/udp` (canonical Kamailio host port) |
| Auth | Digest — **REGISTER and INVITE both challenged** (407 → retry with `Authorization: Digest`) |
| Realm | `localhost` |
| Credentials | `username = <MSISDN>` (e.g. `15553332211`), `password = testpass` |
| Codec | **PCMU (G.711u, PT 0) ONLY** — the relay does not transcode; PCMA/OPUS fail media |
| RTP relay | UDP `30000-30100` (RTPEngine) — open these + `5060/udp` in the firewall |
| 403 semantics | Zero-balance / EIR-fraud / AI-blocked calls → `SIP 403 Forbidden` — treat as **terminal** (no retry loop) |

> Your repo now reads `src/main/resources/sip.properties` at startup. Point it at
> the MVNO stack by setting `sip.server.host=<mvno-host-IP>` and
> `sip.server.port=5060` (canonical). No source edit is needed to connect a new
> host.

## Minimal registration trace (any Unicast/SIPDebugger/client)

1. `REGISTER sip:<server>:5060` with `Authorization: Digest username=<MSISDN>,
   realm=localhost` — expect `200 OK` when the number exists in the Kamailio
   subscriber table (seed via MVNO `scripts/add-subscriber.sh <MSISDN>`).
2. `INVITE sip:15559998888@<server>` — expect `407`, then digest retry → `200 OK`.
3. After `ACK`, stream PCMU — expect RTPEngine to relay + record a pcap.

## Prove your integration (against a live MVNO)

- Replicate `scripts/testing/sip_traffic_sim.py` behavior
  (REGISTER → 407 → digest → INVITE → RTP) — MVNO check `live_demo.sh` 5/6.
- MVNO acceptance: REGISTER `200 OK`, call answered, `rtpengine_bytes_total`
  moves, and your client surfaces the `403` on a zero-balance number
  (`15557654321` = balance 0).
- Walk through MVNO `docs/LIVE_DEMO.md` **S15** to test with your client as the
  external UA (LAN phone/laptop path, live Vosk verdict).