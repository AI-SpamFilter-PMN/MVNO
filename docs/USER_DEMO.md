# MVNO USER-DRIVEN LIVE DEMO — runbook

This runbook is the **live, operator-driven** companion to the automatic
`make graduation` (deterministic gate). The USER types a custom SMS body or
speaks their own voice on a call — the network shows it back live.

## Auto vs User — the split (kept clean, no duplication)

| Surface | What it runs | Input |
|---|---|---|
| **AUTO** | `make graduation` / `make gate` / `sms_matrix.sh` / `demo_call.sh` | Canned, deterministic scripted content |
| **USER** | `scripts/demo/user_demo.sh` → `user_sms.sh` / `user_call.sh` | **Live, typed / spoken by you** |

Each `user_*` script **reuses** the existing tested primitive (no new send/ASR
logic): `send_rest_sms.sh` (REST SMS), `demo_call.sh` (baresip dial),
`mic_record.sh` (64k capture), `live_tap` (RTP→Vosk), `NativeVoskService`
(ASR). So the user-driven path is the *same* pipeline — just fed by you.

## Order (readiness → live)

```sh
# 1) stack up (all containers, Vosk small-model + live-tap daemon)
make up

# 2) confirm the microphone is audible (non-fatal)
bash scripts/demo/mic_probe.sh

# 3) USER SMS — type any body, pick any MVNO flow
make user-sms BODY="You have won a prize, call us now" FLOW=2g-2g
#   or interactively:
make user-demo            # menu → 3) User SMS

# 4) USER LIVE VOICE CALL — speak 10s, Vosk transcribes YOUR words
make user-call            # caller rig → 15559998888
#   or interactively:      make user-demo → 4) User Call

# 5) evidence: scam-flag counters
curl -s localhost:8080/actuator/prometheus | grep mvno_vosk_scamflag
```

## User SMS flows

`user_sms.sh "<body>" <flow>` — `<flow>` is one of:

| flow | route | sender → recipient |
|---|---|---|
| `2g-2g` | 2G SMSC direct | 15557778888 → 15554443322 |
| `2g-5g` | SMSC→SIP relay | 15554443322 → 15551234567 |
| `5g-2g` | bridge→SMPP | 15551234567 → 15554443322 |
| `5g-5g` | Kamailio twin | 15551234567 → 15557654321 |
| `ai` | 5G→5G AI-block | 15551234567 → 15557654321 (no delivery) |

Example — a real scam body flagged live (non-blocking):
```sh
make user-sms BODY="your bank account has been blocked, please verify your details" FLOW=5g-5g
```
The Interception Gateway runs balance → EIR → AI-spam. A scam keyword match
rows the review **FLAG** (`mvno.vosk.scamflag{word}`) and returns **allow=true**
(NEVER hard-blocks the call/SMS) — the exact "flag without blocking" contract.

## Why a silent mic no longer fails graduation

The automatic `mic_verify` hard-asserts a **non-empty this-run transcript**; a
quiet room yields an empty Vosk text (silence is not a transcription error). In
the USER-driven demo **you actually speak**, so `user_call.sh` shows your live
words. If you want `make graduation` to tolerate a silent stage, it can be
softened via an env flag (see `mic_verify.sh`); the live path is the intended
"see your words" demo.

## Links

- Automatic deterministic gate: `Makefile` `graduation` / `gate` targets, `scripts/testing/gate.sh`
- Voice pipeline: `docs/REALTIME_AUDIO.md`, `docs/LIVE_DEMO.md`
- Flag-for-review: `docs/DB-Changes.md`, `scripts/review/flag_watch.sh`