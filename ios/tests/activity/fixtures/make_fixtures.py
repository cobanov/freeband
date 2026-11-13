#!/usr/bin/env python3
"""Regenerates the activity-file fixtures next to this script.

Stdlib only, and deliberately independent of activity_ref.py: every byte here is
packed straight from the layouts in docs/ACTIVITY.md, so the selftest compares two
separate implementations.

Two kinds of fixture come out:

* gb_*.json: test vectors taken from the vendored Gadgetbridge test tree (commit
  d4bd8367). Captured device bytes are copied as data; where Gadgetbridge builds its
  input in memory (DailySummaryParserTest) the same bytes are rebuilt here. The
  expected values are the ones the Gadgetbridge test asserts.
* synthetic.json: files built from the spec for the kinds Gadgetbridge has no test
  data for (daily details, sleep details, sleep stages, manual samples v2), plus
  chunking, CRC, id-list and ordering cases. Expected values are the values that
  were packed, not parser output.

    python3 make_fixtures.py [GADGETBRIDGE_ROOT]
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_GB = os.path.normpath(os.path.join(HERE, "../../../../vendor/Gadgetbridge"))
T = "app/src/test/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/activity/"


def crc(data: bytes) -> bytes:
    return struct.pack("<I", binascii.crc32(data) & 0xFFFFFFFF)


def file_id(ts: int, tz: int, version: int, type_: int, subtype: int, detail: int) -> bytes:
    return struct.pack("<IbBB", ts, tz, version, (type_ << 7) | (subtype << 2) | detail)


def with_crc(body: bytes) -> bytes:
    return body + crc(body)


def write(name: str, source: str, cases: list[dict]):
    path = os.path.join(HERE, name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"source": source, "cases": cases}, fh, indent=1)
        fh.write("\n")
    print(f"wrote {path} ({len(cases)} cases)")


# ---------------------------------------------------------------------------
# Gadgetbridge: XiaomiActivityFileIdTest


def gb_fileid() -> list[dict]:
    src = T + "XiaomiActivityFileIdTest.java"
    return [
        {"name": "decode SPORTS/FREESTYLE/DETAILS v3", "kind": "fileid", "hex": "21F328650403A0",
         "ref": src + ":49-60",
         "expect": {"ts": 1697182497, "tz_quarters": 4, "version": 3, "type": 1, "subtype": 8,
                    "detail": 0, "subtype_name": "freestyle", "detail_name": "details"}},
        {"name": "decode second id of the decode/encode pair", "kind": "fileid", "hex": "21F3286504008C",
         "ref": src + ":36, :62-83 (testEncode passes out-of-range constructor args; only the "
                      "decoded fields and the byte round trip are checked here)",
         "expect": {"ts": 1697182497, "tz_quarters": 4, "version": 0, "type": 1, "subtype": 3,
                    "detail": 0, "subtype_name": "treadmill"}},
        {"name": "all-zero id is a placeholder", "kind": "fileid", "hex": "00000000000000",
         "ref": src + ":85-89",
         "expect": {"ts": 0, "version": 0, "is_empty": True}},
        {"name": "decode/encode list of two ids", "kind": "idlist", "hex": "21F328650403A021F3286504008C",
         "ref": src + ":62-83",
         "expect": [{"hex": "21f328650403a0"}, {"hex": "21f3286504008c"}]},
    ]


# ---------------------------------------------------------------------------
# Gadgetbridge: ManualSamplesParserTest (captured Mi Band 9 Active packets, version 1)


def gb_manual_v1() -> list[dict]:
    src = T + "impl/ManualSamplesParserTest.java"
    spo2 = "EFB9856AF4011800FFEFB9856A0261511E4648"
    s40 = "65C0856AF4011800FF65C0856A03288CA20578"
    s27 = "D1C3856AF4011800FFD1C3856A031BFBF91375"

    def mutate(hexstr: str, index: int, value: int) -> str:
        b = bytearray(bytes.fromhex(hexstr))[:-4]
        b[index] = value
        return with_crc(bytes(b)).hex()

    return [
        {"name": "v1 SpO2 97", "kind": "file", "hex": spo2, "ref": src + ":34, :38-47",
         "expect": {"kind": "manual_samples", "crc": {"ok": True},
                    "file_id": {"version": 1, "tz_quarters": -12, "subtype": 6, "detail": 0},
                    "data": {"samples": [{"ts": 1787148783, "type": 0x12, "value": 97}]}}},
        {"name": "v1 stress 40", "kind": "file", "hex": s40, "ref": src + ":35, :49-57",
         "expect": {"data": {"samples": [{"type": 0x13, "value": 40}]}}},
        {"name": "v1 stress 27", "kind": "file", "hex": s27, "ref": src + ":36, :59-62",
         "expect": {"data": {"samples": [{"type": 0x13, "value": 27}]}}},
        {"name": "v1 rejects header byte != 0xff (CRC recomputed after the mutation)", "kind": "file",
         "hex": mutate(spo2, 8, 0x00), "ref": src + ":65-71", "expect_error": True},
        {"name": "v1 rejects unknown type 0x04 (CRC recomputed)", "kind": "file",
         "hex": mutate(spo2, 13, 0x04), "ref": src + ":73-79", "expect_error": True},
        {"name": "v1 rejects value 101 (CRC recomputed)", "kind": "file",
         "hex": mutate(spo2, 14, 101), "ref": src + ":81-87", "expect_error": True},
    ]


# ---------------------------------------------------------------------------
# Gadgetbridge: DailySummaryParserTest (inputs rebuilt byte for byte; no CRC in those inputs)

DS_TS, DS_TZ = 1_700_000_000, 4


def ds_file(version: int, bitmap: bytes, body: bytes) -> str:
    return (file_id(DS_TS, DS_TZ, version, 0, 0, 1) + b"\x00" + bitmap + body).hex()


def ds_body_v5() -> bytes:
    return b"".join([
        struct.pack("<I", 12345), struct.pack("<H", 250), bytes([75, 60, 180]),
        struct.pack("<I", 1700001000), bytes([55]), struct.pack("<I", 1700002000),
        bytes([80, 40, 90, 10]), bytes([1, 1, 1]), struct.pack("<HH", 2200, 480),
        bytes([96, 99]), struct.pack("<I", 1700003000), bytes([92]), struct.pack("<I", 1700004000),
        bytes([95]), struct.pack("<HH", 130, 700), bytes([2, 5, 25, 40]), struct.pack("<H", 280),
        bytes([3, 30]), struct.pack("<HH", 7, 65),
    ])


DS_ALL_V3 = {
    "steps": 12345, "active_calories": 250, "hr_resting": 60, "hr_max": 180, "hr_max_ts": 1700001000,
    "hr_min": 55, "hr_min_ts": 1700002000, "hr_avg": 80, "stress_avg": 40, "stress_max": 90,
    "stress_min": 10, "standing": 0x010101, "calories": 2200, "recovery_hours": 480, "spo2_max": 99,
    "spo2_max_ts": 1700003000, "spo2_min": 92, "spo2_min_ts": 1700004000, "spo2_avg": 95,
}
DS_V5_ONLY = {
    "training_load_day": 130, "training_load_week": 700, "training_load_level": 2,
    "vitality_light": 5, "vitality_moderate": 25, "vitality_high": 40, "vitality_current": 280,
}


def gb_daily_summary() -> list[dict]:
    src = T + "impl/DailySummaryParserTest.java"
    v5, v3 = ds_body_v5(), ds_body_v5()[:41]
    assert len(v5) == 57
    nulls = lambda keys: {k: None for k in keys}
    cases = [
        {"name": "v5 all bits set", "kind": "file", "has_crc": False, "ref": src + ":112-146",
         "hex": ds_file(5, b"\xff" * 4, v5),
         "expect": {"kind": "daily_summary", "data": {**DS_ALL_V3, **DS_V5_ONLY}}},
        {"name": "v5 no bits set", "kind": "file", "has_crc": False, "ref": src + ":148-170",
         "hex": ds_file(5, bytes(4), b"\xff" * 57),
         "expect": {"data": nulls(["steps", "active_calories", "hr_resting", "hr_max", "hr_max_ts",
                                   "standing", "calories", "recovery_hours", "training_load_day",
                                   "vitality_light", "vitality_moderate", "vitality_high",
                                   "vitality_current"])}},
        {"name": "v5 partial vitality", "kind": "file", "has_crc": False, "ref": src + ":177-202",
         "hex": ds_file(5, bytes([0x80, 0, 0, 0x10]), v5),
         "expect": {"data": {"steps": 12345, "vitality_current": 280, "vitality_light": None,
                             "vitality_moderate": None, "vitality_high": None,
                             "active_calories": None, "hr_max": None, "calories": None}}},
    ]
    probes = {0: ("steps", "active_calories"), 7: ("hr_min_ts", "hr_min"),
              8: ("hr_avg", "hr_min_ts"), 23: ("training_load_level", "training_load_week")}
    for slot, (on, off) in probes.items():
        bm = bytearray(4)
        bm[slot // 8] = 0x80 >> (slot % 8)
        value = {**DS_ALL_V3, **DS_V5_ONLY}[on]
        cases.append({"name": f"v5 bitmap MSB-first, slot {slot}", "kind": "file", "has_crc": False,
                      "ref": src + ":208-229", "hex": ds_file(5, bytes(bm), v5),
                      "expect": {"data": {on: value, off: None}}})
    le = bytearray(57)
    le[0:4] = b"\x01\x02\x03\x04"
    off27 = 4 + 2 + 1 + 1 + 1 + 4 + 1 + 4 + 1 + 1 + 1 + 1 + 3 + 2 + 2 + 1 + 1 + 4 + 1 + 4 + 1 + 2 + 2 + 1 + 1 + 1 + 1
    le[off27:off27 + 2] = b"\x02\x01"
    stand = bytearray(57)
    stand[22:25] = b"\xaa\xbb\xcc"
    cases += [
        {"name": "v5 multi-byte fields are little-endian", "kind": "file", "has_crc": False,
         "ref": src + ":232-249", "hex": ds_file(5, bytes([0x80, 0, 0, 0x10]), bytes(le)),
         "expect": {"data": {"steps": 0x04030201, "vitality_current": 0x0102}}},
        {"name": "v5 standing packs 3 bytes LE", "kind": "file", "has_crc": False,
         "ref": src + ":252-268", "hex": ds_file(5, bytes([0, 0x08, 0, 0]), bytes(stand)),
         "expect": {"data": {"standing": 0xCCBBAA}}},
        {"name": "unsupported version 99", "kind": "file", "has_crc": False, "ref": src + ":271-278",
         "hex": (file_id(DS_TS, DS_TZ, 99, 0, 0, 1) + b"\x00").hex(), "expect_error": True},
        {"name": "v3 all bits set", "kind": "file", "has_crc": False, "ref": src + ":285-320",
         "hex": ds_file(3, b"\xff" * 3, v3),
         "expect": {"data": {**DS_ALL_V3, **nulls(DS_V5_ONLY)}}},
        {"name": "v3 no bits set", "kind": "file", "has_crc": False, "ref": src + ":323-341",
         "hex": ds_file(3, bytes(3), b"\xff" * 41),
         "expect": {"data": nulls(["steps", "active_calories", "hr_resting", "hr_max", "hr_max_ts",
                                   "standing", "calories", "recovery_hours", "spo2_avg"])}},
        {"name": "v3 only hr_max valid", "kind": "file", "has_crc": False, "ref": src + ":344-364",
         "hex": ds_file(3, bytes([0x08, 0, 0]), v3),
         "expect": {"data": {"hr_max": 180, **nulls(["steps", "active_calories", "hr_resting",
                                                      "hr_max_ts", "hr_min", "hr_avg", "standing",
                                                      "calories", "spo2_avg"])}}},
    ]
    return cases


# ---------------------------------------------------------------------------
# Gadgetbridge: WorkoutSummaryParserTest (captured SUMMARY files and the values it asserts)

WORKOUT_SUBTYPES = {"TREADMILL": 0x03, "ROWING": 0x0D, "FREESTYLE": 0x08, "OUTDOOR_CYCLING": 0x17,
                    "OUTDOOR_RUN": 0x16, "WALKING": 0x16, "INDOOR_CYCLING": 0x07, "ELLIPTICAL": 0x0B}


def workout_blobs(gb_root: str) -> list[tuple[str, int, str, bytes]]:
    path = os.path.join(gb_root, T, "impl/WorkoutSummaryParserTest.java")
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    text = "\n".join(lines)
    out = []
    for m in re.finditer(r'private static final String (\w+) =\s*((?:"[^"]*"\s*\+?\s*)+);', text):
        line = text.count("\n", 0, m.start()) + 1
        comment = ""
        for back in range(line - 2, max(line - 5, 0), -1):  # nearest javadoc above
            if "/**" in lines[back]:
                comment = " ".join(l.strip(" /*") for l in lines[back:line - 1]).strip()
                break
        out.append((m.group(1), line, comment, base64.b64decode("".join(re.findall(r'"([^"]*)"', m.group(2))))))
    return out


# What WorkoutSummaryParserTest asserts for each blob, in activity_ref.py's field names
# (floats to two decimals, as the reference rounds them).
WORKOUT_EXPECT = {
    "TREADMILL_V11_24APR": {"sport": "treadmill", "distance_m": 4479, "te_aerobic": 4.2, "hr_avg": 167, "cadence_avg": 163,
                            "te_anaerobic": 1.8, "distance_calibrated_m": 4500, "load": 104, "vitality": 12},
    "TREADMILL_V9_21JUN": {"sport": "treadmill", "calories": 192, "distance_m": 2720, "steps": 3216, "hr_avg": 135,
                           "cadence_max": 180, "te_aerobic": 1.9, "recovery_h": 32, "load": 28, "vitality": 15},
    "ROWING_V7_20APR": {"sport": "rowing", "hr_avg": 142, "active_s": 2549, "strokes": 1208, "stroke_rate_avg": 28,
                        "te_aerobic": 3.4, "te_anaerobic": 0.4, "stroke_rate_max": 71, "recovery_h": 23, "load": 69,
                        "vitality": 0},
    "ROWING_V7_15APR": {"sport": "rowing", "te_anaerobic": 1.1, "te_aerobic": 3.5, "stroke_rate_max": 41},
    "ROWING_V8_22AUG": {"sport": "rowing", "active_s": 147, "hr_avg": 129, "hr_max": 145, "hr_min": 106, "strokes": 46,
                        "stroke_rate_avg": 18, "stroke_rate_max": 27, "load": 2},
    "FREESTYLE_V10_FRISBEE": {"sport": "freestyle", "workout_type": 807, "te_anaerobic": 2.6, "te_aerobic": 4.0},
    "OUTDOOR_CYCLING_V8_23SEP": {"sport": "outdoor_cycling", "active_s": 1579, "distance_m": 5282, "total_calories": 166,
                                 "calories": 127, "pace_max": 76, "pace_min": 1036, "speed_avg": 12.04,
                                 "speed_max": 46.93, "hr_avg": 133, "hr_max": 168, "hr_min": 80, "te_aerobic": 2.3,
                                 "te_anaerobic": 0.8, "recovery_h": 13, "zone_anaerobic_s": 95, "zone_aerobic_s": 814,
                                 "zone_fat_burn_s": 340, "zone_warm_up_s": 283, "load": 28, "vitality": 7},
    "OUTDOOR_CYCLING_V6_23MAY": {"sport": "outdoor_cycling", "distance_m": 11982, "total_calories": 538, "calories": 439,
                                 "pace_max": 104, "speed_max": 34.48, "zone_aerobic_s": 10, "zone_fat_burn_s": 97,
                                 "zone_warm_up_s": 1110, "load": 5},
    "OUTDOOR_RUN_V5_30SEP": {"sport": "outdoor_running", "active_s": 1704, "distance_m": 4189, "hr_min": 119,
                             "hr_max": 200, "hr_avg": 162, "pace_max": 395, "pace_min": 782, "cadence_max": 178},
    "WALKING_V6_29MAY": {"sport": "walking", "active_s": 1912, "hr_min": 131, "hr_max": 192, "hr_avg": 149},
    "WALKING_V9_04JAN": {"sport": "walking", "hr_min": 99, "hr_max": 163, "hr_avg": 135, "load": 28, "vitality": 10},
    "INDOOR_CYCLING_V9_22FEB": {"sport": "indoor_cycling", "hr_min": 94, "hr_max": 150, "hr_avg": 135},
    "ELLIPTICAL_V6_10FEB": {"sport": "elliptical", "hr_min": 118, "hr_max": 156, "hr_avg": 147, "total_calories": 774,
                            "te_anaerobic": 0.3, "load": 96, "vitality": 3},
}


MONTHS = {m: i + 1 for i, m in enumerate("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC".split())}


def gb_workouts(blobs) -> list[dict]:
    src = T + "impl/WorkoutSummaryParserTest.java"
    cases = []
    for name, line, comment, data in blobs:
        sport, version, day = re.match(r"([A-Z_]+?)_V(\d+)_?(\d\d[A-Z]{3})?", name).groups()
        ts, tz = struct.unpack_from("<Ib", data)
        expect = {"kind": "workout_summary", "crc": {"ok": True},
                  "file_id": {"type": 1, "subtype": WORKOUT_SUBTYPES[sport], "detail": 1,
                              "version": int(version)}}
        if day:  # the date in the constant's name is the local date of the workout
            year = re.search(r"20\d\d", comment)
            if year:
                expect["file_id"]["local_date"] = f"{year.group(0)}-{MONTHS[day[2:]]:02d}-{int(day[:2]):02d}"
        if name in WORKOUT_EXPECT:
            expect["data"] = WORKOUT_EXPECT[name]
        cases.append({"name": f"workout summary {name}", "kind": "file", "hex": data.hex(),
                      "ref": f"{src}:{line}", "note": comment, "expect": expect})
    return cases


# ---------------------------------------------------------------------------
# synthetic: daily details

def dd_v4() -> dict:
    ts, tz = 1760389200, 12  # 2025-10-14 00:00 at UTC+3
    # nibbles g0..g10 = F E 8 C C C 8 C C C C, nibble 11 unused
    header = bytes.fromhex("FE8CCC8CCCC0")
    rows = [
        # g0 (bit15, extra, steps), g1 (top2, cal), g2, dist, hr, energy, g6, spo2, stress, extra?, light, momentum
        (0, 0, 12, 0, 3, 0x00, 9, 72, 65, 0, 97, 30, None, 120, 5),
        (0, 1, 16383, 2, 63, 0x7F, 1234, 180, 64, 0xBEEF, 0, 255, 0xAB, 0, 0xFFFF),
        (1, 0, 0, 0, 0, 0x00, 0, 0, 63, 0, 98, 0, None, 7, 1),
    ]
    body = b""
    for b15, extra, steps, top2, cal, g2, dist, hr, energy, g6, spo2, stress, xb, light, mom in rows:
        body += struct.pack("<H", (b15 << 15) | (extra << 14) | steps)
        body += bytes([(top2 << 6) | cal, g2]) + struct.pack("<H", dist) + bytes([hr, energy])
        body += struct.pack("<H", g6) + bytes([spo2, stress])
        if extra:
            body += bytes([xb])
        body += struct.pack("<HH", light, mom)
    data = with_crc(file_id(ts, tz, 4, 0, 0, 0) + b"\x00" + header + body)
    return {"name": "daily details v4, every group present, extra byte in record 1",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "daily_details", "crc": {"ok": True}, "data": {"header_hex": header.hex(), "records": [
                {"ts": ts, "steps": 12, "active_calories": 3, "distance_m": 9, "heart_rate": 72, "energy": 65,
                 "spo2": 97, "stress": 30, "light_raw": 120, "body_momentum_raw": 5},
                {"ts": ts + 60, "steps": 16383, "active_calories": 63, "distance_m": 1234, "heart_rate": 180,
                 "energy": 64, "spo2": 0, "stress": None, "extra_byte": 0xAB, "light_raw": 0,
                 "body_momentum_raw": 0xFFFF},
                {"ts": ts + 120, "steps": 0, "active_calories": 0, "distance_m": 0, "heart_rate": 0, "energy": 63,
                 "spo2": 98, "stress": 0, "light_raw": 7, "body_momentum_raw": 1},
            ]}}}


def dd_v2() -> dict:
    ts, tz = 1760389200, 12
    # g0 B (present, slot0 invalid, extra+steps valid), g1 A (present, calories valid), g2 0 (absent),
    # g3 C, g4 C, g5 8 (present but invalid), g6 0 (absent), nibble 7 unused
    header = bytes.fromhex("BA0CC800")
    body = b""
    body += struct.pack("<H", 100) + bytes([5]) + struct.pack("<H", 80) + bytes([95, 0x55])
    body += struct.pack("<H", (1 << 14) | 0) + bytes([0]) + struct.pack("<H", 0) + bytes([0, 0]) + bytes([0x01])
    data = with_crc(file_id(ts, tz, 2, 0, 0, 0) + b"\x00" + header + body)
    return {"name": "daily details v2, absent groups take no bytes, invalid group still consumed",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "daily_details", "data": {"records": [
                {"ts": ts, "steps": 100, "active_calories": 5, "distance_m": 80, "heart_rate": 95,
                 "energy": None, "spo2": None, "stress": None},
                {"ts": ts + 60, "steps": 0, "active_calories": 0, "distance_m": 0, "heart_rate": 0,
                 "energy": None, "extra_byte": 1},
            ]}}}


def dd_v3_tail() -> dict:
    ts, tz = 1760475600, 12
    header = bytes.fromhex("FE8CCC8CC0")
    rec = struct.pack("<H", 42) + bytes([7, 0]) + struct.pack("<H", 30) + bytes([88, 50])
    rec += struct.pack("<H", 0) + bytes([95, 45])
    data = with_crc(file_id(ts, tz, 3, 0, 0, 0) + b"\x00" + header + rec + b"\x01\x02\x03")
    return {"name": "daily details v3, 3 stray bytes after the last whole record",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"data": {"truncated_tail": 3, "records": [
                {"ts": ts, "steps": 42, "active_calories": 7, "distance_m": 30, "heart_rate": 88,
                 "energy": 50, "spo2": 95, "stress": 45}]}}}


# ---------------------------------------------------------------------------
# synthetic: sleep details

def stage_packet(ptype: int, ts: int, payload: bytes = b"", parity: int = 0, length: int | None = None) -> bytes:
    n = len(payload) if length is None else length
    return b"\xfb\xfa\xfc\xff" + bytes([17]) + struct.pack("<q", ts) + bytes([parity, ptype]) + struct.pack(">H", n) + payload


def stage_words(pairs) -> bytes:
    return b"".join(struct.pack(">H", (code << 12) | minutes) for code, minutes in pairs)


def sd_v5() -> dict:
    bed = 1760469600  # 2025-10-14T19:20:00Z
    wake = bed + 140 * 60
    bitmap = bytes([0xFF, 0xE0])  # idx 0..8 set, 9 HR, 10 SpO2, 11 snore clear
    body = bytes([1]) + struct.pack("<II", bed, wake) + bytes([78])
    body += bytes(range(1, 10)) + struct.pack("<II", bed - 1800, wake)
    body += struct.pack("<HHI", 60, 3, bed) + bytes([58, 55, 60])
    body += struct.pack("<HHI", 300, 2, bed + 600) + bytes([96, 95])
    body += b"\x00\x11"  # junk before the first packet
    body += stage_packet(2, bed, length=5)  # fall asleep: no payload, "length" is flags
    body += stage_packet(17, bed, stage_words([(1, 30), (2, 45), (3, 20), (0, 5), (1, 40)]), parity=1)
    body += stage_packet(16, bed, bytes([0x12]) + struct.pack(">HHHHH", 135, 5, 70, 20, 45) + bytes([0x10, 3]))
    body += stage_packet(1, bed * 1000, bytes([100, 98, 102, 95]))
    data = with_crc(file_id(bed + 600, 12, 5, 0, 8, 1) + b"\x00" + bitmap + body)
    return {"name": "sleep details v5 (SUMMARY), HR+SpO2 blocks, stage/summary/RR packets",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_details", "crc": {"ok": True}, "data": {
                "is_awake": 1, "bed_time": bed, "wakeup_time": wake, "sleep_quality": 78,
                "bed_time2": bed - 1800, "wakeup_time2": wake,
                "hr": {"unit": 60, "count": 3, "first_ts": bed, "values": [58, 55, 60]},
                "spo2": {"unit": 300, "count": 2, "first_ts": bed + 600, "values": [96, 95]},
                "snore": None, "skipped_bytes": 2, "trailing_bytes": 0,
                "packets": [{"type": 2, "flags": 5}, {"type": 17, "parity": 1}, {"type": 16}, {"type": 1}],
                "stages": [
                    {"ts": bed, "stage": "light", "duration_min": 30},
                    {"ts": bed + 1800, "stage": "deep", "duration_min": 45},
                    {"ts": bed + 4500, "stage": "rem", "duration_min": 20},
                    {"ts": bed + 5700, "stage": "awake", "duration_min": 5},
                    {"ts": bed + 6000, "stage": "light", "duration_min": 40}],
                "summaries": [{"sleep_index": 1, "wake_count": 2, "sleep_min": 135, "awake_min": 5,
                               "light_min": 70, "rem_min": 20, "deep_min": 45, "flags": 0x10,
                               "unknown_min": 3}],
                "rr": [{"ts_raw": bed * 1000, "rr_ms": [1000, 980, 1020, 950]}]}}}


def sd_v5_breath() -> dict:
    """Type-10 packets (docs/ACTIVITY.md 6.3.2): 4-byte records with breaths per minute in byte 1,
    ts in nanoseconds, each packet's records spread evenly over the 10 minutes before its ts."""
    bed = 1760469600
    wake = bed + 3600
    ns = 10**9
    bitmap = bytes([0xFF, 0x80])  # idx 0..8 set; no HR, SpO2 or snore block
    body = bytes([1]) + struct.pack("<II", bed, wake) + bytes([80])
    body += bytes(9) + struct.pack("<II", bed - 1800, wake)
    body += stage_packet(101, bed * 1000, bytes([1, 2, 7, 4]))
    # 3 records at 150, 300 and 450 s into the window; the middle one has no reading
    body += stage_packet(10, (bed + 600) * ns, bytes([120, 14, 77, 0, 90, 0, 60, 16, 131, 16, 80, 32]))
    body += stage_packet(11, (bed + 600) * ns, bytes([5, 6]))  # unknown type: payload kept raw
    # 1 record, 41 is out of range; the fifth byte is not a whole record
    body += stage_packet(10, (bed + 1200) * ns + 999, bytes([100, 41, 50, 0, 9]))
    # 2 records at 200 and 400 s, the lowest and highest accepted values
    body += stage_packet(10, (bed + 1800) * ns, bytes([0, 1, 0, 0, 0, 40, 0, 1]))
    data = with_crc(file_id(wake, 12, 5, 0, 8, 1) + b"\x00" + bitmap + body)
    return {"name": "sleep details v5, breathing rate in type-10 packets",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_details", "crc": {"ok": True}, "data": {
                "bed_time": bed, "wakeup_time": wake, "sleep_quality": 80, "hr": None, "spo2": None,
                "skipped_bytes": 0, "trailing_bytes": 0,
                "packets": [{"type": 101, "payload_hex": "01020704"},
                            {"type": 10, "length": 12, "payload_hex": "780e4d005a003c1083105020"},
                            {"type": 11, "payload_hex": "0506"},
                            {"type": 10, "length": 5}, {"type": 10, "length": 8}],
                "respiratory": [{"ts": bed + 150, "brpm": 14}, {"ts": bed + 450, "brpm": 16},
                                {"ts": bed + 1400, "brpm": 1}, {"ts": bed + 1600, "brpm": 40}],
                "rr": [], "stages": [], "summaries": []}}}


