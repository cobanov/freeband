# Stay connected and Find Phone

Status: notes for Freeband's held session and Find Phone, written before the first test on the watch. Section 6 lists what to check; section 7 records what the watch showed (2026-11-09 to 2026-11-12).
Sources: Gadgetbridge `master`, commit `db008768` (2026-11-07), and AstroBox-NG `vendor/astrobox-Pb`.

Citations are `file:line`. Paths are shortened as in [`findings.md`](../findings.md) (`X/`, `XD/`, `W/`) and [`CAPABILITIES.md`](CAPABILITIES.md) (`ABP/` = AstroBox protobuf files), plus:

- `SYS` = `X/services/XiaomiSystemService.java`

Marks: **[CODE]** read in Gadgetbridge. **[AB]** read in AstroBox. **[iOS]** iOS behaviour as Apple documents it. **[MEASURED]** seen on a device. **[UNVERIFIED]** inferred; check on the device.

## 1. Find Phone on the wire

| Direction | Message | Meaning | Source |
|---|---|---|---|
| band → phone | `Command{2,17}` `system(4).findDevice(5) = 0` | start ringing | [CODE] `SYS:88`, `SYS:189-200` |
| band → phone | `Command{2,17}` `system(4).findDevice(5)` ≠ 0 | stop ringing | [CODE] `SYS:193-197` |
| phone → band | `Command{2,17}` `system(4).findDevice(5) = 1` | the phone stopped ringing on its own | [CODE] `SYS:917-931` |

- Gadgetbridge acts on a `2/17` only when the `system` field is there, and reads a missing `findDevice` as 0, so as start. [CODE] `SYS:190-197`
- The phone sends its stop only when the user stops ringing on the phone; a start from the phone does not exist. [CODE] `SYS:917-931`
- AstroBox calls subtype 17 `FIND_PHONE` and field 5 `find_mode`, an enum with `FIND_START = 0`, `FIND_STOP = 1`. [AB] `ABP/wear_system.proto:18-21`, `:61`, `:138`
- `Command{2,18}` with the same field is Find for the band (phone → band). The Watch S1 Active ignores it ([`BLE-V1.md`](BLE-V1.md) section 10).
- Bytes, before encryption:
  - start from the band: `08 02 10 11 22 02 28 00`
  - stop from the phone: `08 02 10 11 22 02 28 01`

## 2. Why it needs a held session

The band sends `2/17` on the command channel of an authenticated session. When no session is open, nothing receives it.

Until now Freeband opened a session only for a sync, a notification or live heart rate, then let go so Mi Fitness keeps working. With Mi Fitness closed, Find Phone on the watch did nothing. [MEASURED] Xiaomi Watch S1 Active, firmware 1.4.174, 2026-11-09

Mi Fitness can ring the phone because it keeps a session open in the background. Only one session at a time works on the channel ([`CAPABILITIES.md`](CAPABILITIES.md) section 2, point 2), so while Freeband holds the session, Mi Fitness can't open its own.

## 3. What iOS allows

- **`bluetooth-central` background mode.** A suspended app is woken for its Bluetooth events: a notification on a characteristic it subscribed to, a connection, a disconnection. Without it the app gets nothing in the background. [iOS]
- **Pending connection.** `connect` has no time limit. When the band comes back in range, iOS connects and wakes the app. [iOS]
- **State restoration.** When iOS ends a background app that holds a Bluetooth connection, it relaunches the app in the background for the next event. The app has to create its central manager with the same restore identifier while launching. [iOS]
  - This doesn't apply when the user swipes the app away in the app switcher: iOS won't relaunch it until the user opens it again. Mi Fitness has the same limit. [iOS]
  - A relaunch in the background has no window, so whatever owns the central manager must be created when the app launches, not when the first screen appears. [iOS]
- **Timers.** Timers don't run while the app is suspended; a retry timer fires when the app next runs. [iOS]
- **Sound.** The phone can ring in two ways [iOS]:
  - **Audio.** The `audio` background mode, with an `AVAudioSession` in the `.playback` category, plays with the ring/silent switch on, at the media volume. A non-mixable session can't be activated from the background, so the session uses `.duckOthers`, which mixes with other audio and lowers it.
  - **A local notification with a sound.** This follows the silent switch and Focus. Critical Alerts would get past both, but need an entitlement from Apple.

## 4. Freeband's design

