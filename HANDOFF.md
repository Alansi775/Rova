# ROVA — build and run on this Mac, then keep going

## What this is

An iPhone app for Istanbul's İETT buses. Its one rule: **it never shows
something it cannot stand behind.** No invented coordinates, no schedule
dressed up as live tracking, no countdown that keeps ticking on a dead GPS
fix. If the data is not there, the app says so.

Everything below has been built and tested; some of it has not yet been
tried on a real bus.

## Step 1 — get it running

```bash
git clone https://github.com/Alansi775/Rova.git
cd Rova/ios
brew install xcodegen          # if not present
xcodegen generate
```

Open `ios/ROVA.xcodeproj` once in Xcode and set signing: the project uses
automatic signing, so pick a team under Signing & Capabilities for both the
`ROVA` and `ROVAWidget` targets. Then:

```bash
xcrun devicectl list devices          # find the iPhone's UDID
xcodebuild -scheme ROVA -configuration Release \
  -destination 'id=<UDID>' -derivedDataPath /tmp/rova \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  /tmp/rova/Build/Products/Release-iphoneos/ROVA.app
```

Run the tests before changing anything — 131 should pass:

```bash
xcodebuild test -scheme ROVA \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Step 2 — the backend is optional

`ios/ROVA/Resources/backend.json` is gitignored and will be missing. **The app
works without it**: it reads İETT's SOAP service directly. The backend only
adds wider coverage and WebSocket push.

To use it, create that file:

```json
{ "url": "https://<your-tunnel>.trycloudflare.com", "token": "<64-hex>" }
```

The token must match `ROVA_DEVICE_TOKEN` in `backend/.env`. Auth is
`Authorization: Bearer <token>` — not a custom header.

## What already works

- **Real route geometry.** İETT publishes route alignments as GeoJSON on
  İstanbul's open data portal (the SOAP services do not — their WSDLs expose
  only stops, lines and garages). 2 868 of 2 876 patterns are covered and
  imported into the bundled SQLite by `tools/build-shapes.py`. Routes are no
  longer stitched from Apple Maps *driving* directions.
- **Progress follows the rider once aboard.** Boarding is detected, not
  declared: the rider's own position on the route, past the boarding stop.
  Start is the only button; there is deliberately no "I am on this bus".
- **Spoken stop announcements** through headphones, with a generated chime,
  two stops out / one stop out / at the stop. Off by default.
- **Live Activity** on the Lock Screen and Dynamic Island.
- Background `audio` + `location`, raised only for the duration of a ride.
- Manual refresh that says "no newer position yet" when İETT has not
  published again, rather than looking successful every time.

## What is NOT done — the next job

The rider's design, in his words, for the bottom of the map:

1. **A horizontal carousel of bus cards.** One card centred, the neighbours
   peeking at the left and right edges. Each card is Liquid Glass
   (`.buttonStyle(.glass)`, `GlassEffectContainer`), showing line number, door
   number (e.g. `B2249`), arrival, the existing `RefreshVehicleButton`, and
   Start. **Nearest/soonest bus first.**
2. **Map and carousel are two views of one selection.** Tapping a bus on the
   map scrolls the carousel to its card; swiping to a card moves the map to
   that bus. Haptic feedback on each swipe.
3. **After Start, the other cards go away** and one card shows the trip, with
   the stop list visible without pulling the sheet up.
4. **Show every line that reaches the destination.** A rider watched a bus
   arrive that would have got him there sooner and was not on the map at all.
   Check `JourneyPlanner.plan` and the map's pattern filter in
   `JourneyEngine.mapVehicles`.

Also open: `/v1/accuracy` still reports `sampleSize: 0` for lack of settled
predictions, and İETT's fleet-wide endpoint (`GetFiloAracKonum_json`, one
request, ~6 900 vehicles, no line code, joinable by door number) is measured
and documented in issue #7 but not yet used.

## How to work on it

Read `IMPLEMENTATION_LOG.md` and the recent commit messages first — they
record *why* things are the way they are, including several wrong turns worth
not repeating.

Hold the project's rule. If a value cannot be verified, say so in the UI
instead of filling the gap. Several of the worst bugs here were not crashes
but confident displays of things that were not true: a marker gliding on a
dead fix, a countdown stuck at "2 minutes" for an hour, a route drawn under
the words "no live bus". Prefer silence to a plausible guess.

Write a test for anything you fix, and run the whole suite before you build.