def sd_v6_body(bed: int, wake: int, snore_block: bool = True) -> bytes:
    """Shaped like the Band 10 Pro v6 file of 2026-10-14 (values made up): 3-byte bitmap, the v5
    fields, 24 unknown bytes, HR/SpO2 blocks with 0 for "no reading", u16 snore samples, then a
    stream that sends the night twice (an interim 16/17 pair and the final one, same ts)."""
    bitmap = bytes([0xDF, 0xFF, 0xFC])
    body = bitmap + bytes([1]) + struct.pack("<II", bed, wake) + bytes([0])
    body += bytes([0x4E]) + struct.pack("<II", 1020, wake - bed + 1020) + struct.pack("<II", bed - 1020, wake)
    body += bytes(range(0x20, 0x38))  # 24 unknown bytes
    body += struct.pack("<HHI", 60, 5, bed + 180) + bytes([62, 0, 0, 64, 0])
    body += struct.pack("<HHI", 60, 5, bed + 180) + bytes([0, 0, 96, 0, 97])
    if snore_block:
        body += struct.pack("<HHI", 600, 2, bed + 720) + struct.pack("<HH", 57, 45)
    body += stage_packet(101, bed * 1000, bytes([1, 3, 1, 0x20]), parity=1)
    body += stage_packet(19, bed * 1000, length=1, parity=1)
    body += stage_packet(20, bed * 1000, parity=1)
    body += stage_packet(18, (bed - 1000) * 10**9, length=1)
    body += stage_packet(2, bed * 1000)
    body += stage_packet(3, (bed + 7200) * 1000, length=1)
    body += stage_packet(16, bed, bytes([0x10]) + struct.pack(">HHHHH", 100, 0, 80, 5, 15) + bytes([0x15, 0]))
    body += stage_packet(17, bed, stage_words([(1, 60), (2, 15), (3, 5), (1, 20)]))
    body += stage_packet(3, wake * 1000, length=6)
    body += stage_packet(16, bed, bytes([0x11]) + struct.pack(">HHHHH", 160, 20, 115, 15, 30) + bytes([0x16, 0]))
    body += stage_packet(17, bed, stage_words([(1, 60), (2, 15), (3, 5), (1, 35), (0, 20), (2, 15), (3, 10)]))
    return body


