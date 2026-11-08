#!/usr/bin/env python3
"""Reference parser for Xiaomi band activity files (Freeband, BLE V2 / SPP V2).

Standard library only. It implements the layouts written down in
docs/ACTIVITY.md: the 7-byte file id, reassembly of the chunks the band sends on
channel 5, the CRC-32 trailer and the payloads of the activity file kinds that
carry steps, heart rate, stress, SpO2, calories, sleep and daily summaries.
It was written from that spec as a second, independent implementation, so the
Swift port has something to diff against.

    activity_ref.py fileid 21F328650403A0
    activity_ref.py parse FILE.bin [--no-crc]
    activity_ref.py parse --hex 00F15365... [--no-crc]
    activity_ref.py assemble CHUNK1.bin CHUNK2.bin ...
    activity_ref.py --selftest [FIXTURE_DIR]
    activity_ref.py --dump [FIXTURE_DIR]      (full output per fixture case, for the Swift diff)

Output is JSON on stdout. Timestamps are Unix seconds (UTC); the file id's
timezone is given in quarter hours and as minutes.
"""
from __future__ import annotations

import datetime as _dt
import glob
import json
import math
import os
import struct
import sys
import zlib  # selftest only: cross-checks the table-driven CRC below

# ---------------------------------------------------------------------------
# errors and byte cursor


class FormatError(ValueError):
    """The bytes do not match the expected layout."""


class Truncated(FormatError):
    """A read ran past the end of the payload."""


class CrcMismatch(FormatError):
    pass


class Cursor:
    """Little-endian reader over data[pos:end]."""

    def __init__(self, data: bytes, pos: int = 0, end: int | None = None):
        self.data = data
        self.pos = pos
        self.end = len(data) if end is None else end

    def left(self) -> int:
        return self.end - self.pos

    def take(self, n: int) -> bytes:
        if n < 0 or self.pos + n > self.end:
            raise Truncated(f"need {n} byte(s) at offset {self.pos}, {self.left()} left")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return int.from_bytes(self.take(2), "little")

    def i16(self) -> int:
        return int.from_bytes(self.take(2), "little", signed=True)

    def u32(self) -> int:
        return int.from_bytes(self.take(4), "little")

    def i64(self) -> int:
        return int.from_bytes(self.take(8), "little", signed=True)

    def f32(self) -> float:
        return struct.unpack("<f", self.take(4))[0]


# ---------------------------------------------------------------------------
# CRC-32 (IEEE 802.3 / zlib: reflected poly 0xEDB88320, init and final xor 0xFFFFFFFF)


def _crc_table() -> list[int]:
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
        table.append(c)
    return table


_CRC = _crc_table()


