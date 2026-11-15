# First pairing ("bind") without the vendor app: local mode

How a phone and a Xiaomi band agree on the 16-byte auth key themselves, with no Xiaomi server.
Nothing here has been tried on a band yet. Code: `ios/Freeband/Band/MiBind.swift`; vectors:
`ios/tests/protocol` (`bind_*`).

Marks: **[AB]** read in AstroBox (`CORE/` = AstroBox-NG-Module-Core `src/` at `6b9b82d`, `PB/` =
AstroBox-NG-Module-Pb `protos/xiaomi/` at `03a9201`; both AGPL, read for facts only). **[MF]** read
in Mi Fitness for Android, decompiled (`MF/` = `com/xiaomi/fit/device/bind/`; class and field names
are the obfuscated ones). **[UNVERIFIED]** inferred, or a choice Freeband makes that neither source
makes. Nothing is **[MEASURED]**.

## 1. Summary

1. The phone asks the band how it wants to be bound (1/17). The band answers with a verify mode
   and an out-of-band (OOB) mode, or with an error such as "already bound".
2. Only verify mode `APP_LOCAL` can be done without Xiaomi's server. The phone sends a fresh P-256
   public key (1/18); the band answers with its own public key, a random and a proof.
3. The phone checks the proof, sends its random and its own proof (1/19); the band (after the user
   accepts on the band, in button mode) answers "confirmed".
4. Both sides derive a 64-byte key block with HKDF. Bytes 40..56 of it are the auth key.
5. The phone sends an encrypted "who I am" record (1/25); the band answers error code 0. Bound.

## 2. Packets

Every packet is a plaintext protobuf command `{1: type = 1 (ACCOUNT), 2: id, 3: Account{…}}` on the
protobuf channel, written before any login, so nothing is encrypted by the transport [AB
`CORE/device/xiaomi/components/bind.rs:150-158`] [MF: every step goes through `unauthCall`,
`MF/LocalWearBinderV2.java:157,205,247`]. The only encrypted bytes are the field inside step 7.
Numbers below are protobuf field numbers; `Account` is a oneof [AB `PB/wear_account.proto:19-36`
ids, `:54-83` oneof].

| Step | Dir | id | Account field | Message |
|---|---|---|---|---|
| 1 | phone to band | 17 `BIND_START_V2` | 11 | `BindStartV2{1 check_dynamic_code: bool, 2 hash_user_id: bytes, 3 device_name: string, 4 pid: uint32 (never set)}` |
| 2 | band to phone | 17 | 12 | `BindInfoV2{1 verify_mode, 2 serial_number: string, 3 mac: string, 4 model: string, 5 oob_mode, 6 device_random: bytes, 7 did: string}` |
| 3 | phone to band | 18 `BIND_VERIFY` | 17 | `BindLocal.AppVerify{1 app_device_id: string, 2 app_public_key: bytes(64)}` |
| 4 | band to phone | 18 | 18 | `BindLocal.DeviceVerify{1 device_public_key: bytes(64), 2 device_random: bytes(16), 3 device_sign: bytes(32)}` |
| 5 | phone to band | 19 `BIND_CONFIRM` | 19 | `BindLocal.AppConfirm{1 app_random: bytes(16), 2 app_sign: bytes(32)}` |
| 6 | band to phone | 19 | 20 | `BindLocal.DeviceConfirm{1 confirm_result: bool}` |
| 7 | phone to band | 25 `BIND_RESULT_V2` | 29 | `BindResultV2{1 encrypt_result_info: bytes}` |
| 8 | band to phone | 25 | 3 | `error_code` = 0 |

(Messages: [AB `PB/wear_account.proto:135-150, 184-215`]; flow: [AB `bind.rs:131-209`] [MF
`MF/WearBinderV2.java:45-107`, `MF/LocalWearBinderV2.java:144-347`].)

At any step the band may answer with `Account{3: error_code}` instead (section 5).

Field details:

