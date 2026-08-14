#!/usr/bin/env python3
"""
Unit tests for the ip-sm-gw 2G<->5G SMS interworking bridge
(scripts/ip_sm_gw.py). Stdlib `unittest` only — no pytest, no third-party deps,
so it runs unchanged in the repo's python:3.11-alpine container.

Coverage (all pure-logic, no sockets/server started):
  * gsm7_decode / gsm7_encode — GSM 03.38 7-bit packing:
      - known-answer (C8 32 9B FD 06 <-> "Hello")
      - "you have won a prize" round-trip
      - extended-table (0x1B escape) chars do NOT emit garbage
      - 160-char max-length message (septet boundary crossing)
      - empty / single septet
      - invalid / oversized input -> no exception
  * smpp_submit_sm — SMPP 3.4 PDU framing WITHOUT a live SMSC (socket is
    monkeypatched to capture the bound bytes and feed scripted responses):
      - bind PDU header struct.unpack(">IIII", ...) -> cmd_len=16+body, cmd_id,
        seq
      - submit_sm PDU -> command_id 0x00000004, status 0, seq increments
      - the GSM-7 user_data pack inside matches the reference packer
      - fragmented/partial recv feeds (3-byte chunks) reassemble without a
        traceback (the fragile recv() framing risk)
  * digest_response — RFC 2617 digest response hash (known-answer against the
    bridge's no-qop MD5 form) + replay-protection sanity (different nonce ->
    different response)
  * parse_nonce / parse_sip_message — known 407/100/200/401/INVITE/MESSAGE
    blobs; malformed input returns None/defaults, never crashes
"""

import struct
import sys
import unittest
from unittest import mock

# Import target module defensively: its module-level code only sets constants
# and never binds sockets (the server runs under `if __name__ == "__main__":`).
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import ip_sm_gw as gw


# --------------------------------------------------------------------------- #
# Independent GSM 03.38 reference packer (used to cross-check the wire bytes)
# --------------------------------------------------------------------------- #
class RefPacker:
    """A from-scratch GSM 03.38 7-bit LSB-first packer, independent of
    ip_sm_gw.gsm7_encode, used to assert the SMPP user_data is correct on the
    wire."""

    @staticmethod
    def char_to_septet(text):
        index = {c: i for i, c in enumerate(gw._GSM7_ALPHABET)}
        ext = {c: i for i, c in gw._GSM7_EXT.items()}
        septets = []
        for ch in text:
            if ch in index:
                septets.append(index[ch])
            elif ch in ext:
                septets.append(0x1B)
                septets.append(ext[ch])
            else:
                septets.append(index["?"])
        return septets

    @staticmethod
    def pack(septets):
        out = bytearray()
        val = 0
        bits = 0
        for s in septets:
            val |= s << bits
            bits += 7
            while bits >= 8:
                out.append(val & 0xFF)
                val >>= 8
                bits -= 8
        if bits > 0:
            out.append(val & 0xFF)
        return bytes(out)

    @classmethod
    def encode(cls, text):
        return cls.pack(cls.char_to_septet(text))


