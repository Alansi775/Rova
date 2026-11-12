# IPHONE_INSTALLATION

## Status: ROVA is already installed on your iPhone

Done on 2026-11-12 from this Mac — nothing is left for you to do to start
using it.

| | |
|---|---|
| Device | **Mohamed's iPhone** — iPhone 12 Pro, iOS 27.2 |
| UDID | `00008101-000529043A78001E` |
| Bundle id | `com.msgone.rova` |
| Configuration | Release |
| Signing | Automatic — *Apple Development: Mohammed Saleh (7DF7XVYYMD)* |
| Team | `7UM534HHV5` |
| Installed | ✅ `App installed: com.msgone.rova` |
| Launched | ✅ `Launched application with com.msgone.rova bundle identifier` |

**Open ROVA from your Home Screen and allow location when it asks.** That is
the only prompt.

---

## What to expect on first open

1. A dark splash: the ROVA chevrons, the wordmark, *MOVE WITH CERTAINTY*.
   It lasts only as long as the transit bundle takes to open — there is no
   artificial delay.
2. The map, already framed on **Şafak Residence → Avcılar Metrobüs**.
3. iOS asks for location. Choose **Allow While Using App** — it is used to
   pick your nearest boarding stop and to centre the map.
4. iOS asks about notifications. Allowing lets ROVA tell you when to leave.
5. The sheet shows the best journey. Drag it up for the vehicle detail, the
   timetable and the step-by-step.

Before the first buses run (roughly 05:00–06:00) ROVA will say
**"No vehicle is reporting a GPS position on this line yet"** and show the
timetable. That is correct behaviour, not a failure — once İETT starts
publishing positions the card switches to a live countdown with a green
**LIVE** badge.

---

## Rebuilding and reinstalling

```bash
cd ~/Projects/ROVA/ios
xcodegen generate                        # only if project.yml changed

xcodebuild -project ROVA.xcodeproj -scheme ROVA \
  -destination 'platform=iOS,id=00008101-000529043A78001E' \
  -configuration Release -allowProvisioningUpdates build

xcrun devicectl device install app --device 00008101-000529043A78001E \
  ~/Library/Developer/Xcode/DerivedData/ROVA-*/Build/Products/Release-iphoneos/ROVA.app

xcrun devicectl device process launch --device 00008101-000529043A78001E com.msgone.rova
```

To check the device is connected:

```bash
xcrun devicectl list devices
```

---

## The 7-day limit

This is a free-provisioning development build, so iOS will stop launching it
about **seven days** after signing. There is no warning — the icon simply
refuses to open.

**To extend it:** connect the iPhone and run the three commands above again.
It takes under a minute and keeps your settings, because the bundle id does
not change.

**To remove the limit permanently:** a paid Apple Developer Program
membership ($99/year) raises provisioning-profile validity to a year. Nothing
in the project needs to change — the same team id already signs it.

---

## If something goes wrong

**"Untrusted Developer" when you tap the icon**
Settings → General → VPN & Device Management → *Apple Development: Mohammed
Saleh* → **Trust**.

**`devicectl` cannot see the phone**
Unlock it, connect by cable, and tap **Trust This Computer**. Then
`xcrun devicectl list devices` again.

**The app opens but the map is empty**
Settings → Privacy & Security → Location Services → ROVA → *While Using the
App*. The journey itself still plans without location; only the blue dot and
"nearest stop to me" need it.

**It says "Live location unavailable"**
İETT is rate limiting (100 requests/hour per caller) or its service is down.
ROVA backs off for ten minutes and keeps showing the timetable. Nothing to
fix on your side — see [DATA_SOURCES.md](DATA_SOURCES.md).

**No buses at all on any line**
Check the hour. İETT's first departures on this corridor are between 04:00
and 06:00; outside service hours the feed is genuinely empty.

---

## Changing the journey

Everything is editable in the app, no rebuild needed:

* Tap **Şafak Residence** or **Avcılar Metrobüs** in the bar at the top to
  search for a different place.
* Tap anywhere on the map to drop a pin and set it as start or destination.
* Tap the ⇅ button to swap them.
* Settings (the slider icon) → **Reset to Şafak Residence → Avcılar Metrobüs**
  to come back.