- **The setting.** Stay connected (Band tab) is off by default and applies to the selected band.
- **The held session.** It authenticates like any session and sets the clock. It reads the device info and worn state, then stays open with no time limit and no polling. Battery and live stats are left to the sync, so a held session adds no records.
- **Other sessions.** Sync, Notify, Live HR and the key check pause the hold. Freeband lets go of the held session and waits 1 s. It then runs the session as before and opens the hold again 2 s after that session ends.
- **Going to the background.** With Stay connected on, the app asks iOS for up to 20 s more (a background task) and opens the hold right away if nothing else runs. The 2 s wait and the retries are timers, and a suspended app runs no timers (section 3). Once the hold has asked for its connection, Bluetooth events wake the app for the rest.
- **When the hold drops.**
  - Disconnected, or not connected in iOS: Freeband opens it again right away. When iOS has no connection to the band, that is a pending connection to the band it knows (section 3), so nothing polls.
  - Any other failure: it retries after 10 s, 30 s, 1 min and 2 min, then every 5 min. A wrong key waits 5 min.
  - Bluetooth off: it retries when Bluetooth comes back on.
- **Ringing.**
  - The phone plays a tone made in code: two short beeps a second, looped, so no sound file is needed. It also vibrates every 2 s.
  - A notification ("Your watch is looking for this phone") with a Stop action shows too. Tapping it, its Stop action, or clearing it stops the ringing.
  - In the app, a full-screen Stop button shows.
  - Ringing stops on the band's stop, on Stop in the app or the notification, or after 2 minutes. When it stops on the phone, the phone sends the stop in section 1 so the band can close its screen.
- **The log.** Diagnostics keeps the last 600 lines across sessions instead of only the last session, so what happened on the held session is still there after a sync. While holding, every command from the band is logged as `← held t/s`. The log lives in memory: `— app started` marks a new process, and `restored by iOS` a relaunch for the held session. When Stay connected is on but can't start, the log says why (`stay connected: no band`, `no key`).

## 5. Limits

- The band can only reach the phone while the hold is open. Find Phone doesn't work after the user swipes Freeband away, while Bluetooth is off, or while another session runs. In those cases the hold reopens within a few seconds when Freeband next runs.
- Ringing is at the media volume. If that volume is at zero, only the notification and the vibration are left.
- Mi Fitness can't sync while Stay connected is on.

## 6. To check on the watch

1. A `2/17` arrives on the held session: the log line `← find phone: ring`, with the message's bytes. Checked, section 7.
2. Cancelling on the watch sends a stop (`← find phone: stop`). Checked, section 7. Stopping on the phone closes the watch's Find Phone screen: it doesn't (section 7). Still open: the watch's own stop has the same bytes as the phone's, and the watch acknowledges the phone's stop (`← 0052 acknowledged` right after `→ find phone: stop`).
3. The session stays open for hours in the background, or the band drops it after some idle time. A newer Gadgetbridge than the one Freeband's notes started from adds a `wakeLink` that sends a battery request "so an idle link is awake". [CODE] `SYS:933-939` This hints that an idle link can need waking. [UNVERIFIED] Partly checked: after some hours locked and idle, Find Phone still rang (section 7). A whole night is not checked yet.
4. Ringing from the background, with the screen locked, and with the silent switch on. Checked, section 7.
5. What else the band sends while the session is idle: the `← held` lines.
6. On a Band 10 (BLE V2), the same: the held session is the same code on the V2 channel. [UNVERIFIED]

## 7. Checked on the watch

Xiaomi Watch S1 Active, model `M2116W1`, firmware `1.4.174`, 2026-11-09, app in the foreground, Mi Fitness closed.

| What | Result |
|---|---|
| The held session | opens 2 s after a sync ends, authenticates, sets the clock; the watch answers with device info (`2/2`) and state (`2/78`) [MEASURED] |
| Find Phone started on the watch | a `2/17` of 8 bytes arrives on the held session; the phone rings [MEASURED] |
| Cancelled on the watch | a `2/17` of 8 bytes arrives, read as stop; the phone goes quiet [MEASURED] |
| Stopped on the phone | the phone sends `2/17` with `findDevice = 1`; nothing comes back and the watch's Find Phone screen stays open until it is cancelled on the watch [MEASURED]. Gadgetbridge sends the same message (section 1). |
| Phone locked, silent switch on | the phone rings and vibrates; the notification shows. Stopping on the watch and with the notification's Stop both work [MEASURED] |
| Mi Fitness on iOS | showed no notification or stop control for the watch's Find Phone, open or closed, so there is nothing to compare the phone's stop with [MEASURED]. Stay connected may have been on during that test, which keeps Mi Fitness off the channel. [UNVERIFIED] |
| The hold after a sync, phone locked | opened a minute after the sync instead of 2 s, with nothing about the hold at launch: either the app was suspended before its 2 s timer, or the hold didn't start when the app launched. The background task and the log lines in section 4 came from this. [MEASURED] |
| Some hours locked and idle | Find Phone from the watch still rang the phone, without opening Freeband first [MEASURED, reported 2026-11-12]. A whole night is not tested yet. |

Freeband keeps sending the stop: it costs one message, and it may close the screen on other bands. [UNVERIFIED]
