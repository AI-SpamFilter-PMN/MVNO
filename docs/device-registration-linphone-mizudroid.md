# REAL-DEVICE SIP Registration — Ready-to-Paste Config (LIVE DB)

> Generated from the **live** Kamailio subscriber DB (`state/kamailio/kamailio.db`
> `subscriber` table) on 2026-08-09. These are the actual accounts that exist
> in the running stack — not invented. A human pasting these into an Android
> SIP client and calling the rig will exercise the real path.

## The one session every human step builds toward

```
[Android phone]  --SIP UDP--> <HOST-LAN-IP>:5060 (Kamailio) --rtpengine--> baresip-rx auto-answer 15559998888
     (register 15551234567)                                                       (answers + records RTP)
```

> **Host LAN IP** is machine-specific. Discover it with:
> `hostname -I | awk '{print $1}'` (returns e.g. `192.168.100.93` on the wired rig
> host). In every config below replace `<HOST-LAN-IP>` with that value. The Kamailio
> host SIP port is **5060** (UDP) — the canonical published port.

---

## A. Human DEVICE account (what YOU register on the phone)

| Field | Value | Source (live DB) |
|---|---|---|
| SIP username / Account ID | `15551234567` | `subscriber.username=15551234567` |
| Password | `testpass` | `subscriber.password=testpass` |
| Domain / Realm | `localhost` | `subscriber.domain=localhost` |
| Proxy server | `<HOST-LAN-IP>:5060` | host LAN IP (discover via `hostname -I`); Kamailio host port 5060 (canonical) |
| Transport | **UDP** | baresip/cfg uses UDP; all registered AoRs are UDP |
| Display name | `MVNO-UE1` | free-form; balance `100` (funded, non-blocked) |

> Why `15551234567`: balance=`100`, `blocked=0`, and it is **not** currently a
> registered SIP AoR (no collision with the 2G bridge `15554443322` / `15557778888`,
> the baresip rigs `15553332211` / `15559998888`, or UERANSIM UEs). `15557654321`
> is deliberately excluded (balance=`0` → SIP 403 contract).

## B. The number you CALL (rig auto-answer)

| Field | Value | Source |
|---|---|---|
| Call destination | `15559998888` (bare) — or `+2015559998888` / `015559998888` / `002015559998888` | baresip-rx auto-answer AoR (registered `sip:15559998888@10.89.0.60:43972`); Kamailio `route[NORMALIZE]` (dialplan dpid=4) rewrites any E.164 `+2015…` / national `0155…` / `00…` form to the bare `15XXXXXXXXX` before `lookup()`. See `docs/ENVIRONMENT_MATRIX.md` §3a |

Verified reachable from the host network:
```
OPTIONS sip:15559998888@<HOST-LAN-IP> SIP/2.0   (from <HOST-LAN-IP>:50999)
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
- Proxy: `<HOST-LAN-IP>:5060`
- Transport: `UDP`
- Display name: `MVNO-UE1`
- Codecs: enable **G.722/16000** (wideband) first, keep PCMU/G.711u as fallback
  (matches the containerized path).

## D. MizuDroid entry — copy-paste

**SIP account**
- Account name / Username: `15551234567`
- Password: `testpass`
- Domain / Realm: `localhost`
- Proxy / Outbound: `<HOST-LAN-IP>:5060`
- Protocol: `UDP`
- Display name: `MVNO-UE1`
- Codecs: **G.722** ticked, PCMU fallback.

---

## E. Exact human actions (do these; then report back)

1. Join the **same Wi-Fi/LAN subnet as the rig host** (the host running the stack).
2. Install **Linphone** or **MizuDroid** on an Android phone.
3. Add the SIP account from section **A/C/D**.
4. From the app, call **`15559998888`**.
   - It is auto-answered (baresip-rx, `answermode=auto`).
5. Speak the known demo scam phrase, e.g. **"You have won a prize, call us now"**,
   for ~5 seconds so the rig's Vosk ASR can transcribe it.
6. Send **one SMS** from the phone (if an SMS path for the phone is configured;
   otherwise use `scripts/testing/send_smpp_sms.py`).
   - Both Linphone and MizuDroid are supported for SMS (Issues 8.51/8.56): the
     bridge accepts bracketless `To: sip:..@..` headers and Kamailio normalizes
     `+`/`00`/`0`-prefixed `From:` before the OCS lookup — use the bare MSISDN
     `15551234567` or the international `+2015551234567` form, either works.
   - Typing indicators while composing are consumed silently (Issue 8.52) —
     only the actual sent message is delivered to the 2G MS.
7. Report back: the time you called, the phrase you spoke, and the SMS body.

> ⚠ I do **not** fabricate the phone event. The device registration and spoken
> call are yours to perform. Everything up to the physical device is pre-verified
> (see `2026-08-09-g722-sip-rtp-path.md`); the only unproven link is the phone.

## F. Where this came from

- Live DB dump: `state/kamailio/kamailio.db` → `subscriber` table (all 6 rows above).
- Host L2/L3: `ip -4 addr show` → `<HOST-LAN-IP>/24` on the active interface (LAN IP from `hostname -I`).
- baresip-rx: `sip_traffic_sim.py` caller → `15559998888` auto-answer (probe above).
- Canonical subscriber constants: `scripts/lib/common.sh` (`MVNO_MSISDN_ALL`).