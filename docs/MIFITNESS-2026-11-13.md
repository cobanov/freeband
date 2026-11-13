# Mi Fitness (com.xiaomi.wearable) — miwear protocol behaviour notes

App analysed: **Mi Fitness / Xiaomi Wear, versionName 9.8.348i (versionCode 908348)**, pulled from APKPure (sha256 42958d45…c2a33). Decompiled with jadx 1.5.6 to /tmp/mifit/out. Static only; APK never executed.

## Packet model as used in code
- `t1i` = outer WearPacket. Fields: `t1i.c` = **type**, `t1i.d` = **id**, payload via setters (`t1i.I(wn6)` = Fitness payload, oneof field 10). `t1i.B(u40)`=auth/raw payload, `t1i.w()`=InfoResponse(weather), `t1i.t()`=System(hhg), `t1i.j()`=Fitness(wn6), `t1i.c()`=auth response.
- `wn6` = Fitness oneof container (nested in packet). `wn6.X(mo6)`=HeartRateMonitor (fld8), `wn6.Y(byte[])`=id (fld3), `wn6.Z(byte[])`=ids (fld2), `wn6.x0(kq6)`=TodayReq (fld5), `wn6.A0(rq6)`=VitalityData (fld43), `wn6.r0(up6)`=SleepResult (fld37), `wn6.s0(gn6.a)`=sport-config list (fld44), `wn6.D()`=getter (fld26 launch-sport reply), `wn6.G()`=sportStatus (fld24), `wn6.d()`=HR value (fld39, read in id47 push), `wn6.v()`/`A()`=gym report list (hp6.a, fld4/59).
- Type constants (`WearPacket.java`, com.xiaomi.miot.core.extensions): note these are the *miot-core* kotlin wrapper constants and DO NOT match the on-wire type numbers used by the fitness code. On the wire the app uses raw ints: **type 8 = Fitness/Health, type 2 = System, type 1 = Account/Auth, 10=weather,11=stock,12=calendar,16=GNSS/AGPS**. (The task's "Health=8, System=2, Account=1" matches the raw ints the code sends, confirmed below.)

## Q1 — Fitness ids: build (app→device) vs parse (device→app)  [CODE]
`FitnessWearPbImpl` (com.xiaomi.fit.fitness.device.mi.send) builds all the sync-control packets with `t1iVar.c = 8`:
- **id 1 GET_TODAY_FITNESS_IDS** — BUILD. `getTodayFitnessIds()`, payload `kq6{f20004a=reason}` (0=manual,1=bg-auto) via `wn6.x0`. Reply parsed in `realGetFitnessIds` (`wn6.N()/O()` → `wn6.n()` id / `wn6.o()` ids).
- **id 2 GET_HISTORY_FITNESS_IDS** — BUILD. `getHistoryFitnessIds()`, empty payload.
- **id 3 REQUEST (single id bytes)** — BUILD. `requestFitnessIds()` when `dataIds.length != 7` → `wn6.Z(dataIds)`.
- **id 4 REQUEST (7-byte id)** — BUILD. same method when `dataIds.length == 7` → `wn6.Y(dataIds)`.
- **id 5 CONFIRM_FITNESS_ID** — BUILD. `confirmFitnessId()`, `wn6.Y(dataId.toByteArray())`.
- **id 6 GET_REMAINING_SPORT_DATA (gym offline reports)** — BUILD. `SportGymSender.getSportReportList()` / `GymDeviceModel.checkGymOfflineReport()`, empty payload; reply parsed as `hp6.a` list of `hp6{f17343a=ids,d=duration,e=distance}`.
- **id 41 SYNC_SLEEP_RESULT** — BUILD (write-back to device). `SleepSegmentUtils.writeBackSleepToDevice()`, payload `up6` (SleepResult) via `wn6.r0`.
- **id 44** — PARSE only (no type-8 build site; the `d=44` senders found are type 2/System). Fitness oneof field 44 = sport-config list, but that is carried under id 52.
- **id 45 register device HR** — BUILD. `sport_manager/extension/DeviceModelExtKt.startDeviceHr()`.
- **id 46 unregister device HR** — BUILD. `…stopDeviceHr()`.
- **id 47 realtime HR push during sport** — PARSE only. `DistanceHeaderViewHolder$DataHandlerImpl.handlePacket` accepts type 8 & `packet.d==47`, reads `packet.j().d().d` (HR). No type-8 sender.
- **id 51 SYNC_VITALITY_DATA** — BUILD (write-back). `MiVitaliyDataSender.sendToWear()`, payload `rq6{f26987b=pq6[]}` via `wn6.A0`.
- **id 52 sport-config to watch** — BUILD. `SportConfigProvider` (sport_manager/source/towear), payload `gn6.a` list via `wn6.s0`.
Other built type-8 ids seen: 29 syncDeviceSportStatus, 30 phone-sport pre-request, 57/58/60 track push, 61/62/63 sleep-rhythm, 65/67/68 gym launch, 35/36 vitality settings, 10/11 HR-monitor cfg, etc.

## Q2 — Moving / intensity (mid-high) minutes  [CODE]
The ring's "Moving/intensity" minutes are **computed on the phone from the activity (fitness) files**, not from a command reply or push.
- File: **daily activity record, dataType=0, dailyType=0, fileType=0** → `DailyRecordParser`. Per-minute records (`sDayInMinutes` loop, 60-sec step).
- Field: per-minute `DataItemType.activityHILevel = 5` (only honoured when record `version >= 3`). Values from enum `ActivityIntensity`: QUIET0 LIGHT1 LOW2 MIDDLE3 HIGH4 SEVERE5.
- `MiParsedDataRecorder.recordDailyRecord` (~line 469): if `activityHILevel in 3..5` it emits one `MHStrengthItem(time)` for that minute → stored via `recordMHStrength`. So "moving/mid-high-intensity minutes" = count of minutes whose per-minute activityHILevel ≥ 3 (MIDDLE/HIGH/SEVERE).
- Daily-report file (dailyType 0 / fileType 1, `DailyReportParser`) also carries aggregate `validStand`(fld12, 3-byte hourly bitmap → `ValidStandItem` per set bit), and vitality summary flds 24/25/26 dayLow/Medium/HighIntensityVitality + 27 total7daysVitality (`recordVitalityItem`). Hourly stand detail = bits of the 3-byte validStand bitmap (bit n = hour active).
- When writing these back to the band (id 51) `MiVitaliyDataSender` builds 4 `pq6` channels: type1=step(c=30min bins), type2=cal(30), type3=strength/MH(30), type4=stand(60min bins); each `pq6.d=int[]` hourly/half-hourly detail, `pq6.b`=total.

## Q3 — Sleep (SYNC_SLEEP_RESULT, id 41)  [CODE]
- Raw sleep comes from fitness file **dailyType = 8 (AllDaySleep)** → `AllDaySleepParser`; (also dailyType 2 Daytime, 3 Night). Raw bytes (`AllDaySleepParseData.sleepSrcBytes`) are fed to a **native algo on the phone**: `MiDevSleepAlgo` → `System.loadLibrary("jni_xiaomi_sleep_algorithm")`, `MiSleepAlgorithmNative.parseSleep()` producing `SleepStageSummary` (stages, durations, breath, HR/SpO2 means computed in `SleepSegmentUtils.convertToSleepSegmentReport`).
- So the sleep **summary is computed on the phone (native lib), then written back to the band** via packet type8/id41 (`up6` SleepResult) so the watch face shows it. Trigger: after a sync, `FitnessDeviceSyncManager.handleSpecialSyncResult` → `SleepSegmentUtils.writeBackSleepToDevice(did, hasNewSleep)`. `hasNewSleep` set true in `onParseSuccess` when a dailyType==8 file parsed. For a 1-day-sleep device it only writes when new sleep exists; a 7-day-sleep device (capability bit 32) always writes the last 7 days.
- `up6` fields: `c[]` = segments; per segment `c.c`=bedTime, `c.d`=wakeupTime, `c.f29571b`=duration*60, `c.e`=avgHr, `c.f`=avgSpo2, `c.f29570a`=cz2{tz}. Cloud upload of raw sleep also happens (`MiParsedDataRecorder.uploadSleepSrcData`).

## Q4 — Normal data-sync sequence  [CODE]
`FitnessDataSyncBaseImpl.syncWithDevice` → `FitnessDeviceSyncManager.startSyncWithDevice`:
1. `pbImpl.syncWearSportStatus()` (type8/id29 via sport state server) — tells watch phone-sync starting.
2. `FitnessWearSender.requestData(did, cb, isBgAutoSync)` → `requestTodayData`:
   a. **id 1** today-ids (payload reason). Device returns packed 7-byte ids (`wn6.n/o`).
   b. ids filtered through Room DB (`DeviceDataSyncDao`, `checkNeedToSync`: skip if stored syncStatus>2; dailyType 5 userprofile always skipped) → `getUnSyncedDataIds`.
   c. **id 3** (or **id 4** when exactly one 7-byte id) `requestFitnessIds` with the id list → device streams the files.
3. On today done/empty → `requestHistoryData`: **id 2** history-ids, same filter, then **id 3/4** request.
4. File transfer is received on **type 102** (`FitnessReceiverHandler`/`FitnessDataReceiver`): little-endian header `total`,`seq` (uint16), chunks reassembled, optional CRC32 trailer, first `DATA_ID_LENGTH` (7) bytes = FitnessDataId, rest = payload → `syncTheData`→parse.
5. After each file parses OK, **id 5 CONFIRM_FITNESS_ID** is sent (`onSyncSuccess` → `confirmFitnessId`) and the id marked synced in DB (status 2 = SYNC_TO_PARSE_DB, 4 = SYNC_TO_WATCH).
6. Completion: 1-min timeout (`TIMEOUT_WAIT_SYNC_COMPLETE`); then `handleSpecialSyncResult` → vitality broadcast register + sleep write-back (id41).
- **Re-request already-confirmed ids / explicit ids**: `syncWithDevice(sid, byte[] dataIds, cb)` / `FitnessSyncer.syncData(did, dataIds, cb)` sends a chosen id list directly (bypasses today/history listing). Used by `ReceiveSportReportActivity` after a gym id6 list.
- **List workout/sport records still on device**: id6 `GET_REMAINING_SPORT_DATA` returns `hp6.a` (ids+startTime+sportType+duration+distance); the chosen ones are then fetched with `syncData(dataIds)`.
- FitnessDataId (7 bytes, LE): uint32 timestamp, int8 tzIn15Min, int8 version, 1 byte = bit7 dataType(0=daily,1=sport) | bits6-2 sportType/dailyType | bits1-0 fileType(0 record,1 report,2 gps,3 recoverRate).

## Q5 — First-time binding (Account type 1 + cloud)  [CODE]
`WearBinderV2.getBindInfo()` sends **type 1 / id 17** (GetBindInfo). Reply `m50` (BindInfo): `f21173a`=verifyMode, `e`=oobMode(f9587b), `c`=mac, `d`=…, `b`=…, `g`=…
Branch on verifyMode:
- **verifyMode == 2 → LocalWearBinderV2** (no-server "local" mode), when oobMode ∈ {2,3}. Flow (all `unauthCall`, type 1):
  - id 18 sendAppVerify (u40 payload, app pubkey) ; local ECDH P-256 (`u25.b` + `dse.m(KeyAgreement)`) → shareKey `h`; verify device signature; `dse.i("miwear-bind", h, salt)` = **HKDF, info "miwear-bind"** → bind key.
  - id 19 sendConfirm (OOB/dynamic code `o` appended to device random).
  - id 25 sendBindResult (`dse.e(...,"bind-data")` encrypt). `recordToServer` is best-effort only.
- **verifyMode == 1 → PSKWearBinderV2** (server-backed). Uses `BindToServer`: `applyBind(verifyMode,model,mac,randomMac,phoneId,…)`, `getBindInfo`(VerifyBindInfo: deviceKey, oobCode, bindKey from cloud), `verifyBind`, `confirmBind`, `unbind`. Device packets type1 id18 verify, id19 confirmOOB, id25 bindResult. OOB shown as `%06d` from `verifyBindInfo.getOobCode()`.
- Else `onBindFailure(1007,"verify mode not support")`.
- Reconnect auth (not bind): `WearAuthV2` type1 **id26 sendAppVerify**, **id27 sendAppConfirm**; `dse.i("miwear-auth", …)` = **HKDF info "miwear-auth"**; `e50` deviceConfirm carries deviceCapability v1/v2; keys installed via `CipherApiCall.updateKeys`.
- So: **local (serverless) bind path exists and is chosen when the device's BindInfo reports verifyMode==2 (OOB mode 2/3)**; verifyMode==1 goes through Xiaomi cloud (`BindToServer`). `RESTRICT_BIND`/`restrict_bind` feature exists. `reportBindStart` is analytics only.

## Q6 — System 2/78 and 2/79  [CODE]
- **2/78 queryStatus** (`com.xiaomi.xms.wearable.extensions.DeviceModelExtKt.queryStatus`): builds `t1i{c=2,d=78}`, reads reply `packet.t().p()` = `agg`. **agg fields: 1 `f811a` bool = CHARGING, 2 `f812b` int = battery level, 3 `c` bool = WEARING, 4 `d` bool = SLEEPING, 5 `e` = egg{1 int,2 int}.** Mapping confirmed in `g2i.java`: ITEM_CHARGING→agg.f811a, ITEM_WEARING→agg.c, ITEM_SLEEP→agg.d, ITEM_BATTERY→agg.f812b.
  - NOTE/mismatch: the observed reply `{1:1,2:0,3:0,4:0,5:{1:0}}` under this schema decodes to charging=true, battery=0, wearing=false, sleeping=false — which contradicts "on wrist, off charger". Either that capture was a different id/schema, or field1 here is not a plain boolean on this model. Worth re-checking against a known-state capture. egg (field5) nested {1,2} meaning not resolved from code (likely a sub-status/extra-flags block).
- **2/79** (`DeviceBasicStatusDataHandler.handlePacket`, `packet.d==79`): a **pushed** charge-status report, parsed as `cgg` (`cgg.f4213a` = charge status, compared to `lastChargeStatus`). Battery sync uses type2/id (syncBattery) reading `packet.t().g()` = `jgg` with nested charge info (`f18839a.a`=level, `.b`=chargeStatus, chargeInfo state 3 = full).

## Could not fully resolve
- egg (agg field 5) and the `{1:0}` sub-field meaning.
- Exact meaning of every bit in the 3-byte `validStand` hourly bitmap beyond "hour active" (bit→hour).
- id 44 as a type-8 command (no build site; parse path unconfirmed).
- The on-wire relationship between miot-core `WearPacket.TYPE_*` constants and the raw type ints — code consistently uses the raw ints (8/2/1), so treat those as authoritative.