def crc32(data: bytes) -> int:
    c = 0xFFFFFFFF
    for b in data:
        c = _CRC[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


# ---------------------------------------------------------------------------
# file id

TYPE_NAMES = {0: "activity", 1: "sports"}
ACTIVITY_SUBTYPES = {0x00: "daily", 0x03: "sleep_stages", 0x06: "manual_samples", 0x08: "sleep"}
SPORTS_SUBTYPES = {
    0x01: "outdoor_running", 0x02: "outdoor_walking_v1", 0x03: "treadmill",
    0x06: "outdoor_cycling_v2", 0x07: "indoor_cycling", 0x08: "freestyle",
    0x09: "pool_swimming", 0x0B: "elliptical", 0x0D: "rowing", 0x0E: "jump_roping",
    0x10: "hiit", 0x16: "outdoor_walking_v2", 0x17: "outdoor_cycling",
}
DETAIL_NAMES = {0: "details", 1: "summary", 2: "gps_track"}
_FETCH_RANK = {1: 0, 0: 1, 2: 2}  # summary, details, gps_track, anything else last


class FileId:
    __slots__ = ("ts", "tz", "version", "type", "subtype", "detail")

    def __init__(self, ts: int, tz: int, version: int, type_: int, subtype: int, detail: int):
        self.ts, self.tz, self.version = ts, tz, version
        self.type, self.subtype, self.detail = type_, subtype, detail

    @classmethod
    def parse(cls, raw: bytes) -> "FileId":
        if len(raw) < 7:
            raise FormatError(f"file id needs 7 bytes, got {len(raw)}")
        ts = int.from_bytes(raw[0:4], "little")
        tz = raw[4] - 256 if raw[4] >= 0x80 else raw[4]
        flags = raw[6]
        return cls(ts, tz, raw[5], flags >> 7, (flags >> 2) & 0x1F, flags & 0x03)

    def to_bytes(self) -> bytes:
        flags = ((self.type & 0x01) << 7) | ((self.subtype & 0x1F) << 2) | (self.detail & 0x03)
        return self.ts.to_bytes(4, "little") + bytes([self.tz & 0xFF, self.version & 0xFF, flags])

    @property
    def is_empty(self) -> bool:
        # list entries with ts == 0 and version == 0 are placeholders, never requested
        return self.ts == 0 and self.version == 0

    def fetch_key(self) -> tuple:
        return (self.ts, self.tz, self.type, self.subtype, _FETCH_RANK.get(self.detail, 3), self.version)

    def names(self) -> tuple[str, str, str]:
        t = TYPE_NAMES.get(self.type, "unknown")
        table = ACTIVITY_SUBTYPES if self.type == 0 else SPORTS_SUBTYPES
        return t, table.get(self.subtype, f"unknown_{self.subtype:02x}"), DETAIL_NAMES.get(self.detail, "unknown")

    def to_json(self) -> dict:
        t, s, d = self.names()
        return {
            "hex": self.to_bytes().hex(),
            "ts": self.ts,
            "iso_utc": _iso(self.ts),
            "tz_quarters": self.tz,
            "utc_offset_min": self.tz * 15,
            "local_date": _dt.datetime.fromtimestamp(self.ts + self.tz * 900, _dt.timezone.utc).strftime("%Y-%m-%d"),
            "version": self.version,
            "type": self.type, "type_name": t,
            "subtype": self.subtype, "subtype_name": s,
            "detail": self.detail, "detail_name": d,
        }


def _iso(ts: int) -> str:
    return _dt.datetime.fromtimestamp(ts, _dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_id_list(blob: bytes) -> list[FileId]:
    """health.activityRequestFileIds of a subtype 1/2 reply: N x 7 bytes."""
    if len(blob) % 7:
        raise FormatError(f"id list length {len(blob)} is not a multiple of 7")
    ids = [FileId.parse(blob[i:i + 7]) for i in range(0, len(blob), 7)]
    return [f for f in ids if not f.is_empty]


# ---------------------------------------------------------------------------
# chunk reassembly (channel 5 payload, already decrypted)


class ChunkAssembler:
    """Each chunk: total u16 LE | index u16 LE (1-based) | bytes. Index == total ends a file.

    Stricter than Gadgetbridge on purpose: a chunk out of sequence raises instead of
    being appended.
    """

    def __init__(self):
        self.reset()

    def reset(self):
        self.buf = bytearray()
        self.total = None
        self.next_index = 1

    def feed(self, chunk: bytes) -> bytes | None:
        if len(chunk) < 4:
            raise FormatError(f"chunk of {len(chunk)} bytes has no header")
        total, index = struct.unpack_from("<HH", chunk)
        if index == 1:
            self.reset()
            self.total = total
        elif self.total is None or index != self.next_index or total != self.total:
            expected = self.next_index if self.total is not None else 1
            self.reset()
            raise FormatError(f"chunk {index}/{total} out of sequence, expected {expected}")
        self.buf += chunk[4:]
        self.next_index = index + 1
        if index >= total:
            out = bytes(self.buf)
            self.reset()
            return out
        return None


# ---------------------------------------------------------------------------
# file envelope: id(7) | pad(1) | payload | crc32 LE(4)


def open_file(data: bytes, has_crc: bool = True):
    """Returns (file_id, pad_byte, payload, crc_info). Raises CrcMismatch on a bad trailer."""
    crc = None
    end = len(data)
    if has_crc:
        # 12 = id + pad + CRC: an empty file (no records of its kind); Gadgetbridge drops under 13
        if len(data) < 12:
            raise FormatError(f"file of {len(data)} bytes is shorter than the 12-byte minimum")
        stored = int.from_bytes(data[-4:], "little")
        computed = crc32(data[:-4])
        crc = {"stored": f"{stored:08x}", "computed": f"{computed:08x}", "ok": stored == computed}
        if stored != computed:
            raise CrcMismatch(f"crc stored {stored:08x} computed {computed:08x}")
        end -= 4
    elif len(data) < 8:
        raise FormatError(f"file of {len(data)} bytes has no id and pad byte")
    return FileId.parse(data[:7]), data[7], data[8:end], crc


def bit_valid(bitmap: bytes, index: int) -> bool:
    """Validity bitmap, MSB first: index 0 is bit 7 of byte 0."""
    byte = index // 8
    if byte >= len(bitmap):
        return False
    return bool(bitmap[byte] & (0x80 >> (index % 8)))


# ---------------------------------------------------------------------------
# daily details (activity / daily / details): one record per minute

DAILY_DETAILS_HEADER = {1: 4, 2: 4, 3: 5, 4: 6}


class _Group:
    def __init__(self, raw: int, width: int, nibble: int):
        self.raw, self.width, self.nibble = raw, width, nibble

    def valid(self, slot: int) -> bool:
        # nibble bit 3 = group present; bits 2, 1, 0 = slots 0, 1, 2 valid
        return bool(self.nibble & (0x4 >> slot))

    def bits(self, start: int, count: int) -> int:
        # start is counted from the most significant bit of the group value
        shift = self.width - start - count
        return (self.raw >> shift) & ((1 << count) - 1)


class _GroupWalker:
    def __init__(self, header: bytes, cur: Cursor):
        self.header, self.cur, self.index = header, cur, 0

    def next(self, width: int) -> _Group | None:
        i = self.index
        self.index += 1
        if i >= 2 * len(self.header):
            raise FormatError(f"header of {len(self.header)} bytes has no nibble for group {i}")
        b = self.header[i // 2]
        nibble = b >> 4 if i % 2 == 0 else b & 0x0F
        if not nibble & 0x8:
            return None  # absent: occupies no bytes in the record
        return _Group(int.from_bytes(self.cur.take(width // 8), "little"), width, nibble)


def _daily_details_record(version: int, header: bytes, cur: Cursor) -> dict:
    g = _GroupWalker(header, cur)
    rec = {
        "steps": None, "active_calories": None, "distance_m": None, "heart_rate": None,
        "energy": None, "spo2": None, "stress": None,
    }
    extra = 0
    x = g.next(16)  # g0: [15] unknown | [14] extra-byte flag | [13..0] steps
    if x is not None:
        if x.valid(1):
            extra = x.bits(1, 1)
        if x.valid(2):
            rec["steps"] = x.bits(2, 14)
    x = g.next(8)  # g1: [7..6] unknown | [5..0] active calories
    if x is not None and x.valid(1):
        rec["active_calories"] = x.bits(2, 6)
    g.next(8)  # g2: unknown
    x = g.next(16)  # g3: distance in metres
    if x is not None and x.valid(0):
        rec["distance_m"] = x.raw
    x = g.next(8)  # g4: heart rate
    if x is not None and x.valid(0):
        rec["heart_rate"] = x.raw
    x = g.next(8)  # g5: energy
    if x is not None and x.valid(0):
        rec["energy"] = x.raw
    g.next(16)  # g6: unknown
    if version >= 3:
        x = g.next(8)  # g7: SpO2
        if x is not None and x.valid(0):
            rec["spo2"] = x.raw
        x = g.next(8)  # g8: stress, 255 = none
        if x is not None and x.valid(0) and x.raw != 0xFF:
            rec["stress"] = x.raw
    if extra:
        rec["extra_byte"] = cur.u8()  # meaning unknown, only consumed
    if version >= 4:
        x = g.next(16)  # g9: "light" (not decoded upstream)
        if x is not None and x.valid(0):
            rec["light_raw"] = x.raw
        x = g.next(16)  # g10: "body momentum" (not decoded upstream)
        if x is not None and x.valid(0):
            rec["body_momentum_raw"] = x.raw
    return rec


def parse_daily_details(fid: FileId, body: bytes) -> dict:
    if fid.version not in DAILY_DETAILS_HEADER:
        raise FormatError(f"daily details version {fid.version} unsupported")
    cur = Cursor(body)
    header = cur.take(DAILY_DETAILS_HEADER[fid.version])
    records, tail = [], 0
    while cur.left() > 0:
        start = cur.pos
        try:
            rec = _daily_details_record(fid.version, header, cur)
        except Truncated:
            tail = len(body) - start
            break
        rec["ts"] = fid.ts + 60 * len(records)
        records.append(rec)
    out = {"header_hex": header.hex(), "records": records}
    if tail:
        out["truncated_tail"] = tail
    return out


# ---------------------------------------------------------------------------
# daily summary (activity / daily / summary)

# (name or None for reserved, size in bytes); all little-endian unsigned
DAILY_SUMMARY_SLOTS = [
    ("steps", 4), ("active_calories", 2), (None, 1), ("hr_resting", 1), ("hr_max", 1),
    ("hr_max_ts", 4), ("hr_min", 1), ("hr_min_ts", 4), ("hr_avg", 1), ("stress_avg", 1),
    ("stress_max", 1), ("stress_min", 1), ("standing", 3), ("calories", 2),
    ("recovery_hours", 2), (None, 1), ("spo2_max", 1), ("spo2_max_ts", 4), ("spo2_min", 1),
    ("spo2_min_ts", 4), ("spo2_avg", 1),
    # version 5 onwards
    ("training_load_day", 2), ("training_load_week", 2), ("training_load_level", 1),
    ("vitality_light", 1), ("vitality_moderate", 1), ("vitality_high", 1),
    ("vitality_current", 2), (None, 1), (None, 1), (None, 2), (None, 2),
]
DAILY_SUMMARY_LAYOUT = {3: (3, 21), 4: (3, 21), 5: (4, 32)}  # version: (bitmap bytes, slots)
# A Band 10 Pro v5 file stops after slot 29 (its bitmap marks 30 and 31 invalid), so slots past
# the v3/v4 set may be missing when the body ends cleanly on a slot boundary.
DAILY_SUMMARY_BASE_SLOTS = 21


def parse_daily_summary(fid: FileId, body: bytes) -> dict:
    if fid.version not in DAILY_SUMMARY_LAYOUT:
        raise FormatError(f"daily summary version {fid.version} unsupported")
    bitmap_len, slots = DAILY_SUMMARY_LAYOUT[fid.version]
    cur = Cursor(body)
    bitmap = cur.take(bitmap_len)
    out = {"bitmap_hex": bitmap.hex()}
    for i in range(slots):
        if i >= DAILY_SUMMARY_BASE_SLOTS and not cur.left():
            break
        name, size = DAILY_SUMMARY_SLOTS[i]
        value = int.from_bytes(cur.take(size), "little")
        if name is None:
            continue
        out[name] = value if bit_valid(bitmap, i) else None
    for name, _ in DAILY_SUMMARY_SLOTS[slots:]:
        if name is not None:
            out[name] = None
    for name, _ in DAILY_SUMMARY_SLOTS[:slots]:
        if name is not None:
            out.setdefault(name, None)
    if out["standing"] is not None:
        out["standing_hours"] = [h for h in range(24) if out["standing"] >> h & 1]
    if cur.left():
        out["trailing_bytes"] = cur.left()
    return out


# ---------------------------------------------------------------------------
# sleep details (activity / sleep / any detail type)

SLEEP_DETAILS_BITMAP = {1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 3}
SLEEP_DETAILS_V6_EXTRA = 24  # unknown fields between wakeup_time2 and the HR block
STAGE_MAGIC = b"\xfb\xfa\xfc\xff"
STAGE_PACKET_HEADER = 17
NO_DATA_PACKET_TYPES = {2, 3, 9, 12, 13, 14, 15, 18, 19}
DETAIL_STAGE = {0: "awake", 1: "light", 2: "deep", 3: "rem", 4: "not_sleep"}


def _sample_block(version: int, bed_time: int, cur: Cursor, read) -> dict:
    unit = cur.u16()
    count = cur.u16()
    block = {"unit": unit, "count": count, "first_ts": None, "values": []}
    if count:
        block["first_ts"] = cur.u32() if version >= 2 else bed_time
        block["values"] = [read() for _ in range(count)]
    return block


def parse_sleep_details(fid: FileId, body: bytes) -> dict:
    v = fid.version
    if v not in SLEEP_DETAILS_BITMAP:
        raise FormatError(f"sleep details version {v} unsupported")
    cur = Cursor(body)
    bitmap = cur.take(SLEEP_DETAILS_BITMAP[v])
    out = {"bitmap_hex": bitmap.hex()}
    out["is_awake"] = cur.u8()  # bitmap index 0, always present
    out["bed_time"] = cur.u32()  # index 1
    out["wakeup_time"] = cur.u32()  # index 2
    idx = 3
    out["sleep_quality"] = None
    if v >= 4:
        if bit_valid(bitmap, idx):
            out["sleep_quality"] = cur.u8()
        idx += 1
    if v >= 5:
        out["v5_unknown_hex"] = cur.take(9).hex()
        out["bed_time2"] = cur.u32()
        out["wakeup_time2"] = cur.u32()
        idx += 5
    if v >= 6:
        out["v6_unknown_hex"] = cur.take(SLEEP_DETAILS_V6_EXTRA).hex()
    blocks_at = cur.pos
    try:
        out["hr"] = _sample_block(v, out["bed_time"], cur, cur.u8) if bit_valid(bitmap, idx) else None
        idx += 1
        out["spo2"] = _sample_block(v, out["bed_time"], cur, cur.u8) if bit_valid(bitmap, idx) else None
        idx += 1
        out["snore"] = None
        if v >= 3:
            if bit_valid(bitmap, idx):
                # float32 up to v5; the one real v6 file has u16 values that end exactly at the stream
                out["snore"] = _sample_block(v, out["bed_time"], cur, cur.u16 if v >= 6 else cur.f32)
            idx += 1
        if v >= 6 and cur.left() and cur.data[cur.pos:cur.pos + 4] != STAGE_MAGIC:
            raise Truncated(f"sample blocks end at offset {cur.pos}, not at a packet")
    except Truncated as e:
        if v < 6:
            raise
        # v6 field bits are a guess; keep the stream rather than fail the night
        out["blocks_error"] = str(e)
        out["hr"] = out["spo2"] = out["snore"] = None
        cur.pos = blocks_at

    packets, stages, summaries, rr = [], [], [], []
    out["skipped_bytes"] = 0
    data, pos, end = cur.data, cur.pos, cur.end
    while end - pos >= STAGE_PACKET_HEADER:
        at = data.find(STAGE_MAGIC, pos, end)
        if at < 0 or end - at < STAGE_PACKET_HEADER:
            break
        out["skipped_bytes"] += at - pos
        h = Cursor(data, at + 4, end)
        header_len = h.u8()
        ts = h.i64()
        parity = h.u8()
        ptype = h.u8()
        length = int.from_bytes(h.take(2), "big")
        pos = h.pos
        pkt = {"type": ptype, "ts": ts, "parity": parity, "header_len": header_len}
        packets.append(pkt)
        if ptype in NO_DATA_PACKET_TYPES:
            pkt["flags"] = length  # no payload follows these
            continue
        if pos + length > end:
            out["error"] = f"packet type {ptype} wants {length} bytes, {end - pos} left"
            pos = end
            break
        payload = data[pos:pos + length]
        pos += length
        pkt["length"] = length
        if ptype == 17:
            t = ts
            for i in range(0, length - 1, 2):
                word = int.from_bytes(payload[i:i + 2], "big")
                code, minutes = word >> 12, word & 0x0FFF
                stages.append({"ts": t, "stage": DETAIL_STAGE.get(code, "unknown"), "raw": code,
                               "duration_min": minutes})
                t += minutes * 60
        elif ptype == 16 and length >= 13:
            p = payload
            summaries.append({
                "ts": ts,
                "sleep_index": p[0] >> 4, "wake_count": p[0] & 0x0F,
                "sleep_min": int.from_bytes(p[1:3], "big"),
                "awake_min": int.from_bytes(p[3:5], "big"),
                "light_min": int.from_bytes(p[5:7], "big"),
                "rem_min": int.from_bytes(p[7:9], "big"),
                "deep_min": int.from_bytes(p[9:11], "big"),
                "flags": p[11], "unknown_min": p[12],
            })
        elif ptype == 1:
            rr.append({"ts_raw": ts, "rr_ms": [10 * b for b in payload]})
        else:
            pkt["payload_hex"] = payload.hex()
    out["trailing_bytes"] = end - pos
    out["packets"] = packets
    out["stages"] = stages
    out["summaries"] = summaries
    out["rr"] = rr
    out["sleep_spans"] = sleep_spans(packets)
    return out


def packet_seconds(ts: int) -> int:
    """Packet timestamp to Unix seconds, the unit told by the magnitude: a Xiaomi Watch S1 Active
    writes types 1, 2, 3 and 101 in milliseconds and 0, 9, 10 in nanoseconds; type 17 is seconds."""
    for limit, scale in ((10**17, 10**9), (10**14, 10**6), (10**11, 10**3)):
        if abs(ts) >= limit:
            return abs(ts) // scale * (1 if ts >= 0 else -1)  # truncates toward zero, as Swift does
    return ts


def sleep_spans(packets: list) -> list:
    """Fell-asleep (type 2) and woke-up (type 3) events paired in time order, as [start, end]
    Unix seconds. A second fall-asleep before a wake-up keeps the first; a lone wake-up is dropped."""
    events = sorted((packet_seconds(p["ts"]), p["type"]) for p in packets if p["type"] in (2, 3))
    spans, start = [], None
    for t, kind in events:
        if kind == 2:
            if start is None:
                start = t
        elif start is not None:
            if t > start:
                spans.append([start, t])
            start = None
    return spans


# ---------------------------------------------------------------------------
# sleep stages (activity / sleep_stages / details), version 2 only

STORED_STAGE = {2: "deep", 3: "light", 4: "rem", 5: "awake"}


def parse_sleep_stages(fid: FileId, body: bytes) -> dict:
    if fid.version != 2:
        raise FormatError(f"sleep stages version {fid.version} unsupported")
    cur = Cursor(body)
    out = {"unknown1_hex": cur.take(7).hex()}
    out["total_min"] = cur.i16()
    out["bed_time"] = cur.u32()
    out["wakeup_time"] = cur.u32()
    out["unknown2_hex"] = cur.take(3).hex()
    out["deep_min"] = cur.i16()
    out["light_min"] = cur.i16()
    out["rem_min"] = cur.i16()
    out["awake_min"] = cur.i16()
    out["no_data"] = out["bed_time"] == 0 or out["wakeup_time"] == 0 or out["total_min"] == 0
    out["unknown3"] = cur.u8()
    stages = []
    while cur.left() >= 5:
        ts = cur.u32()
        code = cur.u8()
        stages.append({"ts": ts, "stage": STORED_STAGE.get(code, "unknown"), "raw": code})
    out["stages"] = stages
    if cur.left():
        out["trailing_bytes"] = cur.left()
    return out


# ---------------------------------------------------------------------------
# manual samples (activity / manual_samples / details)

MANUAL_TYPES = {0x11: "heart_rate", 0x12: "spo2", 0x13: "stress", 0x44: "temperature"}
MANUAL_V1_TYPES = {0x02: 0x12, 0x03: 0x13}


def parse_manual_samples(fid: FileId, body: bytes, pad: int) -> dict:
    cur = Cursor(body)
    samples, zero = [], 0
    if fid.version == 1:
        if pad != 0:
            raise FormatError(f"manual samples v1 pad byte {pad:#04x}")
        if cur.u8() != 0xFF:
            raise FormatError("manual samples v1 header byte is not 0xff")
        if cur.left() == 0 or cur.left() % 6:
            raise FormatError(f"manual samples v1 payload of {cur.left()} bytes")
        while cur.left():
            ts, t1, value = cur.u32(), cur.u8(), cur.u8()
            if t1 not in MANUAL_V1_TYPES:
                raise FormatError(f"manual samples v1 type {t1:#04x}")
            if not 1 <= value <= 100:
                raise FormatError(f"manual samples v1 value {value}")
            t = MANUAL_V1_TYPES[t1]
            samples.append({"ts": ts, "type": t, "type_name": MANUAL_TYPES[t], "value": value})
        return {"samples": samples}
    if fid.version != 2:
        raise FormatError(f"manual samples version {fid.version} unsupported")
    out = {}
    while cur.left():
        at = cur.pos
        ts, t = cur.u32(), cur.u8()
        if t in (0x11, 0x12, 0x13):
            value = cur.u8()
        elif t == 0x44:
            value = cur.u32()
        else:
            out["error"] = f"unknown sample type {t:#04x} at payload offset {at}"
            break
        if value == 0:
            zero += 1
            continue
        s = {"ts": ts, "type": t, "type_name": MANUAL_TYPES[t], "value": value}
        if t == 0x44:
            s["celsius"] = (value & 0xFFFF) / 100.0
            s["high16"] = value >> 16
        samples.append(s)
    out["samples"] = samples
    out["zero_value_records"] = zero
    return out


# ---------------------------------------------------------------------------
# dispatch


def kind_of(fid: FileId) -> str:
    if fid.type == 0:
        if fid.subtype == 0x00 and fid.detail == 0:
            return "daily_details"
        if fid.subtype == 0x00 and fid.detail == 1:
            return "daily_summary"
        if fid.subtype == 0x03 and fid.detail == 0:
            return "sleep_stages"
        if fid.subtype == 0x06 and fid.detail == 0:
            return "manual_samples"
        if fid.subtype == 0x08:
            return "sleep_details"
        return "unsupported"
    if fid.type == 1:
        return {0: "workout_details", 1: "workout_summary", 2: "workout_gps"}.get(fid.detail, "unsupported")
    return "unsupported"


def parse_file(data: bytes, has_crc: bool = True) -> dict:
    fid, pad, body, crc = open_file(data, has_crc)
    kind = kind_of(fid)
    out = {"file_id": fid.to_json(), "kind": kind, "pad": pad, "crc": crc, "payload_len": len(body)}
    if not body and crc is not None:
        # empty file (no records of its kind); only a checked CRC tells it from a cut-off one
        out["data"] = None
    elif kind == "daily_details":
        out["data"] = parse_daily_details(fid, body)
    elif kind == "daily_summary":
        out["data"] = parse_daily_summary(fid, body)
    elif kind == "sleep_details":
        out["data"] = parse_sleep_details(fid, body)
    elif kind == "sleep_stages":
        out["data"] = parse_sleep_stages(fid, body)
    elif kind == "manual_samples":
        out["data"] = parse_manual_samples(fid, body, pad)
    else:
        out["data"] = None  # workouts and unknown kinds: envelope only
    return out


# ---------------------------------------------------------------------------
# selftest


def _match(expected, actual, path="$") -> list[str]:
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {actual!r}"]
        errs = []
        for k, v in expected.items():
            if k not in actual:
                errs.append(f"{path}.{k}: missing")
            elif k == "blocks_error" and isinstance(v, str) and isinstance(actual[k], str):
                continue  # free text, presence only
            else:
                errs += _match(v, actual[k], f"{path}.{k}")
        return errs
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            n = len(actual) if isinstance(actual, list) else type(actual).__name__
            return [f"{path}: expected list of {len(expected)}, got {n}"]
        errs = []
        for i, (e, a) in enumerate(zip(expected, actual)):
            errs += _match(e, a, f"{path}[{i}]")
        return errs
    if isinstance(expected, float) and isinstance(actual, (int, float)):
        return [] if math.isclose(expected, actual, abs_tol=1e-6) else [f"{path}: {actual} != {expected}"]
    if expected != actual or type(expected) is bool and type(actual) is not bool:
        return [f"{path}: {actual!r} != {expected!r}"]
    return []


def _run_case(case: dict) -> list[str]:
    kind = case["kind"]
    if kind == "fileid":
        raw = bytes.fromhex(case["hex"])
        fid = FileId.parse(raw)
        errs = _match(case["expect"], {**fid.to_json(), "is_empty": fid.is_empty})
        if case.get("roundtrip", True) and fid.to_bytes() != raw[:7]:
            errs.append(f"roundtrip {fid.to_bytes().hex()} != {raw[:7].hex()}")
        return errs
    if kind == "idlist":
        ids = parse_id_list(bytes.fromhex(case["hex"]))
        return _match(case["expect"], [f.to_json() for f in ids])
    if kind == "fetch_order":
        ids = [FileId.parse(bytes.fromhex(h)) for h in case["ids"]]
        got = [f.to_bytes().hex() for f in sorted(ids, key=FileId.fetch_key)]
        return [] if got == case["expect"] else [f"order {got} != {case['expect']}"]
    if kind == "crc":
        got = crc32(bytes.fromhex(case["hex"]))
        return [] if got == int(case["expect"], 16) else [f"crc {got:08x} != {case['expect']}"]
    if kind == "chunks":
        asm = ChunkAssembler()
        done = None
        try:
            for h in case["chunks"]:
                r = asm.feed(bytes.fromhex(h))
                if r is not None:
                    done = r
        except FormatError as e:
            return [] if case.get("expect_error") else [f"assembler error: {e}"]
        if case.get("expect_error"):
            return ["expected an assembler error"]
        if done is None:
            return ["no complete file"]
        errs = []
        if "expect_file_hex" in case and done.hex() != case["expect_file_hex"].lower():
            errs.append("reassembled bytes differ")
        try:
            parsed = parse_file(done, True)
        except CrcMismatch as e:
            return errs + ([] if case.get("expect_crc_ok") is False else [str(e)])
        if case.get("expect_crc_ok") is False:
            errs.append("expected a CRC mismatch")
        return errs + _match(case.get("expect", {}), parsed)
    if kind == "file":
        data = bytes.fromhex(case["hex"])
        try:
            parsed = parse_file(data, case.get("has_crc", True))
        except FormatError as e:
            if case.get("expect_error"):
                return []
            return [f"{type(e).__name__}: {e}"]
        if case.get("expect_error"):
            return [f"expected an error, got {json.dumps(parsed)[:200]}"]
        return _match(case.get("expect", {}), parsed)
    return [f"unknown case kind {kind}"]


def selftest(fixture_dir: str) -> int:
    # the table-driven CRC must agree with zlib on a few lengths
    for n in (0, 1, 7, 64, 300):
        blob = bytes((i * 37 + 11) & 0xFF for i in range(n))
        assert crc32(blob) == zlib.crc32(blob), "crc32 table broken"
    files = sorted(glob.glob(os.path.join(fixture_dir, "*.json")))
    if not files:
        print(f"no fixtures in {fixture_dir}", file=sys.stderr)
        return 2
    total = failed = 0
    for path in files:
        with open(path, encoding="utf-8") as fh:
            suite = json.load(fh)
        label = os.path.basename(path)
        for case in suite["cases"]:
            total += 1
            errs = _run_case(case)
            if errs:
                failed += 1
                print(f"FAIL {label} :: {case['name']}")
                for e in errs[:8]:
                    print(f"     {e}")
            else:
                print(f"ok   {label} :: {case['name']}")
    print(f"\n{total - failed}/{total} cases passed ({len(files)} fixture files)")
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# dump: full normalised output per fixture case, for diffing another implementation


def _error_class(e: FormatError) -> str:
    if isinstance(e, CrcMismatch):
        return "crc"
    if isinstance(e, Truncated):
        return "truncated"
    return "format"


def _dump_case(case: dict):
    kind = case["kind"]
    if kind == "fileid":
        fid = FileId.parse(bytes.fromhex(case["hex"]))
        return {**fid.to_json(), "is_empty": fid.is_empty, "encoded": fid.to_bytes().hex()}
    if kind == "idlist":
        try:
            return [f.to_json() for f in parse_id_list(bytes.fromhex(case["hex"]))]
        except FormatError as e:
            return {"error_class": _error_class(e)}
    if kind == "fetch_order":
        ids = [FileId.parse(bytes.fromhex(h)) for h in case["ids"]]
        return [f.to_bytes().hex() for f in sorted(ids, key=FileId.fetch_key)]
    if kind == "crc":
        return f"{crc32(bytes.fromhex(case['hex'])):08x}"
    if kind == "chunks":
        asm, done = ChunkAssembler(), None
        try:
            for h in case["chunks"]:
                r = asm.feed(bytes.fromhex(h))
                if r is not None:
                    done = r
        except FormatError:
            return {"error_class": "sequence"}
        if done is None:
            return {"error_class": "incomplete"}
        try:
            return {"file_hex": done.hex(), "parsed": parse_file(done, True)}
        except FormatError as e:
            return {"error_class": _error_class(e)}
    if kind == "file":
        try:
            return parse_file(bytes.fromhex(case["hex"]), case.get("has_crc", True))
        except FormatError as e:
            return {"error_class": _error_class(e)}
    return {"error_class": f"unknown case kind {kind}"}


def dump(fixture_dir: str) -> int:
    """JSON on stdout: every fixture case's full output, plus CRC vectors checked against zlib."""
    vectors = []
    for n in (0, 1, 7, 64, 300):
        blob = bytes((i * 37 + 11) & 0xFF for i in range(n))
        assert crc32(blob) == zlib.crc32(blob), "crc32 table broken"
        vectors.append({"hex": blob.hex(), "crc": f"{zlib.crc32(blob):08x}"})
    cases = []
    for path in sorted(glob.glob(os.path.join(fixture_dir, "*.json"))):
        with open(path, encoding="utf-8") as fh:
            suite = json.load(fh)
        for case in suite["cases"]:
            cases.append({"fixture": os.path.basename(path), "name": case["name"], "output": _dump_case(case)})
    _dump({"crc_vectors": vectors, "cases": cases})
    return 0


# ---------------------------------------------------------------------------
# CLI


def _dump(obj):
    json.dump(obj, sys.stdout, indent=2)
    sys.stdout.write("\n")


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] in ("--selftest", "--dump"):
        here = os.path.dirname(os.path.abspath(__file__))
        fixture_dir = argv[1] if len(argv) > 1 else os.path.join(here, "fixtures")
        return selftest(fixture_dir) if argv[0] == "--selftest" else dump(fixture_dir)
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "fileid":
            _dump([f.to_json() for f in parse_id_list(bytes.fromhex("".join(rest)))])
        elif cmd == "parse":
            has_crc = "--no-crc" not in rest
            rest = [a for a in rest if a != "--no-crc"]
            if rest and rest[0] == "--hex":
                data = bytes.fromhex("".join(rest[1:]))
            else:
                with open(rest[0], "rb") as fh:
                    data = fh.read()
            _dump(parse_file(data, has_crc))
        elif cmd == "assemble":
            asm, done = ChunkAssembler(), None
            for p in rest:
                with open(p, "rb") as fh:
                    r = asm.feed(fh.read())
                if r is not None:
                    done = r
            if done is None:
                raise FormatError("last chunk never arrived")
            _dump(parse_file(done, True))
        else:
            print(f"unknown command {cmd}", file=sys.stderr)
            return 2
    except FormatError as e:
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