def sd_v6() -> dict:
    bed = 1791850000
    wake = bed + 180 * 60
    data = with_crc(file_id(bed, 12, 6, 0, 8, 1) + b"\x00" + sd_v6_body(bed, wake))
    first = [(bed, "light", 60), (bed + 3600, "deep", 15), (bed + 4500, "rem", 5), (bed + 4800, "light", 20)]
    final = [(bed, "light", 60), (bed + 3600, "deep", 15), (bed + 4500, "rem", 5), (bed + 4800, "light", 35),
             (bed + 6900, "awake", 20), (bed + 8100, "deep", 15), (bed + 9000, "rem", 10)]
    return {"name": "sleep details v6 (Band 10 Pro shape): 3-byte bitmap, 24 unknown bytes, u16 snore, night sent twice",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_details", "crc": {"ok": True}, "data": {
                "is_awake": 1, "bed_time": bed, "wakeup_time": wake, "sleep_quality": 0,
                "bed_time2": bed - 1020, "wakeup_time2": wake, "v6_unknown_hex": bytes(range(0x20, 0x38)).hex(),
                "hr": {"unit": 60, "count": 5, "first_ts": bed + 180, "values": [62, 0, 0, 64, 0]},
                "spo2": {"unit": 60, "count": 5, "first_ts": bed + 180, "values": [0, 0, 96, 0, 97]},
                "snore": {"unit": 600, "count": 2, "first_ts": bed + 720, "values": [57, 45]},
                "skipped_bytes": 0, "trailing_bytes": 0,
                "packets": [{"type": 101, "length": 4}, {"type": 19, "flags": 1}, {"type": 20, "length": 0},
                            {"type": 18, "flags": 1}, {"type": 2, "flags": 0}, {"type": 3, "flags": 1},
                            {"type": 16}, {"type": 17}, {"type": 3, "flags": 6}, {"type": 16}, {"type": 17}],
                "stages": [{"ts": t, "stage": st, "duration_min": m} for t, st, m in first + final],
                "summaries": [{"sleep_index": 1, "wake_count": 0, "sleep_min": 100, "awake_min": 0},
                              {"sleep_index": 1, "wake_count": 1, "sleep_min": 160, "awake_min": 20,
                               "light_min": 115, "rem_min": 15, "deep_min": 30, "flags": 0x16}]}}}


