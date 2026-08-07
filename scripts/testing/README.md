# MVNO Telecom Core — Manual Testing & SMS Injection Suite

This directory contains standalone, executable manual CLI scripts for testing all active telecom protocols, SMS injection methods, and live microphone speech transcription in the MVNO network.

---

## 🛠️ Suite of Manual Testing Scripts

| Script File | Target Protocol / Component | Description | Example Usage |
| :--- | :--- | :--- | :--- |
| [record_mic_call.sh](scripts/testing/record_mic_call.sh) | **Laptop Microphone ➔ Vosk ASR** | Records live audio from laptop mic and transcribes it via Vosk ASR. | `./record_mic_call.sh 5` |
| [send_rest_sms.sh](scripts/testing/send_rest_sms.sh) | Gateway REST API (`HTTP 8080`) | Evaluates balance, EIR, and AI Spam Filter policies. | `./send_rest_sms.sh 15551234567 15557654321 "Clean SMS"` |
| [send_smpp_sms.py](scripts/testing/send_smpp_sms.py) | Binary SMPP 3.4 (`TCP 2775`) | Binds as ESME transceiver and submits binary `SUBMIT_SM` PDU. | `python3 send_smpp_sms.py --sender 15551234567 --recipient 15557654321` |
| [inject_smsc_row.py](scripts/testing/inject_smsc_row.py) | OsmoSMSC SQLite queue | Inserts an SMS row directly into the SMSC store-and-forward queue (replaces the retired direct-DB injection path). | `python3 inject_smsc_row.py 15551234567 15557654321 "DB SMS"` |
| [sip_traffic_sim.py](scripts/testing/sip_traffic_sim.py) | RFC 3261 IMS SIP (`UDP 5066/5060`) | Simulates SIP REGISTER + 407 Digest Auth + INVITE dialog. | `python3 sip_traffic_sim.py` |
| [live_tap.sh](scripts/testing/live_tap.sh) | RTPEngine pcap → WAV (G.711 PCMU) | Zero-Python audio extractor: `--once` post-call extraction (Tier-3 fallback) or `daemon` mode chunking the live pcap mid-call (Tier-1). Feeds `NativeVoskService` via `state/spool/`. | `bash live_tap.sh --once <pcap>` / `bash live_tap.sh daemon` |
| [demo_runbook.sh](scripts/testing/demo_runbook.sh) | End-to-End Master Runbook | Executes complete 13-step graduation project validation suite. | `bash demo_runbook.sh` |
| [e2e_runbook.sh](scripts/testing/e2e_runbook.sh) | SMS Interworking E2E Runbook | Goal-7 multi-cell 2G↔5G SMS interworking + AI-block verification. | `bash e2e_runbook.sh` |
