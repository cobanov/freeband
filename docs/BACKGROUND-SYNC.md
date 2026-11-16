# Background sync

The optional **Sync in background** switch under Band → Connection and data is off by default and applies to the selected band. Freeband requests an iOS app refresh and also tries when a held session authenticates or the band reports a state change while the app is in the background. It waits at least 15 minutes after a completed sync. This is a minimum, not an interval iOS promises: background refresh, Bluetooth, battery, system scheduling and force-quitting can prevent or delay a run. See Apple's [background task documentation](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app) and [Bluetooth restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).

A sync uses the ordinary band session, activity import and optional Apple Health export. Stay connected is independent; a sync pauses its held session and reopens it afterwards. When iOS ends the opportunity, Freeband stops its own session and pauses the Health export. Its persisted ledger allows pending writes to be retried when the app opens or at a later background opportunity. A completed band sync and a completed Apple Health export have separate status indicators.

## Try it on an iPhone

1. Build and run the app, add a real band, turn on **Sync in background**, and optionally enable Apple Health. Keep the band nearby and close Mi Fitness.
2. Sync once, lock the phone and leave the app in the background for more than 15 minutes. iOS chooses when to run it, so this may take considerably longer. Compare the band's last-sync time and the Apple Health status after reopening the app.
3. With Stay connected enabled, move the band out of range and bring it back after the minimum interval. Repeat with Bluetooth disabled, then enabled. Verify manual sync and Find Phone still work.
4. Inspect Settings → Diagnostics → Share log for `background sync: started`, `finished`, `incomplete`, `time expired or disabled`, or a reason for skipping. After a force-quit, open Freeband again before expecting further background work. Test with Background App Refresh disabled too.

No background-sync behavior has been measured on a device yet; the checks above require an iPhone and a band. [UNVERIFIED]
