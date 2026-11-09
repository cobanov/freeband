# BLE V1: the older Xiaomi channel

Status: protocol notes for Freeband's V1 transport, written from Gadgetbridge before the first test. Sections 2 and 10 record what the watch showed; Freeband now logs in and syncs over V1.
Measured device: Xiaomi Watch S1 Active, Bluetooth name `XiaomiWatchS1Active 6373`, 2026-11-08.
Source: Gadgetbridge `master`, commit `db008768` (2026-11-07).

Citations are `file:line`. Paths are shortened as in [`findings.md`](../findings.md) (`X/`, `XD/`, `W/`), plus:

- `CV1` = `X/XiaomiCharacteristicV1.java`
- `PV1` = `X/XiaomiBleProtocolV1.java`
- `AUTH` = `X/XiaomiAuthService.java`

Marks: **[CODE]** read in Gadgetbridge. **[MEASURED]** seen on the watch. **[UNVERIFIED]** inferred; check on the watch.

All multi-byte numbers are little-endian.

## 1. Which devices

Gadgetbridge lists one V1 set under `FE95` for "all encrypted devices": Mi Band 8, Redmi Watch 3 Active, Xiaomi Watch S1 (Active), Redmi Smart Band 2 and Redmi Watch 2 Lite. [CODE] `X/XiaomiUuids.java:33-46`

When a device offers both channels, Gadgetbridge tries V1 first and V2 second. [CODE] `X/XiaomiBleSupport.java:66-79`

The S1 Active's connection type is `BOTH`: a user setting in Gadgetbridge (BLE when unset), not something chosen by firmware. On iPhone, Mi Fitness can only use BLE. [CODE] `W/XiaomiWatchS1ActiveCoordinator.java:46-49`, `findings.md` §3.1

## 2. GATT on the S1 Active [MEASURED]

Read by Freeband's discovery log with Mi Fitness closed. The watch was reached through the connection iOS already held, not by scanning.

| Characteristic | Properties | Role |
|---|---|---|
| `0050` | read | unknown (also on the Band 10 Pro) |
| `0051` | write-without-response, notify | V1 command read |
| `0052` | write-without-response, notify | V1 command write |
| `0053` | write-without-response, notify | V1 activity data |
| `0054` | write-without-response, notify | unknown, not in Gadgetbridge |
| `0055` | write-without-response, notify | V1 data upload |
| `0056`, `0057` | write-without-response, notify | unknown, not in Gadgetbridge |
| `0058`, `0059` | notify | unknown, not in Gadgetbridge |

There's no `005E`/`005F`: this firmware speaks V1 only.

## 3. Characteristics and their roles

| Characteristic | What travels on it | Source |
|---|---|---|
| `0051` command read | the watch's commands and replies | [CODE] `PV1:107` |
| `0052` command write | the phone's commands; the watch's acknowledgements of them | [CODE] `PV1:215-223` |
| `0053` activity data | activity file messages from the watch | [CODE] `PV1:113` |
| `0055` data upload | watch faces, firmware, icons; not needed for sync | [CODE] `PV1:116-120` |

Each characteristic is its own channel, with its own send queue, its own reassembly and its own counter. Acknowledgements are written back to the characteristic the message arrived on. [CODE] `CV1:517-532`

## 4. Starting a session

1. Turn on notifications for `0052`, `0051`, `0053` (and `0055`). [CODE] `PV1:126-129`
2. Send authentication step 1 straight away. Unlike V2, there is no SessionConfig exchange. [CODE] `PV1:132-134`

Gadgetbridge asks for an MTU of 512 and assumes 244-byte writes until the MTU is known. [CODE] `PV1:104`, `PV1:124`, `CV1:66`. iOS negotiates the MTU on its own, so Freeband uses `maximumWriteValueLength(for: .withoutResponse)` as the maximum write. Every V1 characteristic on the S1 Active is write-without-response. [MEASURED]

## 5. Message layout

Every write and every notification starts with a u16 `chunk` field.