- **Step 1.** `hash_user_id` = MD5 of the user id string, 16 bytes [AB `bind.rs:141`] [MF
  `WearBinderV2.java:52`]. `check_dynamic_code` is always written, `false` [AB `bind.rs:140`]; MF
  passes a constructor flag that its only caller sets to `false`
  [MF `BluetoothDeviceBinder.java:219`]. `device_name`: AstroBox sends `"AstroBox"` [AB
  `bind.rs:142`]; Mi Fitness leaves it empty, so the field is not on the wire [MF
  `WearBinderV2.java:50-52`, serializer `defpackage/x60.java:69-79`]. Freeband omits the field when
  the name is empty.
- **Step 2.** `device_random` of this message is used by neither source in local mode [AB] [MF
  passes it only to the server variant, `WearBinderV2.java:104`]. `mac`, `serial_number` and `did`
  identify the band: never log or commit them.
- **Step 3.** `app_device_id`: any string of 1..64 bytes without NUL for AstroBox [AB
  `bind.rs:22-29`]; Mi Fitness sends MD5(upper-case MAC from step 2 followed by the user id) as text
  [MF `MF/LocalBindTool.java:25-32`]. `app_public_key`: see section 3.
- **Step 8.** AstroBox needs `error_code` 0 [AB `bind.rs:191`]. Mi Fitness also takes a reply with
  no account payload or no error code as success [MF `LocalWearBinderV2.java:213`]. Freeband
  follows Mi Fitness (any id 25 reply that is not a non-zero error code).

## 3. Crypto

- **Curve.** NIST P-256 (secp256r1), a fresh key pair per bind [AB `bind.rs:53-64`] [MF
  `defpackage/dse.java:98-102`].
- **Public keys on the wire.** 64 bytes, X then Y, big-endian: the uncompressed SEC1 point without
  its leading `04` [AB `bind.rs:66-68, 73-75`] [MF `dse.java:118-121`, and the `04` put back at
  `LocalWearBinderV2.java:298-300`].
- **Shared secret `S`.** The raw ECDH X coordinate, 32 bytes, no hash [AB `bind.rs:76`] [MF
  `dse.java:123-128`, the key agreement's raw secret].
- **Band's proof (step 4).** `device_sign` = HMAC-SHA256(key `S`, message `device_random` of step
  4) [AB `bind.rs:77-79`] [MF `LocalWearBinderV2.java:310-321`, HMAC at `defpackage/iz7.java:8-12`].
- **Phone's proof (step 5).** `app_sign` = HMAC-SHA256(key `S`, message `app_random`), where
  `app_random` is 16 fresh random bytes [AB `bind.rs:80-81, 88-91`] [MF
  `LocalWearBinderV2.java:233-244, 325`].
- **Dynamic code.** When Mi Fitness holds a non-empty code string, both messages get the code's
  bytes appended: `device_random ‖ code` and `app_random ‖ code` [MF
  `LocalWearBinderV2.java:233-241, 310-319`]. The only caller passes an empty code
  [MF `BluetoothDeviceBinder.java:219`]; AstroBox has no code at all. Freeband takes an optional
  code and appends it the same way.
- **Key block.** HKDF-SHA256, salt = `app_random ‖ device_random` (32 bytes), input key = `S`,
  info = ASCII `miwear-bind`, 64 bytes out [AB `bind.rs:82-86`] [MF
  `LocalWearBinderV2.java:327-330`, `dse.java:87-92`, salt as the HMAC key of the extract step at
  `defpackage/fi8.java:103-115`].

| Bytes | Use | Source |
|---|---|---|
| 0..16 | key for band-to-phone packets | [AB `bind.rs:197`]; kept but not read in [MF `:337`] |
| 16..32 | key for phone-to-band packets; also encrypts step 7 | [AB `bind.rs:198, 111`] [MF `:338, 202`] |
| 32..36 | nonce prefix, band to phone | [AB `bind.rs:199`]; kept but not read in [MF `:339`] |
| 36..40 | nonce prefix, phone to band | [AB `bind.rs:200`]; kept but not read in [MF `:340`] |
| **40..56** | **the 16-byte auth key** (Mi Fitness calls it `appToken`) | [AB `bind.rs:195`] [MF `:341, 127`] |
| 56..64 | unused | [AB] [MF] |

  Bytes 0..40 have the roles they have in the normal login's key block (`findings.md` §4).
