"""Independent recomputation of the MiProtocol test vectors (stdlib + cryptography)."""
import struct
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

# SleepResult.Section: timezone 1{offset 1, zigzag}, valid_sleep_time 2 (seconds), sleep_timestamp 3,
# wakeup_timestamp 4, average_heart_rate 5, average_blood_oxygen 6, extra_data 7 (five varints, optional)
def sleep_section(tz, seconds, bed, wake, hr, spo2, extra=None):
    s = f_bytes(1, f_sint(1, tz)) + f_varint(2, seconds) + f_varint(3, bed) + f_varint(4, wake) + f_varint(5, hr) + f_varint(6, spo2)
    if extra: s += f_bytes(7, b"".join(f_varint(n + 1, v) for n, v in enumerate(extra)))
    return s

def sleep_result(*sections):
    return (f_varint(1, 8) + f_varint(2, 41) + f_bytes(10, f_bytes(37, b"".join(f_bytes(1, s) for s in sections)))).hex()

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

# BLE V1 (docs/BLE-V1.md): AES-CCM, nonce = nonce4 | 0 u32 | counter u32 LE; the phone counts from 1,
# the watch always uses 0. Every value starts with a u16 chunk field; 0 means a control message.
dec_nonce = okm[32:36]
def v1_nonce(base, ctr): return base + bytes(4) + ctr.to_bytes(4, "little")
def to_watch(pt, ctr): return AESCCM(enc_key, tag_length=4).encrypt(v1_nonce(enc_nonce, ctr), pt, None)
def from_watch(pt): return AESCCM(dec_key, tag_length=4).encrypt(v1_nonce(dec_nonce, 0), pt, None)
def u16(v): return v.to_bytes(2, "little")
def w(b): return "w:" + b.hex()
def slices(body, size): return [w(u16(i // size + 1) + body[i:i + size]) for i in range(0, len(body), size)]
nonce_cmd = f_varint(1, 1) + f_varint(2, 26) + f_bytes(3, f_bytes(30, f_bytes(1, phone)))
battery_cmd = f_varint(1, 2) + f_varint(2, 1)
big, plain30, in_plain = bytes(range(40)), bytes(range(0x80, 0x9E)), b"watch says hi"
in_big = bytes(255 - i for i in range(41))
enc_big = u16(1) + to_watch(big, 1)  # chunked and encrypted: the counter goes in front
in_ct = from_watch(in_big)
in_slices = [u16(1) + in_ct[:18], u16(2) + in_ct[18:36], u16(3) + in_ct[36:]]
PLAIN, ENC = b"\0\0\x02\x02", b"\0\0\x02\x01"
ACK, READY, DONE = w(b"\0\0\x03\0"), w(b"\0\0\x01\x01"), w(b"\0\0\x01\0")

want = {
    "ccm_decrypt": b"BandProbe companion device test vector!".hex(),
    "ccm_decrypt_empty": "",
    "ccm_decrypt_rejects": [True, True],
    "v1_nonce": "01020304" + "00000000" + "0d0c0b0a",
    "v1_plain_queue": [[w(PLAIN + nonce_cmd)], [], [w(PLAIN + battery_cmd), "ack:true"]],
    "v1_enc_single": [[w(ENC + u16(1) + to_watch(battery_cmd, 1))], ["ack:true"],
                      [w(ENC + u16(2) + to_watch(battery_cmd, 2))]],
    "v1_enc_chunked": [[w(b"\0\0\0\x01" + u16(3))], slices(enc_big, 18), [slices(enc_big, 18)[1]], ["ack:true"]],
    "v1_plain_chunked": [[w(b"\0\0\0\0" + u16(2))], slices(plain30, 18), ["ack:false"]],
    "v1_in_single": [[ACK, "msg:" + in_plain.hex()], [ACK, "msg:" + in_plain.hex()], [ACK, "bad:8"]],
    "v1_in_enc_frame": (ENC + from_watch(in_plain)).hex(),
    "v1_in_slices": [s.hex() for s in in_slices],
    "v1_in_chunked": [[READY], [], ["receiving:true"], [w(b"\0\0\x01\x05" + u16(1) + u16(3))], [],
                      [DONE, "msg:" + in_big.hex()], ["receiving:false"], []],
    "v1_unexpected": [["?"], ["?"], ["?"], ["?"]],
    "v1_auth_reset": [[w(PLAIN + nonce_cmd)], [w(ENC + u16(1) + to_watch(battery_cmd, 1))]],
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
    "live_intensity": 49,  # realTimeStats field 5
    # gnss(18).gps_info(3){timestamp 1, longitude 2, latitude 3, altitude 4}; doubles are wire type 1, little-endian
    "gps_info": (f_varint(1, 16) + f_varint(2, 2) + f_bytes(18, f_bytes(3, f_varint(1, 1760000000)
                 + varint(2 << 3 | 1) + struct.pack("<d", 28.9784) + varint(3 << 3 | 1) + struct.pack("<d", 41.0082)
                 + varint(4 << 3 | 1) + struct.pack("<d", 35.5)))).hex(),
    "gps_info_no_altitude": (f_varint(1, 16) + f_varint(2, 2) + f_bytes(18, f_bytes(3, f_varint(1, 1760000000)
                 + varint(2 << 3 | 1) + struct.pack("<d", 151.2093) + varint(3 << 3 | 1) + struct.pack("<d", -33.8688)))).hex(),
    # Gadgetbridge setCurrentTime: local date/time, sint32 (zigzag) 15-min offsets, name, isNot24hour
    "clock_istanbul": clock(1760000000, "Europe/Istanbul", True),
    "clock_newyork_12h": clock(1760000000, "America/New_York", False),
    # docs/SLEEP-WRITEBACK.md: Command{8,41}, fitness(10).sleepResult(37), one section(1) per sleep
    "sleep_result": sleep_result(sleep_section(12, 437 * 60, 1794090600, 1794117600, 56, 96)),
    "sleep_result_two": sleep_result(
        sleep_section(-16, 437 * 60, 1794090600, 1794117600, 56, 96, extra=(1794089700, 26220, 82, 91, 15)),
        sleep_section(-16, 45 * 60, 1794140000, 1794143000, 0, 0)),
    "sleep_result_empty": sleep_result(),
    # docs/ACTIVITY.md section 2.2
    "activity_today": "0808100152042a020800",
    "activity_past": "08081002",
    "activity_fetch": "080810035209120700f15365040001",
    "activity_ack": (f_varint(1, 8) + f_varint(2, 5) + f_bytes(10, f_bytes(3, bytes.fromhex("00f15365040001")))).hex(),
    "notify_cmd": (f_varint(1, 7) + f_varint(2, 0) + f_bytes(9, f_bytes(3, f_bytes(1,
        f_bytes(1, b"dev.cobanov.freeband") + f_bytes(2, b"Freeband") + f_bytes(3, "Başlık".encode()) + f_bytes(4, b"")
        + f_bytes(5, b"Merhaba") + f_bytes(6, __import__("datetime").datetime.fromtimestamp(1760000000, __import__("datetime").timezone.utc).strftime("%Y%m%dT%H%M%S").encode())
        + f_varint(7, 42))))).hex(),
    "find_start": (f_varint(1, 2) + f_varint(2, 18) + f_bytes(4, f_varint(5, 0))).hex(),
    "find_stop": (f_varint(1, 2) + f_varint(2, 18) + f_bytes(4, f_varint(5, 1))).hex(),
    # docs/STAY-CONNECTED.md section 1: the phone's stop; the band's 0 or missing value starts, others stop
    "find_phone_stop": "0802101122022801",
    "find_phone_parsed": ["true", "false", "true", "nil", "nil"],
    # (next, nack): resend nack..next-1 mod 256 when 0 < next-nack <= 32 (the TX window)
    "resend_seqs": [[(nack + i) % 256 for i in range((next - nack) % 256)] if 0 < (next - nack) % 256 <= 32 else []
                    for next, nack in [(10, 10), (10, 7), (3, 250), (40, 8), (40, 7), (10, 11)]],
}
# Health monitoring settings: the expected bytes are built here field by field, in the order the
# band sent them; a changed field keeps its place, a new one goes to the end.
def hr_body(disabled, interval, sleep, tail9_11=True):
    return (f_varint(1, disabled) + f_varint(2, interval) + f_varint(3, 1) + f_varint(4, 120)
            + f_bytes(5, f_varint(1, sleep)) + f_varint(7, 1) + f_bytes(8, f_varint(1, 0) + f_varint(2, 40))
            + f_varint(9, 2) + (f_varint(10, 0) if tail9_11 else b"") + f_varint(11, 1)
            + f_varint(20, 300) + f_bytes(21, b"ab") + bytes([0xB5, 0x01, 1, 2, 3, 4]))
def mon_set(sub, field, body): return (f_varint(1, 8) + f_varint(2, sub) + f_bytes(10, f_bytes(field, body))).hex()
want.update({
    "mon_get": [(f_varint(1, 8) + f_varint(2, s)).hex() for s in (8, 10, 14)],
    "mon_reply": hr_body(0, 30, 1).hex(),
    "mon_reply_other": True,
    "mon_hr_parsed": "every(30)/true",
    # field 10 came back as 0 (the band doesn't have it), so it is not sent
    "mon_hr_1min": mon_set(11, 8, hr_body(0, 1, 1, tail9_11=False)),
    "mon_hr_off": mon_set(11, 8, hr_body(1, 30, 1, tail9_11=False)),
    "mon_hr_smart_nosleep": mon_set(11, 8, hr_body(0, 0, 0, tail9_11=False)),
    "mon_hr_empty_smart": mon_set(11, 8, f_varint(1, 0) + f_varint(2, 0) + f_bytes(5, f_varint(1, 0)) + f_varint(7, 1)),
    "mon_hr_garbage": "nil",
    "mon_spo2_parsed": 0,
    "mon_spo2_allday": mon_set(9, 7, f_varint(1, 1) + f_varint(2, 2) + f_bytes(4, f_varint(1, 1) + f_varint(2, 90))),
    "mon_stress_parsed": False,
    "mon_stress_on": mon_set(15, 10, f_varint(1, 1) + f_bytes(2, f_varint(1, 1) + f_varint(2, 0))),
})
# The band's state: charging is battery state 1 (2 and 3 are not); the 2/78 reply is not read;
# the 2/79 push is {charging 1: 1 yes / 2 no, wearing 2, sleep 3}.
want.update({
    "battery_charging": ["false", "true", "false", "nil"],
    "battery_level_with_state": 82,
    "state_basic_not_read": "nil",
    "state_pushed": "false/true/false",
    # a push with only charging (2 = no): the other parts are not in it
    "state_pushed_one_field": "false/nil/nil",
})
bad = [k for k in want if got.get(k) != want[k]]
for k in want:
    print(("OK  " if k not in bad else "FAIL"), k)
sys.exit(1 if bad else 0)
