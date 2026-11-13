# Sleep summary write-back (Fitness id 41, `SYNC_SLEEP_RESULT`)

The band records sleep but the vendor app computes the night's summary on the phone and writes it back to the band, so the band's own sleep screen can show it. This note says what that message holds and how Mi Fitness fills it. Freeband builds it (`MiAuth.sleepResultCommand`) and sends it once per night after the sync that brought the night, only while "Show sleep on the band" (Band › Connection and data) is on; it is off by default and marked experimental, because nothing here has been tried on a band yet.

Marks:

- **[AB]**: AstroBox proto, `AstroBox-NG-Module-Pb` commit `03a92010`, `protos/xiaomi/wear_fitness.proto` and `wear_common.proto`.
- **[MF]**: Mi Fitness for Android 9.8.348i (versionCode 908348), decompiled with jadx; class names are the obfuscated ones (`docs/MIFITNESS-2026-11-13.md`). Read only, never run.
- **[GB]**: Gadgetbridge master `83b2efe9` (2026-11-13).
- **[UNVERIFIED]**: inferred, or not seen anywhere.

## 1. The message

`Command{type 8, subtype 41}` with the Fitness payload in field 10, and inside it `sleep_result = 37`. [AB] `wear_fitness.proto:62`, `:148`; [MF] `SleepSegmentUtils.java:273-276` (`t1i.c = 8`, `t1i.d = 41`), `wn6.java:1119-1121` (field 37).

```
SleepResult {                         [AB] wear_fitness.proto:318-346
  repeated Section section_list = 1
  optional Animal  animal = 2 { type 1, current_progress 2, total_progress 3 }
}
Section {
  Timezone timezone             = 1   { offset 1, dst_saving 2, id 3, id_spec 4 }   [AB] wear_common.proto:545-550
  uint32   valid_sleep_time     = 2
  uint32   sleep_timestamp      = 3
  uint32   wakeup_timestamp     = 4
  uint32   average_heart_rate   = 5
  uint32   average_blood_oxygen = 6
  ExtraData extra_data          = 7   { bedtime 1, sleep_time 2, sleep_quality 3, sleep_efficiency 4, breathing 5 }
}
```

The proto gives names and numbers only; it has no comments and no units. Neither AstroBox Core nor Gadgetbridge sends or handles subtype 41. [AB], [GB] (`docs/SOURCES-2026-11-13.md` section 2)

## 2. What Mi Fitness puts in it

All from `com/xiaomi/fit/fitness/device/mi/parse/utils/SleepSegmentUtils.java` unless another file is named. [MF]

| Field | Value | Unit | Where |
|---|---|---|---|
| `timezone.offset` (1.1) | the report's `tzIn15Min`, which is the tz byte of the sleep file's id (`dataId.getTzIn15Min()`) | 15-minute blocks from UTC, DST included; **zigzag varint** | `:251-253`, `:114`; `cz2.java` writes field 1 with the zigzag writer (`CodedOutputByteBufferNano.i0`) |
| `timezone.dst_saving`, `id`, `id_spec` | not set, so not on the wire | | `cz2.java` writes 2-4 only when non-zero / non-empty |
| `valid_sleep_time` (2) | `sleepDuration * 60` | **seconds**; `sleepDuration` is minutes (`SleepShortSegmentViewHolder.java:139` passes it to `TimeUnit.MINUTES`) | `:254` |
| `sleep_timestamp` (3) | `bedTime` = the algorithm's `sleepIntoTs` (fell asleep) | Unix seconds | `:249`, `:85` |
| `wakeup_timestamp` (4) | `wakeupTime` = `sleepOutofTs` | Unix seconds | `:250`, `:85` |
| `average_heart_rate` (5) | mean heart rate between those two times; **0 when there is none** | bpm | `:255-262`, `:115-119` |
| `average_blood_oxygen` (6) | mean SpO2 between those two times; **0 when there is none** | percent | `:263-270`, `:120-124` |
| `extra_data` (7) | **never set** | | no code outside the message class builds `up6.b` |
| `animal` (SleepResult 2) | **never set** | | no code outside the message class builds `up6.a` |