# --------------------------------------------------------------------------- #
# gsm7_decode / gsm7_encode
# --------------------------------------------------------------------------- #
class Gsm7DecodeTest(unittest.TestCase):
    def test_known_answer_hello(self):
        # The classic GSM 03.38 known-answer: C8 32 9B FD 06 unpacks to "Hello".
        self.assertEqual(gw.gsm7_decode(bytes.fromhex("C8329BFD06")), "Hello")
        # And it encodes back to exactly the same octets.
        self.assertEqual(gw.gsm7_encode("Hello").hex().upper(), "C8329BFD06")

    def test_known_answer_hello_upper(self):
        # 5 uppercase septets -> the well-known C8 22 93 F9 04 packing.
        self.assertEqual(gw.gsm7_encode("HELLO").hex().upper(), "C82293F904")
        self.assertEqual(gw.gsm7_decode(bytes.fromhex("C82293F904")), "HELLO")

    def test_phrase_roundtrip(self):
        phrase = "you have won a prize"
        packed = gw.gsm7_encode(phrase)
        self.assertEqual(gw.gsm7_decode(packed), phrase)

    def test_extended_table_chars_do_not_emit_garbage(self):
        # Each GSM 03.38 extended-table char is 0x1B-escaped. Decode must
        # reproduce the char, never a garbage/raw escape residue.
        for ch in "[", "]", "{", "}", "\\", "|", "~", "^", "\u20ac":
            packed = gw.gsm7_encode(ch)
            self.assertEqual(
                gw.gsm7_decode(packed),
                ch,
                msg=f"extended char {ch!r} did not survive the 0x1B escape",
            )
            self.assertNotIn("\uffff", gw.gsm7_decode(packed))
        phrase = 'you [have] won {100} ~prize~ |ok| ^]\\'
        self.assertEqual(gw.gsm7_decode(gw.gsm7_encode(phrase)), phrase)

    def test_crossing_septet_boundary(self):
        # A char whose 0x1B escape splits across two octets must reassemble
        # (e.g. '}' packs as 9B14, the escape byte straddles a byte boundary).
        value = "\u007d"  # '}'
        self.assertEqual(gw.gsm7_decode(gw.gsm7_encode(value)), value)

    def test_160_char_max_length(self):
        # Max GSM-7 message length (160 septets); exercises the longest packed
        # pattern and the trailing-septet handling.
        msg = ("The quick brown fox jumps over the lazy dog " * 9)[:160]
        self.assertEqual(len(msg), 160)
        packed = gw.gsm7_encode(msg)
        self.assertEqual(len(packed), 140)  # 160*7/8 == 140 octets exactly
        self.assertEqual(gw.gsm7_decode(packed), msg)

    def test_empty_and_single_septet(self):
        self.assertEqual(gw.gsm7_decode(b""), "")
        self.assertEqual(gw.gsm7_encode(""), b"")
        self.assertEqual(gw.gsm7_decode(gw.gsm7_encode("H")), "H")

    def test_lengths_roundtrip(self):
        # Every message length 1..160 (none, including the tricky exact-fill
        # 160 and the ≡7 mod 8 padding boundaries) must round-trip exactly when
        # the true septet count is passed.
        base = "The quick brown fox jumps over the lazy dog 0123456789 " * 4
        for n in range(1, 161):
            phrase = base[:n]
            packed = gw.gsm7_encode(phrase)
            self.assertEqual(
                gw.gsm7_decode(packed, n_septets=n),
                phrase,
                msg=f"length {n} did not round-trip",
            )

    def test_oversized_input_no_exception(self):
        # Arbitrary / oversized octet blobs must never raise.
        blobs = [
            bytes([0x1B]),                  # dangling escape
            bytes([0x1B, 0x3C]),            # escape + valid ext index
            bytes(range(256)),              # all octet values
            bytes([0xFF]) * 300,            # oversized nonsense
            b"\x00\x00\x00\x00",            # all-NUL
            b"\x1b" * 5,                    # repeated escapes
        ]
        for blob in blobs:
            with self.subTest(blob=b"len:%d" % len(blob)):
                gw.gsm7_decode(blob)  # must not raise


# --------------------------------------------------------------------------- #
# smpp_submit_sm — PDU framing (socket monkeypatched, no live SMSC)
# --------------------------------------------------------------------------- #
class FakeSMPPSocket:
    """A stream socket whose recv() returns at most CHUNK bytes at a time from
    an underlying byte stream — simulating an arbitrarily fragmented TCP
    read. sendall() captures every PDU byte. Optionally drops the socket close
    so the test can inspect what was sent."""

    CHUNK = 3  # force heavy fragmentation

    def __init__(self, af, sockt, response_stream=b"", fail_open=False):
        self._af = af
        self._sockt = sockt
        self._buf = bytearray(response_stream)
        self.sent = []
        self.connect_called = None
        self.timeout = None
        self.closed = False
        self.fail_open = fail_open

    def settimeout(self, t):
        self.timeout = t

    def connect(self, addr):
        self.connect_called = addr

    def sendall(self, data):
        self.sent.append(data)

    def close(self):
        self.closed = True

    def recv(self, n):
        if self.fail_open or not self._buf:
            return b""
        take = min(n, self.CHUNK)
        chunk = bytes(self._buf[:take])
        del self._buf[:take]
        return chunk