- **Step 7 payload.** Plaintext `BindLocal.ResultInfo{1 user_id: string, 2 CompanionDevice}`,
  encrypted with AES-128-CCM: key = bytes 16..32, **fixed 12-byte nonce `10 11 12 13 14 15 16 17
  18 19 1A 1B`**, associated data = ASCII `bind-data`, 4-byte tag; the field carries ciphertext ‖
  tag [AB `bind.rs:94-113`, `CORE/crypto/aesccm.rs:9`] [MF `LocalWearBinderV2.java:202`, nonce
  `WearBinderV2.java:19`, 32-bit tag `dse.java:75-78`, ciphertext then tag `dse.java:63-72` and
  `defpackage/h71.java:23-30`].
- **`CompanionDevice` contents differ.** AstroBox: `{1 device_type = 0 (ANDROID), 3 device_name =
  "AstroBox", 4 app_capability = 0xFFFFFFFF}` [AB `bind.rs:96-105`]. Mi Fitness: `{1 device_type =
  0, 2 system_version = Android SDK level as float, 3 device_name = phone model}`, no capability
  [MF `LocalWearBinderV2.java:197-201`]. Freeband sends what its normal login already sends:
  `{1: 1 (IOS), 3: name, 4: 0xFFFFFFFF}` [UNVERIFIED for bind].

## 4. Preconditions and what the user does

- **Verify mode** (step 2 field 1): 1 `SERVER_PSK`, 2 `APP_LOCAL` [AB `PB/wear_account.proto:5-8`].
  Only 2 can be done here. With 1 the band wants a signature from Xiaomi's server (`BindPsk.*`):
  AstroBox stops with an error [AB `bind.rs:172`], Mi Fitness goes to its cloud path [MF
  `WearBinderV2.java:97-104`]. Any other value: "verify mode not support" [MF `:98`].
  **The band decides**, the phone cannot ask for local mode. Which models and firmwares answer
  `APP_LOCAL` is in neither source [UNVERIFIED].
- **OOB mode** (step 2 field 5): 0 `NO_OOB`, 1 `NUMERIC_COMPARISON`, 2 `DYNAMIC_CODE`, 3
  `BUTTON_CONFIRM` [AB `PB/wear_account.proto:10-15`]. AstroBox continues for 0 and 3 [AB
  `bind.rs:173`]; Mi Fitness continues for 2 and 3 and fails for the rest ("oob mode not support")
  [MF `WearBinderV2.java:87-94`]. Freeband continues for 0, 2 and 3 and refuses 1.
- **Button confirm (3).** Mi Fitness shows "confirm on the band" right after sending step 3 and
  takes it down after step 8 [MF `LocalWearBinderV2.java:183-185, 216`]; AstroBox logs the same
  request after step 2 [AB `bind.rs:175`]. Mi Fitness waits 20 s for step 4 and 15 s for steps 2,
  6 and 8 [MF `:182, 222, 270`, `WearBinderV2.java:106`]. Whether the band holds back step 4 or
  step 6 until the button is pressed is not in the sources [UNVERIFIED]; with those timeouts the
  user has at most about 20 s.
- **Declining.** The band answers step 5 with error code 6 `CANCEL` ("device cancelled") [MF
  `:261-262`] or with `confirm_result = false` ("Device declined local binding") [AB
  `bind.rs:187`].
- **Dynamic code (2).** What the band shows and where the code comes from is in neither source;
  Mi Fitness's caller binds with an empty code [MF `BluetoothDeviceBinder.java:219`] [UNVERIFIED
  that a band in mode 2 accepts that].

## 5. Error codes

`Account.error_code` (field 3) [AB `PB/wear_account.proto:38-52`]. What each means for the user is
[UNVERIFIED] unless a source is given.

