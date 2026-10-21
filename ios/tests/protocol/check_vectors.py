"""Independent recomputation of the MiProtocol test vectors (stdlib + cryptography)."""
import hashlib, hmac, json, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

got = json.load(sys.stdin)
key, phone, watch, ccm_nonce = bytes(range(16)), bytes(range(16, 32)), bytes(range(32, 48)), bytes(range(48, 60))

def varint(v):
    out = b""
    while v >= 0x80:
        out += bytes([v & 0x7F | 0x80]); v >>= 7
    return out + bytes([v])
def f_varint(n, v): return varint(n << 3) + varint(v)
def f_bytes(n, b): return varint(n << 3 | 2) + varint(len(b)) + b

# Gadgetbridge computeAuthStep3Hmac, written as its loop (not via an HKDF library)
prk = hmac.new(phone + watch, key, hashlib.sha256).digest()
okm, t, i = b"", b"", 1
while len(okm) < 64:
    t = hmac.new(prk, t + b"miwear-auth" + bytes([i]), hashlib.sha256).digest(); okm += t; i += 1
okm = okm[:64]
dec_key, enc_key, enc_nonce = okm[:16], okm[16:32], okm[36:40]

companion = f_varint(1, 1) + f_bytes(3, b"BandProbe") + f_varint(4, 0xFFFFFFFF)
confirm = f_bytes(1, hmac.new(enc_key, phone + watch, hashlib.sha256).digest()) \
        + f_bytes(2, AESCCM(enc_key, tag_length=4).encrypt(enc_nonce + bytes(8), companion, None))
confirm_cmd = f_varint(1, 1) + f_varint(2, 27) + f_bytes(3, f_bytes(32, confirm))

def f_sint(n, v): return f_varint(n, ((v << 1) ^ (v >> 63)) & ((1 << 64) - 1))

def clock(ts, tzname, h24):
    from datetime import datetime, timezone
    from zoneinfo import ZoneInfo
    d = datetime.fromtimestamp(ts, ZoneInfo(tzname))
    dst = int(d.dst().total_seconds()); std = int(d.utcoffset().total_seconds()) - dst
    date = f_varint(1, d.year) + f_varint(2, d.month) + f_varint(3, d.day)
    time = f_varint(1, d.hour) + f_varint(2, d.minute) + f_varint(3, d.second) + f_varint(4, d.microsecond // 1000)
    zone = f_sint(1, std // 900) + f_sint(2, dst // 900) + f_bytes(3, tzname.encode())
    clk = f_bytes(1, date) + f_bytes(2, time) + f_bytes(3, zone) + f_varint(4, 0 if h24 else 1)
    return (f_varint(1, 2) + f_varint(2, 3) + f_bytes(4, f_bytes(4, clk))).hex()

def crc16arc(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc
def frame(kind, seq, payload):
    return bytes([0xA5, 0xA5, kind, seq]) + len(payload).to_bytes(2, "little") + crc16arc(payload).to_bytes(2, "little") + payload

ctr_in = bytes((i * 7) & 0xFF for i in range(40))
enc = Cipher(algorithms.AES(key), modes.CTR(key)).encryptor()
start = bytes([1, 1, 3, 0, 1, 0, 0, 2, 2, 0, 0, 0xFC, 3, 2, 0, 0x20, 0, 4, 2, 0, 0x10, 0x27])

want = {
    "crc_123456789": "bb3d",
    "okm": okm.hex(),
    "ccm_short": AESCCM(key, tag_length=4).encrypt(ccm_nonce, b"hello", None).hex(),
    "ccm_long": AESCCM(key, tag_length=4).encrypt(ccm_nonce, b"BandProbe companion device test vector!", None).hex(),
    "ctr": (enc.update(ctr_in) + enc.finalize()).hex(),
    "nonce_cmd": (f_varint(1, 1) + f_varint(2, 26) + f_bytes(3, f_bytes(30, f_bytes(1, phone)))).hex(),
    "confirm_cmd": confirm_cmd.hex(),
    "wrong_key_rejected": True,
    "session_frame": frame(2, 0, start).hex(),
    "drained": ["3:7:0102aa", "1:9:"],
    "leftover": "a5a503",
    "battery_parsed": 87,
    "battery_cmd": (f_varint(1, 2) + f_varint(2, 1)).hex(),
    "realtime_start": (f_varint(1, 8) + f_varint(2, 45)).hex(),
    "realtime_stop": (f_varint(1, 8) + f_varint(2, 46)).hex(),
    "live_parsed": "8421/312/74/9",
    # Gadgetbridge setCurrentTime: local date/time, sint32 (zigzag) 15-min offsets, name, isNot24hour
    "clock_istanbul": clock(1760000000, "Europe/Istanbul", True),
    "clock_newyork_12h": clock(1760000000, "America/New_York", False),
    # docs/ACTIVITY.md section 2.2
    "activity_today": "0808100152042a020800",
    "activity_past": "08081002",
    "activity_fetch": "080810035209120700f15365040001",
    "notify_cmd": (f_varint(1, 7) + f_varint(2, 0) + f_bytes(9, f_bytes(3, f_bytes(1,
        f_bytes(1, b"dev.cobanov.freeband") + f_bytes(2, b"Freeband") + f_bytes(3, "Başlık".encode()) + f_bytes(4, b"")
        + f_bytes(5, b"Merhaba") + f_bytes(6, __import__("datetime").datetime.fromtimestamp(1760000000, __import__("datetime").timezone.utc).strftime("%Y%m%dT%H%M%S").encode())
        + f_varint(7, 42))))).hex(),
    "find_start": (f_varint(1, 2) + f_varint(2, 18) + f_bytes(4, f_varint(5, 0))).hex(),
    "find_stop": (f_varint(1, 2) + f_varint(2, 18) + f_bytes(4, f_varint(5, 1))).hex(),
    # (next, nack): resend nack..next-1 mod 256 when 0 < next-nack <= 32 (the TX window)
    "resend_seqs": [[(nack + i) % 256 for i in range((next - nack) % 256)] if 0 < (next - nack) % 256 <= 32 else []
                    for next, nack in [(10, 10), (10, 7), (3, 250), (40, 8), (40, 7), (10, 11)]],
}
bad = [k for k in want if got.get(k) != want[k]]
for k in want:
    print(("OK  " if k not in bad else "FAIL"), k)
sys.exit(1 if bad else 0)