def sd_v6_misaligned() -> dict:
    bed = 1791850000
    wake = bed + 180 * 60
    data = with_crc(file_id(bed, 12, 6, 0, 8, 1) + b"\x00" + sd_v6_body(bed, wake, snore_block=False))
    return {"name": "sleep details v6, snore bit set but no snore block: blocks dropped, stream kept",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_details", "data": {
                "bed_time": bed, "hr": None, "spo2": None, "snore": None, "blocks_error": "",
                "summaries": [{"sleep_min": 100}, {"sleep_min": 160}]}}}


def ds_v5_short() -> dict:
    v5 = ds_body_v5()[:53]  # slots 0..29, as a Band 10 Pro sends them
    data = with_crc(file_id(1791838800, 12, 5, 0, 0, 1) + b"\x00" + bytes([0xFF, 0xFF, 0xFF, 0xFC]) + v5)
    return {"name": "daily summary v5 ending after slot 29 (Band 10 Pro), slots 30-31 absent",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "daily_summary", "crc": {"ok": True}, "data": {**DS_ALL_V3, **DS_V5_ONLY}}}


def sd_v2() -> dict:
    bed = 1760380000
    wake = bed + 110 * 60
    bitmap = bytes([0xF0])  # idx 0..2, 3 = HR valid, 4 = SpO2 clear
    body = bytes([0]) + struct.pack("<II", bed, wake)
    body += struct.pack("<HH", 60, 0)  # HR block with zero samples: no first-ts field
    body += stage_packet(17, bed, stage_words([(2, 50), (1, 60)]))
    data = with_crc(file_id(bed, 12, 2, 0, 8, 0) + b"\x00" + bitmap + body)
    return {"name": "sleep details v2 (DETAILS), empty HR block, two stages",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_details", "data": {
                "is_awake": 0, "bed_time": bed, "wakeup_time": wake, "sleep_quality": None,
                "hr": {"unit": 60, "count": 0, "first_ts": None, "values": []}, "spo2": None, "snore": None,
                "stages": [{"ts": bed, "stage": "deep", "duration_min": 50},
                           {"ts": bed + 3000, "stage": "light", "duration_min": 60}]}}}