def _bind_resp():
    return struct.pack(">IIII", 16, 0x80000009, 0, 1)  # bind_transceiver_resp


def _submit_resp():
    return struct.pack(">IIII", 16, 0x80000004, 0, 2)  # submit_sm_resp


class SmppSubmitSmTest(unittest.TestCase):
    def setUp(self):
        self.sock = None
        self._orig_socket = gw.socket.socket

        def fake_socket(af, sockt):
            s = FakeSMPPSocket(af, sockt, _bind_resp() + _submit_resp())
            self.sock = s
            return s

        gw.socket.socket = fake_socket

    def tearDown(self):
        gw.socket.socket = self._orig_socket

    def test_bind_and_submit_header_framing(self):
        gw.smpp_submit_sm("10.0.0.1", 2775, "15554443322",
                          "15551234567", "Hello 5G")
        self.assertIsNotNone(self.sock)
        self.assertEqual(self.sock.connect_called, ("10.0.0.1", 2775))
        self.assertEqual(len(self.sock.sent), 2)  # bind PDU, then submit PDU

        bind_pdu = self.sock.sent[0]
        submit_pdu = self.sock.sent[1]

        # Header is command_length/command_id/command_status/sequence_number.
        bind_cmd_len, bind_cmd_id, bind_status, bind_seq = struct.unpack(
            ">IIII", bind_pdu[:16])
        # command_length == 16 + len(body)
        self.assertEqual(bind_cmd_len, 16 + (len(bind_pdu) - 16))
        self.assertEqual(bind_cmd_id, 0x00000009)  # bind_transceiver
        self.assertEqual(bind_status, 0)
        self.assertEqual(bind_seq, 1)

        sub_cmd_len, sub_cmd_id, sub_status, sub_seq = struct.unpack(
            ">IIII", submit_pdu[:16])
        self.assertEqual(sub_cmd_len, 16 + (len(submit_pdu) - 16))
        self.assertEqual(sub_cmd_id, 0x00000004)  # submit_sm
        self.assertEqual(sub_status, 0)
        self.assertEqual(sub_seq, 2)  # sequence number increments

    def test_submit_sm_payload_is_unpacked_ascii(self):
        # Verified 2026-08-14 (smpp_ab_test.py + live e2e): OsmoSMSC expects
        # UNPACKED 7-bit chars with data_coding=0 (one octet per septet,
        # sm_length = char count). Pre-packed GSM-7 bytes were double-encoded
        # and the 2G MS displayed raw packed garbage. The wire short_message
        # is therefore `message.encode("ascii")`, NOT gsm7_encode(message).
        sender = "15554443322"
        recipient = "15551234567"
        message = "you have won a prize"
        gw.smpp_submit_sm("10.0.0.1", 2775, sender, recipient, message)
        submit_pdu = self.sock.sent[1]
        body = submit_pdu[16:]  # after the 16-byte header

        def parse_string_at(body_blob, pos):
            end = body_blob.index(b"\x00", pos)
            return body_blob[pos:end].decode("ascii"), end + 1

        pos = 0
        pos += 1                                   # service_type
        pos += 2                                   # source_addr_ton/npi
        src, pos = parse_string_at(body, pos)
        pos += 2                                   # dest_addr_ton/npi
        dst, pos = parse_string_at(body, pos)
        pos += 3                                   # esm_class/protocol_id/prio
        pos += 1                                   # schedule_delivery_time
        pos += 1                                   # validity_period
        pos += 4                                   # reg_delivery/replace/dcs/msg_id
        sm_length = body[pos]
        pos += 1
        user_data = body[pos:pos + sm_length]

        self.assertEqual(src, sender)
        self.assertEqual(dst, recipient)
        # sm_length == unpacked char count (ASCII octets, data_coding=0).
        expected = message.encode("ascii")
        self.assertEqual(sm_length, len(expected))
        self.assertEqual(user_data, expected)
        # The payload is NOT the pre-packed GSM-7 octets.
        self.assertNotEqual(user_data, RefPacker.encode(message))

    def test_fragmented_recv_reassembles(self):
        # The fragile framing risk: if recv() returns a PDU header in 3-byte
        # fragments, _recv_exact must reassemble the 16-byte header without a
        # struct.error traceback. The fake socket above feeds 3-byte chunks by
        # default.
        gw.smpp_submit_sm("10.0.0.1", 2775, "15554443322",
                          "15551234567", "regression ok")
        # Reaching this line means both bind and submit PDUs were parsed.
        # FakeSMPPSocket has no `.connected`; assert on the real attributes it
        # exposes to prove the socket connected to the SMPP server:port and a
        # 5 s timeout was set (was AttributeError before).
        self.assertEqual(self.sock.connect_called, ("10.0.0.1", 2775))
        self.assertEqual(self.sock.timeout, 5)

    def test_bind_failure_raises(self):
        sock = FakeSMPPSocket(0, 0,
                              struct.pack(">IIII", 16, 0x80000009, 0x1, 1))
        gw.socket.socket = lambda af, t: sock
        with self.assertRaises(RuntimeError):
            gw.smpp_submit_sm("x", 1, "a", "b", "c")

    def test_submit_failure_raises(self):
        sock = FakeSMPPSocket(0, 0,
                              _bind_resp() +
                              struct.pack(">IIII", 16, 0x80000004, 0x1, 2))
        gw.socket.socket = lambda af, t: sock
        with self.assertRaises(RuntimeError):
            gw.smpp_submit_sm("x", 1, "a", "b", "c")