**`chunk` ≠ 0:** a slice of a chunked message, numbered from 1. The rest of the value is the slice. [CODE] `CV1:158-167`, `CV1:239-280`

**`chunk` = 0:** a control message. The next byte is its type:

| Bytes | Meaning | Source |
|---|---|---|
| `00 00 00 <enc> <n u16>` | a chunked message of `n` slices follows; `enc` 1 encrypted, 0 plain | [CODE] `CV1:284-297`, `CV1:466-471` |
| `00 00 01 01` | ready: send the slices (reply to a chunked start) | [CODE] `CV1:320-336`, `CV1:523-526` |
| `00 00 01 00` | every slice arrived | [CODE] `CV1:310-319`, `CV1:529-532` |
| `00 00 01 02` | the chunked message was refused | [CODE] `CV1:338-347` |
| `00 00 01 05 <i u16>…` | send these slices again | [CODE] `CV1:173-205`, `CV1:348-374` |
| `00 00 02 <enc> [ctr u16] <body>` | a single-write message; `enc` 1 encrypted, 2 plain; `ctr` only on encrypted messages from the phone | [CODE] `CV1:380-399`, `CV1:482-494` |
| `00 00 03 <result>` | acknowledgement of a single-write message; 0 accepted | [CODE] `CV1:52`, `CV1:401-422` |

The plain flag differs: 0 in a chunked start, 2 in a single-write message.

The body is a protobuf `Command`, as on V2, but with nothing in front of it: V1 has no channel or opcode bytes. [CODE] `PV1:107`, `PV1:222`

## 6. Sending

- **One message in flight per characteristic.** The next one waits for `00 00 03 xx` (single write), or for `00 00 01 00` or `00 00 01 02` (chunked). [CODE] `CV1:429-433`, `CV1:310-347`, `CV1:401-422`
- **Plain until authenticated.** Both authentication messages go plain; encryption starts once the watch confirms step 3. [CODE] `CV1:443`, `AUTH:152-157`
- **Single write or chunks.** A message goes as a single write when its body plus 6 bytes fits in the maximum write; otherwise it is chunked. The body is the ciphertext with its tag, or the plaintext. [CODE] `CV1:507-515`
- **Single write:** `00 00 02 01 <ctr> <ciphertext‖tag>`, or `00 00 02 02 <plaintext>`. [CODE] `CV1:482-494`
- **Chunked:** [CODE] `CV1:450-475`, `CV1:320-336`, `CV1:158-167`
  1. The message is `<ctr u16> <ciphertext‖tag>` when encrypted, or the plaintext.
  2. It is cut into slices of maximum write − 2 bytes.
  3. Send `00 00 00 <enc> <n>` and wait for `00 00 01 01`.
  4. Send every slice as `<i u16> <slice>`, `i` from 1.
- **Resend request.** On `00 00 01 05 <i>…`, send those slices again. [CODE] `CV1:348-374`
- **Counter.** `ctr` goes up by one with each encrypted message. [CODE] `CV1:457`, `CV1:490`

## 7. Receiving

- **Single write:** acknowledge with `00 00 03 00` at once, then decrypt the body if `enc` is 1. Incoming messages carry no counter: ciphertext and tag follow the flag directly. [CODE] `CV1:380-399`, `CV1:517-521`
- **Chunked start:** note `n`, drop any slices kept so far and reply `00 00 01 01`. [CODE] `CV1:284-297`
- **Slices:** keep each by number and ignore numbers above `n`. When all `n` are in, reply `00 00 01 00`, join them in order and decrypt. [CODE] `CV1:239-280`
- **Missing slices:** when no slice arrives for 5 s, send `00 00 01 05` followed by the missing numbers, at most (maximum write − 4) / 2 of them. [CODE] `CV1:50`, `CV1:173-205`, `CV1:211-214`
- **The flag.** Gadgetbridge decrypts every chunked message on an encrypted channel and drops a chunked start whose flag is not 1. Freeband decrypts by the flag instead, which agrees whenever Gadgetbridge's check passes. [CODE] `CV1:287-292`, `CV1:266-268`

