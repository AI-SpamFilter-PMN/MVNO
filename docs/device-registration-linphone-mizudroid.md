# REAL-DEVICE SIP Registration — Ready-to-Paste Config (LIVE DB)

> Generated from the **live** Kamailio subscriber DB (`state/kamailio/kamailio.db`
> `subscriber` table) on 2026-08-09. These are the actual accounts that exist
> in the running stack — not invented. A human pasting these into an Android
> SIP client and calling the rig will exercise the real path.

## The one session every human step builds toward

```
[Android phone]  --SIP UDP--> 192.168.100.93:5066 (Kamailio) --rtpengine--> baresip-rx auto-answer 15559998888
     (register 15551234567)                                                       (answers + records RTP)
```

---

## A. Human DEVICE account (what YOU register on the phone)

| Field | Value | Source (live DB) |
|---|---|---|
| SIP username / Account ID | `15551234567` | `subscriber.username=15551234567` |
| Password | `testpass` | `subscriber.password=testpass` |
| Domain / Realm | `localhost` | `subscriber.domain=localhost` |
| Proxy server | `192.168.100.93:5066` | host wlan0 = `192.168.100.93/24`; Kamailio host-map 5066→5060udp |
| Transport | **UDP** | baresip/cfg uses UDP; all registered AoRs are UDP |
| Display name | `MVNO-UE1` | free-form; balance `100` (funded, non-blocked) |

> Why `15551234567`: balance=`100`, `blocked=0`, and it is **not** currently a
> registered SIP AoR (no collision with the 2G bridge `15554443322` / `15557778888`,
> the baresip rigs `15553332211` / `15559998888`, or UERANSIM UEs). `15557654321`
> is deliberately excluded (balance=`0` → SIP 403 contract).

## B. The number you CALL (rig auto-answer)

| Field | Value | Source |
|---|---|---|
| Call destination | `15559998888` | baresip-rx auto-answer AoR (registered `sip:15559998888@10.89.0.60:43972`) |

Verified reachable from the host network:
```
OPTIONS sip:15559998888@192.168.100.93 SIP/2.0   (from 192.168.100.93:50999)
==> SIP/2.0 200 OK
```
And from inside the stack the caller role got `407 → 180 Ringing → 200 OK` against
it (see `2026-08-09-g722-sip-rtp-path.md`).

---

## C. Linphone (Android) entry — copy-paste

**Account settings**
- SIP Identity / Username: `15551234567`
- Password: `testpass`
- Domain: `localhost`
- Proxy: `192.168.100.93:5066`
- Transport: `UDP`
- Display name: `MVNO-UE1`
- Codecs: enable **G.722/16000** (wideband) first, keep PCMU/G.711u as fallback
  (matches the containerized path).

## D. MizuDroid entry — copy-paste

**SIP account**
- Account name / Username: `15551234567`
- Password: `testpass`
- Domain / Realm: `localhost`
- Proxy / Outbound: `192.168.100.93:5066`
- Protocol: `UDP`
- Display name: `MVNO-UE1`
- Codecs: **G.722** ticked, PCMU fallback.

---

## E. Exact human actions (do these; then report back)

1. Join Wi-Fi **192.168.100.x** (same subnet as the rig host `192.168.100.93`).
2. Install **Linphone** or **MizuDroid** on an Android phone.
3. Add the SIP account from section **A/C/D**.
4. From the app, call **`15559998888`**.
   - It is auto-answered (baresip-rx, `answermode=auto`).
5. Speak the known demo scam phrase, e.g. **"You have won a prize, call us now"**,
   for ~5 seconds so the rig's Vosk ASR can transcribe it.
6. Send **one SMS** from the phone (if an SMS path for the phone is configured;
   otherwise use `scripts/testing/send_smpp_sms.py`).
7. Report back: the time you called, the phrase you spoke, and the SMS body.

> ⚠ I do **not** fabricate the phone event. The device registration and spoken
> call are yours to perform. Everything up to the physical device is pre-verified
> (see `2026-08-09-g722-sip-rtp-path.md`); the only unproven link is the phone.

## F. Where this came from

- Live DB dump: `state/kamailio/kamailio.db` → `subscriber` table (all 6 rows above).
- Host L2/L3: `ip -4 addr show` → `192.168.100.93/24` on `wlan0`.
- baresip-rx: `sip_traffic_sim.py` caller → `15559998888` auto-answer (probe above).
- Canonical subscriber constants: `scripts/lib/common.sh` (`MVNO_MSISDN_ALL`).