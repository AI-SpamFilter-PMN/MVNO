# Architecture Decisions & Verified Recommendations (`ARCHITECTURE_DECISIONS.md`)

> Written 2026-08-14 after a full cold-start verification gate + cross-client
> (Android Linphone / MizuDroid / Java SipClient) hardening pass. This document
> records **decisions taken** (with evidence) and **recommendations** for the
> three open architecture questions raised during the deep-run review:
> (1) is `ip-sm-gw` the correct approach for SMS interworking, or is there a
> maintained project like Kamailio/OsmoCOM/Asterisk that does it for us?
> (2) does our NeonDB change the picture / is the bridge even needed?
> (3) are conference calling + accept/decline + reply-with-message already
> implemented in a platform we can use, or do we build a platform from scratch?

---

## 1. SMS Interworking: keep the Python IP-SM-GW bridge (validated decision)

**Decision: KEEP `scripts/ip_sm_gw.py` as the SIP↔SMPP interworking bridge.**

### Why keep it (evidence, not vibes)

- It is a **consumer of OsmoSMSC's own SQLite delivery queue** (poll loop over
  `smsc.db`), not a store — there is no competing open-source component that
  "plugs in" there without replacing OsmoSMSC itself.
- It performs exactly three jobs, all small and now unit-tested (33 tests):
  1. poll OsmoSMSC's `smsc.db` for MT-SMS rows and deliver them as SIP MESSAGE
     to the 5G/IMS side (2G→5G leg);
  2. receive SIP MESSAGE from Kamailio and submit them to OsmoSMSC over SMPP
     (`:2775`) for the 2G radio path (5G→2G leg);
  3. REGISTER the 2G MSISDNs with Kamailio so `lookup("location")` can route
     to the bridge.
- The bugs that kept "popping up" were **real defects in the bridge**, each
  root-caused and fixed with a regression test this session (strict `To:`
  regex, bare-LF `reply_ok()` losing the 200 OK, typing-indicator relay, stale
  REGISTER refresh, GSM-7 double-encode, SMPP bind-response drain, unbounded
  retry, malformed `Via:` in the 200 OK). The defect rate is now dropping: 4
  fixes landed on 2026-08-14, the gate is green (35/35 unit tests + SMS
  matrix + demo-verify), and the remaining entries in ISSUES.md are
  observations (AO), not crashes.

### Why not switch to a "maintained" alternative

Researched 2026-08-14 (web + code):

| Option | Verdict | Why |
|---|---|---|
| **OpenSIPS `proto_smpp`** | ✗ wrong fit | A SIP↔SMPP *gateway module* (SMPP-ESME to SIP), not an IP-SM-GW; would require re-plumbing the whole signaling path (replace Kamailio or run OpenSIPS in front) for zero functional gain over our 400-line bridge. It interworks *SMPP sessions*, not OsmoSMSC's internal queue. |
| **paicoretech/ip-sm-gw** (GitHub) | ✗ wrong fit | A real IP-SM-GW but architected around **SS7/MAP (SIGTRAN) + Kafka + ScyllaDB** — it expects a carrier-grade core with an MSC/MAP subscriber model. Our lab has OsmoSMSC (no MAP) and a 34-container compose; adopting it would mean adding an SS7 stack and two data systems for a demo. |
| **OsmoSMSC native MT handling** | ✓ already used | OsmoSMSC already *is* the SMSC; the only missing piece is the SIP leg to 5G/IMS, which is precisely what the bridge adds. There is no Osmocom SIP-SMSC-GW product. |
| **Asterisk `chan_sip` + SMPP** | ✗ wrong fit | Asterisk is a PBX/media server; SMS-over-IP there is `chan_mobile`/SMS plugins, not a managed interworking gateway with a delivery queue + OCS/intercept integration like ours. |

**Conclusion:** for an interception-core lab with OsmoSMSC + Kamailio, a small
purpose-built bridge is the *correct* shape; the alternatives are either
heavier (SS7 + Kafka), differently-scoped (OpenSIPS module), or a different
product class (Asterisk). The right move is what we did: harden the bridge
with tests, not replace it. The bridge is **not** a "reliable source such as
Kamailio or OsmoCOM" — it is a thin glue layer; its reliability comes from the
test suite (35 unit tests + SMS matrix + gate), which is now enforced.

---

## 2. NeonDB / database role: no, it does not replace the bridge (validated)

**Decision: NeonDB does NOT mitigate or replace the IP-SM-GW bridge.**