| Code | Name | For the user | `MiBind.Failure` |
|---|---|---|---|
| 0 | NO_ERROR | at step 8: bound | |
| 1 | HAVE_BOUND | the band is bound to another phone or app ("device have bound", [MF `WearBinderV2.java:72-74`]); reset the band first (section 7) | `.alreadyBound` |
| 2 | INFO_MISSING | a required field was missing: a bug on our side | `.band(code: 2, …)` |
| 3 | INVALID_PARAM | a field was wrong (key length, id): a bug on our side | `.band(code: 3, …)` |
| 4 | NO_BOUND | the band is not bound; expected for login, not for bind | `.band(code: 4, …)` |
| 5 | SERVER_ERROR | the band wanted the server path | `.band(code: 5, …)` |
| 6 | CANCEL | declined on the band, or the band's prompt timed out [MF `LocalWearBinderV2.java:261-262`] | `.rejectedOnBand` |
| 7 | VERIFY_ERROR | a proof did not match ("verify device signature failed" at step 4, [MF `:176-177`]); try again | `.band(code: 7, …)` |
| 8 | STATE_NOT_MATCH | steps out of order, for example a bind left half done; reconnect and start over | `.band(code: 8, …)` |
| 9 | USER_CHANGED | the user id differs from the one the band knows | `.band(code: 9, …)` |
| 10 | CONNECTION_REACH_LIMIT | too many phones connected to the band | `.band(code: 10, …)` |
| 100 | UNKNOWN | the band gave no reason | `.band(code: 100, …)` |

Failures the phone finds itself: `.serverBindRequired` (verify mode 1), `.unsupportedVerifyMode`,
`.unsupportedOOB` (mode 1 or unknown), `.bandProofMismatch` (step 4 proof or key malformed or
wrong), `.unexpectedReply` (a bind reply that is neither the expected message nor an error code).

When Mi Fitness itself finds the band's proof wrong it tells the band: id 19 with `error_code` 7;
for a failed key generation, id 18 with code 100 [MF `LocalWearBinderV2.java:105-108, 120-124,
273-287`]. AstroBox sends nothing [AB `bind.rs:206, 219-221`]. Freeband returns such a packet next to
`.bandProofMismatch` for the caller to send.

## 6. After the bind

- AstroBox marks the connection logged in with bytes 0..40 as session keys and runs no login
  (26/27) in it [AB `bind.rs:191-203`]. Mi Fitness stores bytes 0..16 and 32..40 but this class
  never reads them; it hands the app device id and the auth key to its caller and records the bind
  on the server on a best-effort basis [MF `LocalWearBinderV2.java:126-141`]. Whether the band
  treats the connection as logged in after step 8 is [UNVERIFIED]. `MiBind.Bound` carries both the
  auth key and the session keys.
- Later logins: `Auth.AppVerify` has `2 app_device_id` and `3 check_dynamic_code` [AB
  `PB/wear_account.proto:219-223`]. AstroBox sends the id when it has one [AB
  `CORE/device/xiaomi/components/auth.rs:59-67`]; Mi Fitness sends it for a device that has one,
  with field 3 set to whether a code is known [MF `com/xiaomi/wearable/wear/api/WearAuthV2.java:
  103-110`]. So the app device id must be stored next to the auth key; `MiAuth.nonceCommand` takes
  it as an optional argument. Whether a locally bound band rejects a login without it is
  [UNVERIFIED].

## 7. A band that is already bound to the vendor app

- The only thing the sources say: the band may answer step 1 with `HAVE_BOUND`, and Mi Fitness
  then shows "already bound" and stops [MF `WearBinderV2.java:70-74`,
  `com/xiaomi/fitness/device/manager/ui/bind/BindViewModel.java:309-312`]. AstroBox treats it like
  any other error [AB `bind.rs:206`].
- Whether a bound band answers `HAVE_BOUND`, or starts a new bind and replaces the old one, is
  **not known** [UNVERIFIED]. Error code `USER_CHANGED` and the System ids `NOTIFY_NEW_BIND` (12)
  and `APPLY_NEW_BIND` (63) [AB `PB/wear_system.proto:43-44`] hint that some firmwares can take a
  new owner while bound; nothing reads them.