## 8. Encryption

- **Cipher:** AES-128-CCM, 4-byte tag, no associated data. The 12-byte nonce is `nonce4 ‖ 00 00 00 00 ‖ counter u32`. [CODE] `AUTH:177-188`, `AUTH:343-350`
- **Phone to watch:** `encryptionKey` and `encryptionNonce`, with the message's `ctr` as counter. Counter 0 belongs to authentication step 3 (the CompanionDevice blob). After authentication, messages count from 1 on every characteristic. [CODE] `AUTH:233`, `CV1:111`
- **Watch to phone:** `decryptionKey` and `decryptionNonce`, with counter 0 every time. [CODE] `AUTH:190-200`. [UNVERIFIED] on the S1 Active.
- **Tag check:** Gadgetbridge checks the watch's tag (`checkDecryptionMac`, true unless a coordinator overrides it; the S1 Active doesn't). [CODE] `XD/XiaomiCoordinator.java:795-797`, `AUTH:356`
- **Keys:** the same HKDF output and the same split as V2. [CODE] `findings.md` §4.4
- **After authentication:** every characteristic resets. Counters go back to 1, and queued messages and partial chunked messages are dropped. [CODE] `PV1:204-213`, `CV1:108-117`

## 9. What stays as on V2

- **Authentication:** the same three commands (`findings.md` §4.3), sent as plain single-write messages on `0052`, with replies on `0051`. [CODE] `PV1:132-134`, `PV1:107`
- **Commands:** the same protobuf `Command` messages. [CODE] `PV1:107`, `PV1:222`
- **Activity files:** messages on `0053` go to the same activity fetcher that V2's channel 5 feeds, so Freeband's `ActivityAssembler` and parsers apply unchanged. [CODE] `PV1:113`
- **Releasing the channel:** turn notifications off on every characteristic so Mi Fitness can take over (`findings.md` §5.4).

## 10. Checked on the watch

Xiaomi Watch S1 Active, model `M2116W1`, firmware `1.4.174`, 2026-11-08. iOS reported 509-byte writes.

| Question | Result |
|---|---|
| Authentication over V1 with `device_type = iOS` | works [MEASURED] |
| The watch encrypts with counter 0 (section 8) | yes: its encrypted replies decrypt with matching tags [MEASURED] |
| Where acknowledgements and replies arrive | acknowledgements on the characteristic written (`0052`), replies on `0051` [MEASURED] |
| Commands | device info, live stats and both file lists answer; the clock command gets no reply [MEASURED] |
| Activity files | arrive on `0053` and pass the CRC: daily details v3, daily summary v4, sleep details v2, manual samples v2, and subtype 10 v1 (14 bytes; unknown to Gadgetbridge too) [MEASURED] |
| Empty files | a day without manual readings gives a 12-byte manual-samples file: id, pad and CRC only (`docs/ACTIVITY.md`) [MEASURED] |
| Sleep | a sleep details v2 file covering the second of the night's two sessions (the first had no file on the watch), with no summary or stages; the session is in the fell-asleep/woke-up events, not the header (`docs/ACTIVITY.md`) [MEASURED] |
| Command 13/2 | about ten during each file fetch; AstroBox calls it Factory `DUMP_FILE` [MEASURED], meaning [UNVERIFIED] |
| Notifications (Command 7/0) | shown on the watch [MEASURED, 2026-11-09] |
| Find (Command 2/18) | acknowledged, but the watch doesn't vibrate; Gadgetbridge marks Find unsupported on it [CODE] `W/XiaomiWatchS1ActiveCoordinator.java:51-54`. Freeband hides Find for this watch [MEASURED, 2026-11-09] |
| Before the login | right after the notifications come on, the watch can send an encrypted single-write message on `0051`, still under the previous session's keys. It can't be decrypted (logged as "didn't decrypt"); it is acknowledged and dropped, and the login goes on normally [MEASURED, 2026-11-09] |

Still open:

1. A write near the 509-byte maximum: so far every outgoing message was a short single write.