# ---------------------------------------------------------------------------
# synthetic: sleep stages, manual samples v2

def ss_v2(empty: bool = False) -> dict:
    bed = 0 if empty else 1760390000
    wake = 0 if empty else bed + 7 * 3600
    body = bytes.fromhex("FFFF1000050300") + struct.pack("<hII", 0 if empty else 420, bed, wake)
    body += bytes.fromhex("0A0100") + struct.pack("<hhhh", 90, 240, 70, 20) + bytes([7])
    phases = [] if empty else [(bed, 3), (bed + 3600, 2), (bed + 9000, 4), (bed + 10800, 3), (bed + 25000, 5)]
    for t, p in phases:
        body += struct.pack("<IB", t, p)
    data = with_crc(file_id(1760390000, 12, 2, 0, 3, 0) + b"\x00" + body)
    if empty:
        return {"name": "sleep stages v2 with no data (bed time 0)", "kind": "file", "hex": data.hex(),
                "synthetic": True, "expect": {"kind": "sleep_stages", "data": {"no_data": True, "stages": []}}}
    return {"name": "sleep stages v2, five phase changes", "kind": "file", "hex": data.hex(), "synthetic": True,
            "expect": {"kind": "sleep_stages", "data": {
                "total_min": 420, "bed_time": bed, "wakeup_time": wake, "deep_min": 90, "light_min": 240,
                "rem_min": 70, "awake_min": 20, "no_data": False,
                "stages": [{"ts": bed, "stage": "light", "raw": 3}, {"ts": bed + 3600, "stage": "deep", "raw": 2},
                           {"ts": bed + 9000, "stage": "rem", "raw": 4}, {"ts": bed + 10800, "stage": "light", "raw": 3},
                           {"ts": bed + 25000, "stage": "awake", "raw": 5}]}}}