- If the band accepts a new bind while bound, expect the old auth key (the vendor app's) to stop
  working and, on the pattern of the vendor app, the band's data to be wiped [UNVERIFIED]: when Mi
  Fitness unbinds a connected band it sends System (type 2) id 0 with a reset mode it logs as
  `ERASE_ALL`, a factory reset [MF `MF/BluetoothDeviceBinder.java:108-119`].
- If the band answers `HAVE_BOUND`, the way forward is a factory reset on the band (all data on it
  is lost) and a bind while it shows its pairing screen [UNVERIFIED].
- A band bound to the vendor app through the server may well report `SERVER_PSK` after a reset
  too; then local bind is not possible on that firmware and the key has to come from the vendor
  app as today.
- Steps 1 and 2 change nothing we know of on the band [UNVERIFIED], so the first probe is: send
  step 1 only and log the verify mode, the OOB mode or the error code.

## 8. Where AstroBox and Mi Fitness differ

| Point | AstroBox | Mi Fitness | Freeband |
|---|---|---|---|
| `device_name` in step 1 | `"AstroBox"` | absent | absent when empty |
| OOB modes accepted | 0, 3 | 2, 3 | 0, 2, 3 |
| Dynamic code in the proofs | none | appended when non-empty | appended when non-empty |
| `app_device_id` | caller's string | MD5(MAC ‖ user id) as text | caller's string |
| `CompanionDevice` | type 0, name, capability | type 0, SDK level, model | type 1, name, capability |
| Step 6 `confirm_result = false` | fails | ignored (then times out) | fails, `.rejectedOnBand` |
| Step 8 success | `error_code` 0 | 0, or no error code | 0, or no error code |
| Tells the band about a bad proof | no | id 19, code 7 | returns the packet |
| After step 8 | session keys in use, no login | keeps the auth key | returns both |

## 9. To check on the band

1. Step 1 on a band that is bound to the vendor app: `HAVE_BOUND`, or a `BindInfoV2`? Does the
   vendor app still log in afterwards (was anything changed)?
2. Step 1 on a factory-reset band showing its pairing screen: verify mode and OOB mode.
3. Does the band answer step 1 without `device_name`, and with one?
4. In mode 3: at which step does the band show its prompt, how long does it wait, and what comes
   back when the user declines or does nothing?
5. Is the band's proof over `device_random` of step 4 only (not the one of step 2)?
6. Does step 7 pass with `device_type` 1 (IOS)?
7. After step 8: does the band accept encrypted commands at once with bytes 0..40, or does it want
   a login (26/27) first? Does a login with bytes 40..56 work in the same connection and after a
   reconnect, with and without `app_device_id`?
8. Does the band keep its activity data across a bind?
9. After a local bind, can the vendor app still bind the band (after a reset)?

## 10. Code and tests

`MiBind` (`ios/Freeband/Band/MiBind.swift`) has a builder per phone command, the two crypto
functions and `MiBind.Machine`. The caller makes a machine from a `Config` (user id, app device id,
phone name, optional code), writes `start()` to the band as a plaintext command, and passes every
plaintext command the band sends to `receive(_:)`, which answers one of:

- `.send(command, confirmOnBand:)`: write it; when `confirmOnBand` is true, ask the user to accept
  on the band.
- `.bound(Bound)`: store `authKey` and `appDeviceID` for the band; `keys` are the session keys of
  section 6.
- `.failed(Failure, tellBand:)`: over; write `tellBand` first when it is there.
- `.ignored`: not a bind reply, or one this stage does not wait for.

The machine has no timers: the caller gives up after its own timeout by dropping it. The private
key and the app random are arguments, so tests fix them. `MiCrypto.ccmEncrypt/ccmDecrypt` took an
`aad` argument for step 7, and `MiAuth.nonceCommand` an optional `appDeviceID` (section 6).

Vectors (`ios/tests/protocol`, keys `bind_*`, `ccm_aad*`, `nonce_cmd_app_id`): `check_vectors.py`
plays the band with Python's `cryptography` (its own P-256 keys, ECDH, HMAC, HKDF loop, AES-CCM)
and compares every command the machine sends and the final key block: a whole bind in button mode
and one with a code, then the refusals (server mode, unknown verify mode, numeric comparison,
already bound, wrong proof, wrong code, off-curve key, declined, cancelled, other error codes,
unexpected reply, invalid config).