- Fields 2-6 are always written, also when 0; field 7 and the timezone only when present. [MF] `up6.java`, `c.writeTo`
- The AstroBox proto types `Timezone.offset` as `int32`; Mi Fitness writes it zigzag, and Gadgetbridge's `TimeZone` is `sint32` too. They differ only for zones west of UTC. Freeband follows Mi Fitness. [AB] `wear_common.proto:546`, [MF], [GB] `GBProtobufGenerator/src/main/proto/xiaomi/wear_common.proto:23-28`
- The clock command (2/3) sends the standard offset in field 1 and DST in field 2. Here only field 1 goes out and it is the total offset, as the file id has it. [MF]
- **One section per sleep segment** (night or nap) with a non-zero duration (`:202`), sorted by bed time, oldest first (`Collections.sort`, `SleepSegmentReport.compareTo`, `:240`). The segments are the stored ones between two local midnights: today only, or the last 7 days when the device's capability has bit 32 set (`DEVICE_CAPABILITY_7_DAY_SLEEP`, `:51`, `:129-142`).
- Heart rate and SpO2 means are only computed for a segment that has stages (`:116`, `:121`).

### When it is sent

After every sync with the band finishes (`FitnessDeviceSyncManager.handleSpecialSyncResult`, `FitnessDeviceSyncManager.java:616-620`), on a background thread: [MF]

- 1-day device: only when that sync parsed a new all-day sleep file (`hasNewSleep`, reset at the start of each sync, `:626`); otherwise it logs "not write back" (`:133-136`).
- 7-day device: every sync.
- No stored sleep in the range: nothing is sent (`:236-239`).
- The reply is only logged (`onSuccess` / `onError` with a code, `:280-290`).

### Where `sleep_quality` and `breathing` would come from

Mi Fitness's sleep report has `breathQuality` and `avgBreathRate` (from the native sleep algorithm, `:89-100`), and they go to its own store and the cloud, not into this message. So what `ExtraData.sleep_quality`, `sleep_efficiency` and `breathing` carry, their units and ranges, and whether `bedtime` / `sleep_time` are timestamps or durations, is not known. [UNVERIFIED]

## 3. Freeband's builder

`MiAuth.sleepResultCommand(_ sections: [SleepResultSection]) -> Data` in `ios/Freeband/Band/MiProtocol.swift`, pure (no I/O).

- `SleepResultSection`: `bedTime`, `wakeTime` (sent as Unix seconds), `tzQuarterHours` (zigzag), `minutesAsleep` (sent × 60), `averageHeartRate`, `averageSpO2` (nil goes out as 0), `extra` (nil leaves field 7 out, which is what Mi Fitness does).
- `SleepResultSection.Extra` writes fields 1-5 raw. It exists because the proto has it; do not send it before the list below says what it means.
- Sections are sorted by bed time. An empty list gives an empty `SleepResult`; Mi Fitness sends nothing in that case, and so should the caller.
- Vectors: `sleep_result`, `sleep_result_two`, `sleep_result_empty` in `ios/tests/protocol` (Python builds the expected bytes field by field).

## 4. To check on the band

Nothing below has been tried. Band 10 Pro `M2552B1` is the device at hand.

1. Does the band answer 8/41 at all, and with which `status` (field 100: 0 ok, 1 not supported, 4 parameter error)? [AB] `wear_common.proto:5-15`
2. Does the band's sleep screen change after it? Which value does it show: `valid_sleep_time`, or wake minus bed?
3. Is `valid_sleep_time` really seconds on the band (437 minutes sent as 26220 should read 7 h 17 min)?
4. Does a section without averages (0, 0) hide heart rate and SpO2, or show 0?
5. Does the band want one section (today) or accept seven? Is the Band 10 Pro's capability bit 32 set? (Where Mi Fitness reads the capability from was not traced.) [UNVERIFIED]
6. Does a second write for the same night replace the first, or add a second entry?
7. Does the band need the write at all when Mi Fitness is not installed: what does its sleep screen show the morning after a night that only Freeband synced?
8. A zone west of UTC: is the zigzag offset read correctly? (Cannot be checked from Turkey without changing the phone's zone.)
9. `ExtraData`: send one night with distinct values (quality 82, efficiency 91, breathing 15) and see what appears where. Only after 1-4 are settled.
10. `Animal`: not built by Freeband. Whether a newer Mi Fitness sends it is unknown. [UNVERIFIED]

Risk: the message only carries display values for the band's sleep screen as far as the sources show; a wrong one should at worst show a wrong summary until the next write. That is an inference, not a measurement. [UNVERIFIED]