# --------------------------------------------------------------------------- #
# digest_response — RFC 2617
# --------------------------------------------------------------------------- #
class DigestResponseTest(unittest.TestCase):
    # RFC 2617 §3.5 example credentials.
    USER = "Mufasa"
    REALM = "testrealm@host.com"
    PASSWORD = "Circle Of Life"
    NONCE = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
    # The bridge computes the no-qop MD5(HA1:nonce:HA2) form. Independent
    # recomputation gives this exact known answer:
    #   HA1 = MD5("Mufasa:testrealm@host.com:Circle Of Life")
    #   HA2 = MD5("GET:/dir/index.html")
    #   resp = MD5(HA1:nonce:HA2) = 670fd8c2df070c60b045671b8b24ff02
    KNOWN_ANSWER = "670fd8c2df070c60b045671b8b24ff02"

    def test_rfc2617_digest_response_hash(self):
        self.assertEqual(
            gw.digest_response(
                self.USER, self.REALM, self.PASSWORD,
                "GET", "/dir/index.html", self.NONCE),
            self.KNOWN_ANSWER,
        )

    def test_different_nonce_different_response(self):
        # Replay protection sanity: a new nonce must yield a different digest,
        # otherwise a captured response could be replayed.
        r1 = gw.digest_response(self.USER, self.REALM, self.PASSWORD,
                                "GET", "/dir/index.html", self.NONCE)
        r2 = gw.digest_response(self.USER, self.REALM, self.PASSWORD,
                                "GET", "/dir/index.html", "0" * 32)
        self.assertNotEqual(r1, r2)

    def test_method_and_uri_affect_response(self):
        r1 = gw.digest_response(self.USER, self.REALM, self.PASSWORD,
                                "REGISTER", "sip:15554443322@10.89.0.23",
                                self.NONCE)
        r2 = gw.digest_response(self.USER, self.REALM, self.PASSWORD,
                                "MESSAGE", "sip:15554443322@10.89.0.23",
                                self.NONCE)
        self.assertNotEqual(r1, r2)


# --------------------------------------------------------------------------- #
# parse_nonce / parse_sip_message
# --------------------------------------------------------------------------- #
CHALLENGE_401 = (
    "SIP/2.0 401 Unauthorized\r\n"
    "Via: SIP/2.0/UDP 10.89.0.23:5060;branch=z9hG4bK71c4\r\n"
    "From: <sip:15554443322@10.89.0.23>;tag=abc\r\n"
    "To: <sip:15554443322@10.89.0.23>;tag=xyz\r\n"
    "Call-ID: deadbeef\r\n"
    "CSeq: 1 REGISTER\r\n"
    'WWW-Authenticate: Digest realm="localhost", nonce="a1b2c3d4e5f6", '
    "algorithm=MD5\r\n"
    "Content-Length: 0\r\n"
    "\r\n"
)