- The bridge **does not own state** that NeonDB could hold: it polls
  `state/kamailio/smsc.db` (OsmoSMSC's SQLite) and `state/kamailio/kamailio.db`
  (Kamailio usrloc/auth). It is a stateless relay with an in-memory counter set
  for metrics.
- NeonDB (the org's Postgres, used by `sms-client` on `:2076` per
  INTEGRATION_CONTRACT §5) is the **right store for org-level business state**
  (subscriber OCS balances, campaign/decider data, delivery receipts for the
  `sms-client` product) — none of which the bridge reads or writes.
- Replacing the bridge's OsmoSMSC polling with "push to NeonDB then relay"
  would add a moving part (a DB write + a consumer) with zero reliability gain
  and would make delivery *dependent* on an external DB being up — worse SLA,
  not better.

**Conclusion:** keep the bridge as a thin consumer of OsmoSMSC's queue. If the
org wants a durable outbound campaign store, put it in NeonDB at the
`sms-client`/decider layer (which already targets `:2076`), not between
OsmoSMSC and Kamailio.

---

## 3. Conferencing, accept/decline, reply-with-message: use an existing platform (recommendation)

**Question:** are conference calling + accept/decline (call screening) +
reply-with-message already implemented in a platform we can use, or do we build
a platform from scratch?

**Answer: they are commodity features of a media-server platform. We should
NOT build them; we should add a platform (Asterisk recommended) beside
Kamailio.** Researched 2026-08-14:

| Feature | Platform | Where it lives today |
|---|---|---|
| **Conference bridges** | Asterisk `app_confbridge` / FreeSWITCH `mod_conference` | Battle-tested multi-party mixing (audio + video), conference PINs, recording, admin controls. FreeSWITCH and Asterisk both expose them over a control API. |
| **Accept/Decline (call screening)** | Asterisk `app_authenticate`/`Read` + `Hangup`, FreeSWITCH XML dialplan; **baresip already does it** | The classic "screening" flow: caller says who they are, callee accepts/declines. In our rig, baresip's call UI already offers Answer/Decline (verified live on the Android Linphone call — the phone showed Answer/Decline buttons), and baresip `menu` handles accept/reject. For IVR-style screening, Asterisk is the standard. |
| **Reply-with-message (SMS/voicemail reply)** | Asterisk voicemail (`app_voicemail`), or SMS reply via our existing intercept pipeline | Voicemail + "press 1 to accept, 2 to decline, 3 to leave a message" is stock Asterisk. SMS reply is our own SMS intercept path (already working) — a platform feature, not a build. |
| **Our interception core** | Kamailio + rtpengine + telecom-api | Already the policy/recording layer; a media platform would sit AFTER interception (Kamailio routes the established call to the platform for screening/conference), not replace it. |

### Concrete recommendation (IMPLEMENTED 2026-08-14 — see below)

- **Do NOT build a platform.** Add **Asterisk** (or FreeSWITCH) as a
  media-server sidecar: Kamailio `route[INTERCEPT]` → policy verdict → if
  screening/conference requested, hand the dialog to the platform (Asterisk
  via SIP B2BUA or `dialplan`/`manager` API). Conference + voicemail +
  accept/decline are all stock dialplan/AGI features with decades of docs and
  an active community.
- baresip already covers the simple "accept/decline a ringing call" case (used
  in the rig and on Android Linphone) — no code needed there.
- The org's Filteration-System decider stays the policy owner; the media
  platform is a *consumer* of its verdicts, keeping the interception core
  unchanged.

### Implementation status (2026-08-14) — DONE

Asterisk 20.6 runs as `mvno-asterisk` on the bridge net (10.89.0.63), built
from `configs/asterisk/Dockerfile` (Ubuntu 24.04 packaged `apt install
asterisk` — same image on the CachyOS host and Ubuntu teammates). Kamailio
routes feature numbers to the SIP trunk at :5061:

| Feature | Dialed number | Verified live 2026-08-14 |
|---|---|---|
| Conference (ConfBridge) | `7XXX` (e.g. 7001) | 2 callers (baresip-tx 15553332211 + baresip-rx 15559998888) joined ConfBridge 001, RTP recorded, 0% loss, clean hangup |
| Voicemail main | `8XXX` (e.g. 8100) | VoiceMailMain executes, mailbox found |
| Screening demo | `8000` | Record() saved the caller's name WAV; accept (1) dialed the rig callee via Kamailio as UA 15550000001 and CONNECTED; decline (2) / message (3) branches wired |
| Accept/decline | native SIP (200/486/603) | baresip/Linphone UI (no code) |

Notes: `asterisk` was DROPPED from Debian 12 main (sound packages only), so
the image is Ubuntu-based (Asterisk 20.6.0). app_voicemail_imap/odbc must be
`noload`ed (they clobber the file-based VoiceMailMain registration). Screening
uses a registered Asterisk UA `15550000001` (`scripts/add-subscriber.sh`)
for the accept-leg so it rings the real rig callee. See ISSUES.md 8.62.

---

## 4. Decisions recorded this session (2026-08-14)

| # | Decision | Evidence |
|---|---|---|
| D1 | Keep the Python IP-SM-GW bridge; harden with tests (35 now) | 4 fixes landed 08-14; SMS matrix all cells green; unit suite 35/35 |
| D2 | NeonDB is org-level state only; bridge stays DB-free | Bridge polls OsmoSMSC/Kamailio SQLite; no state of its own |
| D3 | Normalize `$fU` (From) in Kamailio before the intercept payload | Cross-client `+1555..` message no longer 403s as "Prepaid balance exhausted" |
| D4 | Gate RFC 3994 typing indicators at BOTH Kamailio and the bridge | `SMS TYPING-INDICATOR CONSUMED` + `[SKIP] typing indicator`; no fake SMS rows |
| D5 | baresip rigs get `ctrl_tcp_listen 0.0.0.0:4444` + `baresip_dial.py` for gate dials | demo-verify.sh all gates green, two consecutive runs |
| D6 | RTP pcap assertions decode the whole `10000-20000` range (dynamic ports) | observed 10032/10044 on 08-14; 0% loss |
| D7 | Conference/voicemail/screening = Asterisk sidecar (IMPLEMENTED 2026-08-14) | ConfBridge 2-user live call + voicemail + screening accept-leg all verified; configs/asterisk + compose service + Kamailio :5061 trunk |
| D8 | Test harnesses MUST bind their UDP socket and keep Via == source port under rootless passt | Not-Issue N-3; unbound sockets silently dropped |

See `docs/ISSUES.md` issues 8.51–8.62 + Not-Issues N-3/N-4 for the full RCA of
each fix, and `docs/INTEGRATION_CONTRACT.md` for the org boundaries this
affects (SipClient `+`-prefixed From, sms-client `:2076`/Neon).