def ms_v2() -> dict:
    # the record bytes are the example in ManualSamplesParser.java:72-77; id, pad and CRC are synthetic
    records = bytes.fromhex("8A90A9651263" "C793A9651300" "9698A965131C" "E79CA965445A0E0000" "729FA96544590E0000")
    data = with_crc(file_id(0x65A99000, 4, 2, 0, 6, 0) + b"\x00" + records)
    return {"name": "manual samples v2 (records from the ManualSamplesParser source comment)",
            "kind": "file", "hex": data.hex(), "synthetic": True,
            "ref": "app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/activity/impl/ManualSamplesParser.java:71-77",
            "expect": {"kind": "manual_samples", "data": {"zero_value_records": 1, "samples": [
                {"ts": 0x65A9908A, "type": 0x12, "value": 0x63},
                {"ts": 0x65A99896, "type": 0x13, "value": 0x1C},
                {"ts": 0x65A99CE7, "type": 0x44, "value": 0x0E5A, "celsius": 36.74},
                {"ts": 0x65A99F72, "type": 0x44, "value": 0x0E59, "celsius": 36.73}]}}}


# ---------------------------------------------------------------------------
# synthetic: transport-level cases


def chunk(total: int, index: int, part: bytes) -> str:
    return (struct.pack("<HH", total, index) + part).hex()