CHALLENGE_407 = CHALLENGE_401.replace("401 Unauthorized", "407 Proxy Authentication Required") \
                             .replace("WWW-Authenticate", "Proxy-Authenticate")

MESSAGE_REQ = (
    "MESSAGE sip:15551234567@10.89.0.23 SIP/2.0\r\n"
    "Via: SIP/2.0/UDP 10.89.0.23:5060;branch=z9hG4bK2\r\n"
    "From: <sip:15554443322@10.89.0.23>;tag=b\r\n"
    "To: <sip:15551234567@10.89.0.23>\r\n"
    "CSeq: 2 MESSAGE\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 23\r\n"
    "\r\n"
    "Hello 5G from the 2G core"
)

INVITE_REQ = (
    "INVITE sip:15551234567@10.89.0.23 SIP/2.0\r\n"
    "Via: SIP/2.0/UDP 10.89.0.23:5060;branch=z9hG4bK1\r\n"
    "From: <sip:15554443322@10.89.0.23>;tag=a\r\n"
    "To: <sip:15551234567@10.89.0.23>\r\n"
    "Call-ID: c1@host\r\n"
    "CSeq: 1 INVITE\r\n"
    "Content-Length: 0\r\n"
    "\r\n"
)


class ParseNonceTest(unittest.TestCase):
    def test_nonce_from_407_proxy_authenticate(self):
        self.assertEqual(
            gw.parse_nonce(CHALLENGE_407, "Proxy-Authenticate"),
            "a1b2c3d4e5f6",
        )

    def test_nonce_from_401_www_authenticate(self):
        self.assertEqual(
            gw.parse_nonce(CHALLENGE_401, "WWW-Authenticate"),
            "a1b2c3d4e5f6",
        )

    def test_nonce_header_name_must_match(self):
        # A WWW-Authenticate nonce is not found when asking for the
        # Proxy-Authenticate header.
        self.assertIsNone(gw.parse_nonce(CHALLENGE_401, "Proxy-Authenticate"))

    def test_100_trying_and_200_ok_have_no_nonce(self):
        self.assertIsNone(gw.parse_nonce("SIP/2.0 100 Trying\r\n\r\n",
                                         "WWW-Authenticate"))
        self.assertIsNone(gw.parse_nonce("SIP/2.0 200 OK\r\n\r\n",
                                         "WWW-Authenticate"))

    def test_malformed_returns_none(self):
        for bad in (None, "", "   ", b"bytes", "GARBAGE no headers", 123):
            with self.subTest(bad=bad):
                self.assertIsNone(gw.parse_nonce(bad, "WWW-Authenticate"))


