#!/usr/bin/env python3
"""
inject_smsc_row.py — deterministic SMSC store-and-forward row injector (Goal 7 e2e)

Inserts a clean pending SMS row directly into OsmoSMSC's SQLite database
(state/hlr/smsc.db, the SAME file the IP-SM-GW bridge polls). This is the reliable
way to drive a 2G->5G (or AI-block) flow in e2e: unlike the retired
send_vty_sms.sh (VTY unpublished, container lacks nc/socat) and send_db_sms.sh
(invented schema writing to the wrong DB), it writes to the
bridge's actual SMS table with clean text and deliver_attempts=0.

Usage:
  python3 scripts/testing/inject_smsc_row.py [src] [dest] [text]
"""
import sqlite3
import sys

DB = "state/hlr/smsc.db"


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "15554443322"
    dest = sys.argv[2] if len(sys.argv) > 2 else "15551234567"
    text = sys.argv[3] if len(sys.argv) > 3 else "E2E deterministic row"

    con = sqlite3.connect(DB, timeout=15)
    con.execute("PRAGMA busy_timeout=8000")
    cur = con.execute(
        """
        INSERT INTO SMS (
            created, deliver_attempts, reply_path_req, status_rep_req,
            is_report, msg_ref, protocol_id, data_coding_scheme, ud_hdr_ind,
            src_addr, src_ton, src_npi, dest_addr, dest_ton, dest_npi, text
        ) VALUES (
            datetime('now'), 0, 1, 0,
            0, 1, 0, 0, 0,
            ?, 1, 1, ?, 1, 1, ?
        )
        """,
        (src, dest, text),
    )
    con.commit()
    rowid = cur.lastrowid
    print(f"injected SMS row id={rowid} {src}->{dest} text='{text}'")
    con.close()


if __name__ == "__main__":
    main()