def transport_cases(blobs) -> list[dict]:
    name, _, _, real = next(b for b in blobs if b[0] == "TREADMILL_V9_21JUN")
    parts = [real[0:120], real[120:240], real[240:]]
    good = [chunk(3, i + 1, p) for i, p in enumerate(parts)]
    bad = bytearray(parts[1])
    bad[5] ^= 0x01
    small = with_crc(file_id(1760389200, 12, 1, 0, 6, 0) + b"\x00" + bytes.fromhex("FF") + struct.pack("<IBB", 1760390000, 2, 98))
    ids = [file_id(1760389200, 12, 4, 0, 0, d).hex() for d in (0, 1, 2)]
    other = file_id(1760389100, 12, 5, 0, 8, 1).hex()
    return [
        {"name": "CRC-32 check value of '123456789'", "kind": "crc", "hex": b"123456789".hex(), "expect": "cbf43926"},
        {"name": f"reassemble real {name} from 3 chunks", "kind": "chunks", "chunks": good,
         "expect_file_hex": real.hex(), "expect": {"crc": {"ok": True}, "file_id": {"version": 9}}},
        {"name": "flipped bit in chunk 2 fails the CRC", "kind": "chunks",
         "chunks": [good[0], chunk(3, 2, bytes(bad)), good[2]], "expect_crc_ok": False},
        {"name": "chunk 3 before chunk 2 is rejected", "kind": "chunks",
         "chunks": [good[0], good[2], good[1]], "expect_error": True},
        {"name": "single-chunk file (total 1)", "kind": "chunks", "chunks": [chunk(1, 1, small)],
         "expect": {"kind": "manual_samples", "data": {"samples": [{"ts": 1760390000, "value": 98}]}}},
        {"name": "id list drops the all-zero placeholder", "kind": "idlist",
         "hex": ids[0] + "00000000000000" + other, "expect": [{"hex": ids[0]}, {"hex": other}]},
        {"name": "fetch order: time first, then summary < details < gps", "kind": "fetch_order",
         "ids": [ids[2], ids[0], ids[1], other], "expect": [other, ids[1], ids[0], ids[2]]},
    ]