class ParseSipMessageTest(unittest.TestCase):
    def test_message_from_to_and_body(self):
        sender, recipient, body = gw.parse_sip_message(MESSAGE_REQ)
        self.assertEqual(sender, "15554443322")
        self.assertEqual(recipient, "15551234567")
        self.assertEqual(body, "Hello 5G from the 2G core")

    def test_invite_from_to_empty_body(self):
        sender, recipient, body = gw.parse_sip_message(INVITE_REQ)
        self.assertEqual(sender, "15554443322")
        self.assertEqual(recipient, "15551234567")
        self.assertEqual(body, "")

    def test_malformed_returns_defaults(self):
        for bad in (None, "", "   ", b"bytes", "GARBAGE no headers"):
            with self.subTest(bad=bad):
                self.assertEqual(gw.parse_sip_message(bad),
                                 (None, None, ""))

    def test_linphone_bracketless_to_and_from(self):
        # Android Linphone sends `To: sip:15554443322@localhost` WITHOUT the
        # angle brackets (RFC 3261 permits both forms). Regression for the
        # silent-drop: the old `To:\s*<sip:` regex returned recipient=None and
        # the 5G->2G relay never fired (observed live 2026-08-14, e2e Cell 3).
        linphone_msg = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 192.168.100.33:37322;branch=z9hG4bK.1;rport\r\n"
            "From: <sip:15551234567@192.168.100.93>;tag=TisjRObY9\r\n"
            "To: sip:15554443322@localhost\r\n"
            "CSeq: 21 MESSAGE\r\n"
            "Call-ID: yOPA0YONrX\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: 11\r\n"
            "\r\n"
            "PHONE2UE0710"
        )
        sender, recipient, body = gw.parse_sip_message(linphone_msg)
        self.assertEqual(sender, "15551234567")
        self.assertEqual(recipient, "15554443322")
        self.assertEqual(body, "PHONE2UE0710")

    def test_is_typing_indicator_detects_linphone_iscomposing(self):
        # Linphone's RFC 3994 typing notification (XML body, iscomposing
        # content type) must be recognized so it is NOT relayed as an SMS.
        composing = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 192.168.100.33:37322;branch=z9hG4bK.3\r\n"
            "From: <sip:15551234567@192.168.100.93>;tag=z\r\n"
            "To: sip:15554443322@localhost\r\n"
            "CSeq: 21 MESSAGE\r\n"
            "Content-Type: application/im-iscomposing+xml\r\n"
            "Content-Length: 207\r\n"
            "\r\n"
            '<?xml version="1.0"?><isComposing><state>active</state></isComposing>'
        )
        self.assertTrue(gw.is_typing_indicator(composing))

    def test_is_typing_indicator_false_for_plain_sms(self):
        self.assertFalse(gw.is_typing_indicator(MESSAGE_REQ))
        self.assertFalse(gw.is_typing_indicator(INVITE_REQ))
        self.assertFalse(gw.is_typing_indicator(None))
        self.assertFalse(gw.is_typing_indicator(b"bytes"))
        self.assertFalse(gw.is_typing_indicator(""))

    def test_linphone_bracketless_from_too(self):
        # Both headers bare (no <>): must still parse.
        msg = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 192.168.100.33:37322;branch=z9hG4bK.2\r\n"
            "From: sip:15551234567@192.168.100.93;tag=x\r\n"
            "To: sip:15554443322@localhost\r\n"
            "CSeq: 1 MESSAGE\r\n"
            "Content-Length: 4\r\n"
            "\r\n"
            "TEST"
        )
        sender, recipient, body = gw.parse_sip_message(msg)
        self.assertEqual(sender, "15551234567")
        self.assertEqual(recipient, "15554443322")
        self.assertEqual(body, "TEST")

    def test_mizudroid_lowercase_headers_and_bare_lf(self):
        # Mizudroid / embedded stacks emit lowercase header names and bare-LF
        # line endings (no CRLF). Both must still parse; the body split must
        # survive the normalized line endings.
        msg = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\n"
            "via: SIP/2.0/UDP 192.168.100.55:40000;branch=z9hG4bK.m1\n"
            "from: <sip:15551234567@192.168.100.93>;tag=mt\n"
            "to: <sip:15554443322@localhost>\n"
            "cseq: 7 MESSAGE\n"
            "content-type: text/plain\n"
            "content-length: 9\n"
            "\n"
            "MIZU0710"
        )
        sender, recipient, body = gw.parse_sip_message(msg)
        self.assertEqual(sender, "15551234567")
        self.assertEqual(recipient, "15554443322")
        self.assertEqual(body, "MIZU0710")

    def test_display_name_plus_prefix_and_tel_uri(self):
        # Java SIP client (SipClient) style: display name with digits, a
        # +-prefixed international number, and a tel: URI. The display-name
        # digits must never be mistaken for the MSISDN.
        msg = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 192.168.100.99:55555;branch=z9hG4bK.j1\r\n"
            'From: "Agent 007" <sip:+15551234567@192.168.100.93>;tag=jt\r\n'
            "To: <tel:+15554443322>\r\n"
            "CSeq: 3 MESSAGE\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: 10\r\n"
            "\r\n"
            "JAVACLIENT"
        )
        sender, recipient, body = gw.parse_sip_message(msg)
        self.assertEqual(sender, "15551234567")
        self.assertEqual(recipient, "15554443322")
        self.assertEqual(body, "JAVACLIENT")

    def test_display_name_without_angle_brackets(self):
        # SipClient-style display name, bare URI (no <>), + prefix.
        msg = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 192.168.100.99:55556;branch=z9hG4bK.j2\r\n"
            'From: "Team Member" <sip:+15551234567@10.89.0.23>;tag=jt2\r\n'
            "To: sip:15554443322@10.89.0.23\r\n"
            "CSeq: 4 MESSAGE\r\n"
            "Content-Length: 5\r\n"
            "\r\n"
            "TEAM1"
        )
        sender, recipient, body = gw.parse_sip_message(msg)
        self.assertEqual(sender, "15551234567")
        self.assertEqual(recipient, "15554443322")
        self.assertEqual(body, "TEAM1")

    def test_typing_indicator_case_insensitive_content_type(self):
        # Some clients lowercase the Content-Type header name too.
        composing = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\n"
            "from: <sip:15551234567@192.168.100.93>;tag=z\n"
            "to: <sip:15554443322@localhost>\n"
            "content-type: application/im-iscomposing+xml\n"
            "content-length: 200\n"
            "\n"
            '<?xml version="1.0"?><isComposing><state>active</state></isComposing>'
        )
        self.assertTrue(gw.is_typing_indicator(composing))

    def test_reply_ok_carries_headers_for_bare_lf_request(self):
        # Regression (2026-08-14, cross-client): reply_ok() used to split on
        # "\r\n" ONLY — a bare-LF (MizuDroid/embedded) request collapsed into
        # ONE line, so the 200 OK had NO Via/From/Call-ID headers. Kamailio's
        # tm could not match the transaction and retransmitted the MESSAGE
        # forever; the SMS WAS delivered but the sender never saw the final
        # 200. The reply must now carry the transaction headers regardless of
        # the request's line endings.
        bare_lf = (
            "MESSAGE sip:15554443322@localhost SIP/2.0\n"
            "via: SIP/2.0/UDP 127.0.0.1:5090;branch=z9hG4bK-mz1\n"
            "from: sip:15551234567@localhost;tag=mztag1\n"
            "to: sip:15554443322@localhost\n"
            "call-id: mizu-0814-1@127.0.0.1\n"
            "cseq: 1 MESSAGE\n"
            "max-forwards: 70\n"
            "content-type: text/plain\n"
            "content-length: 12\n"
            "\n"
            "XC-MIZU-0814"
        )
        sent = {}

        class FakeSock:
            def sendto(self, data, addr):
                sent["data"] = data.decode(errors="ignore")

        gw.reply_ok(bare_lf, FakeSock(), "127.0.0.1", 5060)
        reply = sent.get("data", "")
        self.assertIn("SIP/2.0 200 OK", reply)
        self.assertIn("Via: SIP/2.0/UDP 127.0.0.1:5090;branch=z9hG4bK-mz1", reply)
        self.assertIn("From: sip:15551234567@localhost;tag=mztag1", reply)
        self.assertIn("To: sip:15554443322@localhost", reply)
        self.assertIn("Call-ID: mizu-0814-1@127.0.0.1", reply)
        self.assertIn("CSeq: 1 MESSAGE", reply)

    def test_reply_ok_carries_headers_for_crlf_request(self):
        # CRLF requests must still produce a well-formed 200 OK (no regression).
        sent = {}

        class FakeSock:
            def sendto(self, data, addr):
                sent["data"] = data.decode(errors="ignore")

        gw.reply_ok(MESSAGE_REQ, FakeSock(), "127.0.0.1", 5060)
        reply = sent.get("data", "")
        self.assertIn("SIP/2.0 200 OK", reply)
        self.assertIn("Via: SIP/2.0/UDP 10.89.0.23:5060;branch=z9hG4bK2", reply)
        self.assertIn("From: <sip:15554443322@10.89.0.23>;tag=b", reply)
        self.assertIn("To: <sip:15551234567@10.89.0.23>", reply)
        self.assertIn("CSeq: 2 MESSAGE", reply)


if __name__ == "__main__":
    unittest.main(verbosity=2)