def main(argv):
    gb_root = argv[1] if len(argv) > 1 else DEFAULT_GB
    blobs = workout_blobs(gb_root)
    write("gb_fileid.json", "Gadgetbridge d4bd8367 " + T + "XiaomiActivityFileIdTest.java", gb_fileid())
    write("gb_manual_samples_v1.json",
          "Gadgetbridge d4bd8367 " + T + "impl/ManualSamplesParserTest.java (captured Mi Band 9 Active packets)",
          gb_manual_v1())
    write("gb_daily_summary.json",
          "Gadgetbridge d4bd8367 " + T + "impl/DailySummaryParserTest.java (Gadgetbridge's own synthetic inputs, "
          "rebuilt byte for byte; they carry no CRC trailer)", gb_daily_summary())
    write("gb_workout_summary_blobs.json",
          "Gadgetbridge d4bd8367 " + T + "impl/WorkoutSummaryParserTest.java (captured SUMMARY files with the "
          "values that test asserts)", gb_workouts(blobs))
    write("synthetic.json", "SYNTHETIC: built by make_fixtures.py from docs/ACTIVITY.md; not device data",
          [dd_v4(), dd_v2(), dd_v3_tail(), sd_v5(), sd_v5_breath(), sd_v6(), sd_v6_misaligned(), sd_v2(), ss_v2(), ss_v2(empty=True),
           ds_v5_short(), ms_v2()]
          + transport_cases(blobs))


if __name__ == "__main__":
    main(sys.argv)
