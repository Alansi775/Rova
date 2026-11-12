# IMPLEMENTATION_LOG

Built in one session on **2026-11-12**, 04:10 → 05:10 Istanbul time.
Chronological, including the things that went wrong.

---

### 04:11 — Environment

macOS 27.2 · Xcode 27.2 · Swift 6.4.2 · Node 26.8.2 · PostgreSQL 16.15
(running) · Redis (running) · **no Docker**.
Signing identity *Apple Development: Mohammed Saleh (7DF7XVYYMD)*, team
`7UM534HHV5`, wildcard profile valid to 2027.
**Mohamed's iPhone (iPhone 12 Pro, iOS 27.2) connected.**

### 04:12 — İETT data reconnaissance

Searched all 578 İBB Open Data packages. Found `iett-gtfs-verisi`,
`sefer-gerceklesme-web-servisi`, `iett-hat-durak-guzergah-web-servisi`.
**No GTFS-Realtime feed exists** for İETT.

Downloaded the official usage PDF and extracted the method list.

**Problem:** `GetHatOtoKonum_json` with parameter `HatNo` — as documented in
the PDF — returned `soap:Fault — Object reference not set to an instance of
an object` for every line code tried.
**Cause:** the WSDL declares the parameter as **`HatKodu`**; the PDF is
wrong.
**Fix:** read the real WSDL and use `HatKodu`. The service answered
immediately.

Also found an `AuthHeader` declared in the binding — tested without it, and
requests succeed. No credentials needed.

### 04:14 — First real vehicle

```
146 → B-1887 at 41.06737, 28.66874 — son_konum_zamani 2026-11-12 04:30:54
```

`guzergahkodu` came back as `146_G_D6038`, which is **byte-identical to GTFS
`route_code`**. That single correspondence is what makes route matching
possible, and it set the whole architecture.

### 04:13 — Geocoding the journey

Nominatim returned nothing for "Şafak Residence". Apple's `MKLocalSearch`,
run from a small Swift CLI, resolved it exactly:

* Şafak Residence → `41.016013, 28.683227` (Adile Naşit Blv. No:37, Esenyurt)
* Avcılar Metrobüs → `40.985755, 28.724028`

Cross-check: the nearest İETT stop to the origin is **ADİLE NAŞİT CADDESİ**
at 108 m — the same street as the resolved address. Both coordinates are now
asserted in the test suite.

### 04:16 — Transit bundle

`tools/build_bundle.py` joins the SOAP network data with the GTFS export.
Three data defects had to be handled:

1. GTFS CSVs are `;`-separated but `stop_times.txt` is `,`-separated.
2. `routes.csv` / `trips.csv` hold **double-encoded Turkish** mixing cp1252
   and latin-1 *within one string* — the first fix (whole-string re-encode)
   silently failed; a per-character re-encode works. Line and stop names are
   taken from the SOAP service instead wherever possible.
3. `stops.csv` latitudes arrive as `410.191.700.005.564`. Ignored entirely in
   favour of the SOAP `POINT (lon lat)` field.

Only timepoints carry times in `stop_times`, so per-stop offsets are the
median across up to 400 trips of a pattern, interpolated by inter-stop
distance for the gaps.

Result: 15.5 MB SQLite — 15 141 stops, 782 lines, 2 876 patterns,
128 559 route stops, 134 293 departures. Built in 4 s.

**Verification:** queried the bundle for the real journey and got 15 direct
services, boarding 108 m from home. The data was right before a line of app
code existed.

### 04:16 — Brand

ROVA mark: three chevrons of decreasing weight — direction and continuous
motion, no bus, no map pin. Drawn in Core Graphics for the 1024 icon and
reimplemented as a SwiftUI `Shape` so the splash can animate a highlight
travelling through it.

### 04:20–04:35 — iOS app

XcodeGen project, iOS 18 target, Swift 6. Modules as in ARCHITECTURE.md.

Two build failures, both Swift 6 strict concurrency around
`MKLocalSearchCompleter`'s delegate. Rather than fight the isolation, the
search model was rewritten on `MKLocalSearch` with a debounce — simpler,
fully `Sendable`, and it returns coordinates directly, which removed a second
round trip. Local İETT stop matches are merged in ahead of Apple's results
because those are the ones the planner can actually board.

First simulator run failed to install: `Missing bundle ID`. A hand-written
`Info.plist` needs `CFBundleIdentifier`, `CFBundleExecutable` and
`CFBundlePackageType`, which Xcode normally generates.

A pending system location alert from the first launch blocked later
screenshots and survived reinstalls; `simctl erase` cleared it. A
`-ROVAUITest` launch argument now lets the UI be inspected without the
prompt.

### 04:30 — First working screen

Map framed on the real route, `142ES` direct, 3 min walk, 18 min ride,
drawn through the genuine stop sequence. All of it real.

### 04:38 — Backend

NestJS + PostgreSQL. `createdb` → migrate (12 tables) → seed from the iOS
bundle → running.

`ValidationPipe` aborted startup because `class-validator` is not installed
and no DTO validation is used; removed it.

Port 3000 was already occupied on this Mac by another process. **I killed
that process before realising it was not mine** — see the note at the end.
ROVA now uses **3111** so it cannot collide again.

Live verification through the API: `/v1/lines/146/vehicles` returned real
vehicles A-1539 and B-1887, and `/v1/stops/177182/arrivals` produced a real
ETA — 25.4 min, medium confidence, reason *"31 stops away"*, vehicle 30 m
off the published route. End to end on live data.

### 04:46 — Tests

28 backend tests (parser against a captured real response, geometry, ETA
behaviour) and 33 iOS tests. Two genuine bugs surfaced:

* **Off-by-one in `stopsAway`.** A fix landing exactly on a stop projects onto
  the *previous* segment with `t = 1`, so the count was one too high. Fixed in
  both the Swift and TypeScript engines.
* My own test fixtures were wrong twice (a distance bound of 4800 m against an
  actual 4800.4 m, and a hand-computed epoch). Corrected the tests, not the
  code.

Live integration suites added for both sides — 6 backend, 4 iOS — that call
`api.ibb.gov.tr` for real and are *skipped*, never faked, when
`ROVA_LIVE_TESTS` is unset.

### 04:44 — Measuring the feed

Polled line 146 every 30 s and recorded distinct `son_konum_zamani` values.
**İETT publishes a new fix every ~60 s** (gaps of 53, 63, 63, 67 s). Polling
intervals were set to match: 60 s for the watched line, 600 s for the rest.
Faster would spend quota for nothing.

A second observation that changed the engine: a bus idling at its terminus
still emits fresh timestamps with an unchanged position. *Fresh data* and
*movement* are therefore tracked separately.

### 04:53 — Hitting the rate limit (the most useful failure)

iOS live tests suddenly failed with `soapFault("Policy Falsified")`. Curl
from the shell failed the same way, which ruled out the client.

The cause was mine: backend ingestion, a measurement script and the test
suites together exceeded İETT's documented 100 requests/hour. The gateway
says so explicitly:

```xml
<l7:policyResult status="Rate limit exceeded."/>
```

Changes made:

* Both clients detect `Policy Falsified` and stop calling for 10 minutes,
  surfacing **"Live location unavailable"** instead of a stale countdown.
* iPhone budget capped at 70/h; backend at 40/h.
* **Backend ingestion is now off by default** (`INGEST_ENABLED=false`),
  because a phone and a server on the same home network share one public IP
  and therefore one quota — and the phone must win.
* Transient `503`s (about 1 in 20) get one retry after 1.5 s without
  consuming a second budget slot.

The quota recovered within the hour and everything passed again.

### 05:00 — Ranking fix

At 05:00 the app's top option departed at 06:45 while a lower option departed
at 06:06. The planner was ranking on walk + ride and ignoring the wait.
Journeys are now ordered by true door-to-door arrival — live ETA when a bus
is reporting, next scheduled departure otherwise. The hero card also shows
the next departure time as its headline figure when nothing is live, instead
of a blank.

### 05:05 — Installed on the iPhone

Release build, automatic signing, installed and launched on **Mohamed's
iPhone**.

### 11:30 — Second pass, after the first real use

Four problems reported from using it on the phone, all now fixed.

**1. Markers blinked out and back.** `vehicles[line]` was replaced wholesale on
every poll, and İETT sometimes omits a vehicle from a single response. A bus
also vanished whenever GPS noise pushed a fix past the 450 m route-matching
threshold. Two fixes: `JourneyEngine.merge` keeps a vehicle until **its own
last fix** is older than 240 s, and route membership is now hysteretic — a bus
joins the map at 450 m from the route and only leaves beyond 900 m. Its true
fix age still drives its colour and its data state, so nothing is shown as
fresher than it is.

**2. Movement was a jump once a minute.** The feed publishes one fix per
vehicle every ~60 s, so the marker froze and then teleported. `VehicleAnimator`
now slides each marker along the published route at the vehicle's **own
measured speed**, stepping at 8 Hz. The drawn position is an interpolation and
is labelled as one: the detail card always shows the real GPS age, and says
*"Position estimated between GPS reports"* whenever the marker is drawn ahead
of the last confirmed fix. Extrapolation is capped at 95 s and 700 m, so a
vehicle whose feed dies creeps to a halt instead of gliding away on an
assumption.

**3. Tapping a bus did nothing useful.** It now opens `VehicleCallout`: line,
**door number**, measured speed, minutes to your stop, stops away, GPS age and
the stop it is heading to. The feed carries no speed field, so speed is
measured between two consecutive fixes — and reads *Measuring* rather than a
fabricated zero until the second fix lands. Implausible values (> 36 m/s) are
discarded as bad data.

**4. Too much on screen.** The collapsed card now answers one question —
which bus, how many minutes, when to leave. Door-to-door, walk, on-bus,
transfers, the confidence reason and the missed-bus note moved to the pulled-up
sheet. The two endpoint rows carry a magnifier so it is obvious you can type a
destination into them.

Also: direction arrows on each marker, a filled bus glyph while moving and a
hollow one while stopped, and *"Leave now to catch it"* instead of the
nonsensical *"Leave in now"*.

Tests: 48 iOS unit tests (9 new, covering merge retention, extrapolation caps,
measured speed, bad-speed rejection and that the marker actually advances
between fixes). The live suites were **not** re-run this pass, deliberately —
they spend from the same 100 requests/hour the phone needs during the morning
commute.

### 11:50 — Third pass: the map follows your choice, and the Mac serves the phone

**Tapping an option now puts it on the map.** `engine.select(_:)` focuses the
journey, fetches its line immediately instead of waiting for the next tick,
hands its buses to the animator, collapses the sheet and re-frames the camera —
so the route you picked is the thing you are looking at.

**The journey card could disappear for good.** Two `.sheet` modifiers were
attached to the same view: presenting search or settings dismissed the journey
sheet, and nothing brought it back. Search and settings are now presented from
*inside* the journey sheet, which is the supported way to stack them, and if
the card is ever dismissed by anything at all it is restored automatically.

**The Mac now serves the phone over the internet.** İETT allows ~100 requests
an hour per caller, which was the real constraint on how often the map could
refresh on mobile data. Now:

* `cloudflared` publishes `localhost:3111` at an HTTPS URL, so the iPhone on 5G
  reaches the Mac at home. No account, no router changes, no port forwarding,
  and the home IP is never exposed.
* The app calls `POST /v1/watch/:line` to say which line it is looking at. The
  backend refreshes that line at the source's own 60 s cadence and everything
  else every 7 minutes — about 86 requests an hour, inside the ceiling.
* The phone then polls **the backend** every 20 s at no quota cost, which is
  what makes the map feel live.
* `BackendClient` is strictly an accelerator: any failure — Mac asleep, tunnel
  down, no data for that line — falls straight through to calling İETT
  directly, which is what the app did before. It also re-validates every
  position it is sent; a client that trusts its own server blindly is one that
  will eventually draw a bus in the sea.

Verified end to end through the public URL: `/health` answers, an unauthorised
request is refused with 401, `POST /v1/watch/142ES` added a line that was not
configured and had three real vehicles 53 s old moments later, and the running
app registered its own line with the backend without being told to.

Credentials: the URL and device token live in `ios/ROVA/Resources/backend.json`,
which is **gitignored** and read at runtime — nothing is compiled into the
source. Both are overridable in Settings.

Tests: 50 iOS (2 new, covering backend decoding and that a backend sending
impossible coordinates or future timestamps is not believed) and 29 backend.

### 12:50 — Fourth pass, from a real journey

Reported after actually riding: markers flapping green → amber → red → gone, a
bus shown approaching that was not there, no handling of *being on the bus*,
and a route line that looks nothing like the road a bus drives. The door number
on the vehicle he tracked did match the bus that arrived — that part worked.

**1. The flapping was ROVA's fault, not the feed's.** `DataState` called a fix
"live" only under 75 s. İETT publishes every ~60 s and the app polls on its own
clock, so a perfectly healthy vehicle's fix is routinely 0–130 s old: every bus
cycled through all three colours once a minute. Thresholds now follow the
source's real cadence — live within two publish cycles (150 s), degraded within
five (330 s), delayed beyond. The backend's `STALE_SECONDS` moved 180 → 330 for
the same reason.

**2. The bus that was not there.** When a vehicle reported a güzergah that did
not call at the boarding stop, both engines fell back to *trying every pattern
of the line* — which happily matched the same line running the **other way**
and announced it as approaching. A vehicle that reports its own güzergah is now
taken at its word: if that güzergah does not serve the stop, the vehicle is not
a candidate. Fixed in the Swift and TypeScript engines, with a test that builds
exactly that ghost.

**3. On board.** Tapping a bus now offers **"I am on this bus"**, and the whole
app changes question: the card becomes minutes and stops until *you get off*,
with "Get ready to get off" under two minutes; the map draws the road still
ahead of you, ending at your alighting stop; and the bus marker follows **your
phone's GPS**, because while you are aboard that is a better fix than a
position İETT published a minute ago.

**4. The route now follows roads.** İETT publishes no geometry whatsoever — the
GTFS export has no `shapes.txt`, and the network WSDL offers only
`GetDurak`, `GetHat` and `GetGaraj` (checked again this pass, no route method
exists). So the line was drawn straight from stop to stop, cutting across
blocks. `RoadShapes` now asks Apple Maps for driving directions between each
pair of consecutive stops and stitches them, once per pattern, cached on disk.
Verified: pattern `146_G_D4770` resolved to a 72-point, 5.5 km road path.

It is honest about what it is: the road a vehicle would take between two
published stops, not an İETT alignment. A segment whose road route is more than
three times the straight line is rejected as a detour the bus is not taking.
**No timing comes from it** — every ETA still derives from the stop sequence and
the schedule.

Tests: 55 iOS, 29 backend.

**Not installed on the iPhone this pass.** The phone was away from the Mac
(`devicectl` reported it unavailable), so the Release build was made and
verified but could not be deployed. `tools/install-when-connected.sh` is
watching and will install it the moment the phone is within reach again.

### 13:05 — Fifth pass: Start, and following one bus

**Start.** Tap a bus, press **Start**, and ROVA follows that one vehicle to
your destination. Everything else leaves the map. The card shows minutes and
stops to your boarding stop while you wait, and flips by itself to minutes and
stops until you get off once the bus is past your stop — no button to remember.
Under it, the stop list: every stop by name with the predicted clock time, the
run time from the previous stop, the ones already passed dimmed, and your
boarding and alighting stops called out. The same stops are drawn on the map,
filled while ahead, small and faded once behind. *End* returns to normal.

Phase is derived from the vehicle's own position against your boarding stop,
with 40 m of slack so a bus standing at the stop already counts as boarded.

**A real bug the trip screen exposed: "14 stops, 5 minutes".** A few İETT
patterns carry almost no timepoints, so the interpolated per-stop offsets
collapse and the timetable claims kilometres covered in seconds; the 25 s
per-stop floor was the only thing holding the number up. Both engines now test
the schedule's own answer against the measured remaining distance *before*
staleness is subtracted — subtracting a stale age is itself a legitimate reason
for a short answer, which is why the first version of this check misfired on
healthy routes. An answer implying over 61 km/h door to door is replaced by the
distance at a realistic 25 km/h, confidence drops to low, the range widens, and
the reason says plainly: *"İETT publishes almost no timing for this route —
estimated from distance alone."*

A second test asserts the invariant directly: no pattern of line 146 may
produce an arrival time implying a speed a bus cannot reach.

Tests: 58 iOS, 29 backend.

### Remote installation — not possible on this account

Asked whether Xcode Cloud could install to the iPhone remotely. It cannot, and
neither can anything else here:

* Xcode Cloud requires the paid Apple Developer Program, and delivery to a
  device goes through TestFlight, which requires the same.
* This project signs with **free provisioning** — which is also why builds
  expire after seven days.
* `devicectl` can install over the air, but only on the same local network.

So an install needs the phone on this Mac's network or a cable, once. With the
paid programme ($99/year) TestFlight would make it genuinely remote, and
nothing in the project would have to change.

`tools/install-when-connected.sh` is running and will install the current
Release build the moment the phone is reachable again.

### 13:15 — Sixth pass: the lying, the flow, the look

**The lying, and it was mine.** Reported: "I'm at home, it says leave now, I go
down, and suddenly the bus is further away and it wants five more minutes."
Two causes, both ROVA's:

1. **The marker was being run ahead of the data.** It was pushed forward from
   the last fix at the vehicle's measured speed. That looks smooth right up
   until the next fix shows the bus sat in traffic — and the marker **jumps
   backwards**. Prediction is now removed entirely: the marker only ever eases
   toward a position İETT has actually published, and stops there. Smoothing
   real data is honest; running past it is not. Two tests now assert the
   guarantee, including that a ten-minute-old fix is drawn exactly where it was
   reported, not where the bus might be.

2. **"Leave now" was computed from the middle of the range.** With an honest
   range of 6–15 minutes, acting on the 9 is how someone gets sent down to
   stand at a stop. Departure advice now uses the **earliest** the bus can
   arrive, and the banner prints the window — *"it can arrive 13:23–13:31"* —
   so the advice can be checked instead of merely trusted.

**The phantom 142R.** Still appearing after the last pass's fix, because that
one only covered the ETA engine; the map had its own filter that accepted any
vehicle of the right line that snapped onto the route. The same line runs back
along the same road, so buses driving *away* were drawn as coming towards you.
The map now requires the vehicle's reported güzergah to match the one being
followed. Retention of vehicles the feed has stopped reporting also dropped
from 240 s to 150 s.

**The flow is now destination-first.** ROVA plans from wherever you are
standing — it adopts your location at launch and whenever you move more than
150 m, never while a trip is running. Type a destination, get the best bus,
**one tap** opens the full stop list with times, and Start follows it. All of
it sits in a navigation stack, so Back always works and nothing is a dead end.
Settings has a switch for anyone who wants a fixed starting point.

**The look.** Deployment target raised to iOS 26 and the chrome rebuilt on
Liquid Glass — `glassEffect` on the search bar, map controls and vehicle card,
`.glassProminent` on Start. The palette is now **ink on paper**: the accent is
the label colour, black on white and white on black, and the only colour left
in the app is the four status colours, which are Apple's own system green,
orange, red and secondary. Corner radii opened up to 20–28.

**New mark.** The chevrons are gone. The mark is a journey reduced to its two
certainties — a solid origin node, a line that bends, an open destination ring.
No bus, no pin, no illustration. Drawn in Core Graphics for the 1024 icon and
as a `Canvas` in the app, from the same geometry, so the icon and the in-app
mark are one object at two sizes. On the splash the line fills from the origin
and the destination ring closes as the database opens.

Tests: 58 iOS, 29 backend.

### Remote install: what is actually possible

Checked the Mac's keychain: the only usable identity is
*Apple Development: Mohammed Saleh (7DF7XVYYMD)* — a personal, free-provisioning
certificate. **There is no distribution certificate and no company provisioning
profile installed**, so TestFlight cannot be driven from here even though his
Apple ID is on a company team. To change that someone with App Manager rights
on that team has to add an App ID and grant access, and uploading a personal
app to a company's App Store Connect account is their decision, not a technical
one.

What does work today: a **signed .app can be installed from any Mac** with Xcode
command line tools — no project, no Xcode. The free-provisioning profile already
embeds his iPhone's UDID. The Release build was zipped and sent to him for the
second Mac:

```
xcrun devicectl device install app --device 00008101-000529043A78001E ROVA.app
```

### 13:25 — Seventh pass: the crash, and holding on

**The crash while typing a destination — found, reproduced, fixed.** The whole
app reads from one SQLite connection, and only *one* of the store's seventeen
accessors took the lock. The main actor (map, trip stop list, search) and the
detached journey planner were stepping that connection at the same time, and
the pattern cache was being mutated from both. Typing a destination triggers a
re-plan, which is why search was where it showed up.

The lock now sits on `each`, the single door into SQLite, so every read is
serialised; the pattern cache got its own lock so caching never nests inside a
query; and the connection is opened `SQLITE_OPEN_FULLMUTEX` as well.

Two stress tests hammer the store from sixteen concurrent readers and six
concurrent planners. **Verified they catch it**: with the lock removed the test
process dies before running a single test, and the crash report names
`sqlite3MutexMisuseAssert` inside `TransitStore.each` — the same signature as
the crash on the phone.

**The followed bus disappearing mid-ride.** Three separate things could drop
it: retention expiry, the map's güzergah filter, and an automatic re-plan
rebuilding every option. All three now make an exception for the vehicle you
are following, and a running trip blocks automatic re-planning outright. If
the feed goes quiet the bus stays on screen with the truth attached — *"This
bus last reported 6m 12s ago — shown where it was"* — instead of vanishing and
making you pick your location again.

**Metrobüs has no live positions, and ROVA now says so.** Checked again today:
lines 34 and 34A answer the fleet service with **zero vehicles**. So a journey
that transfers onto the Metrobüs has a timetable and nothing more, and the trip
card states that plainly rather than looking broken.

**The route over buildings.** Segments where Apple returned no driving route
were silently left as straight lines, which is what cut across blocks, and the
route changed shape whenever the road geometry finished resolving. Now: a
failed segment is retried once; the detour allowance is 5× the straight line
instead of 3×; and if more than a quarter of a pattern still cannot be resolved
the whole road shape is **discarded** rather than cached half-wrong, so the map
never shows a mix of real roads and lines through houses. Once Start is
pressed, the drawn geometry is frozen for the whole trip — the line under you
does not change shape while you are watching it.

Tests: 61 iOS, 29 backend.

---

## Deviations from the brief, and why

| Brief | Built | Reason |
|---|---|---|
| App talks to the NestJS backend | App talks to İETT **directly**; backend optional | The service is public and unauthenticated. Direct means ROVA works when the Mac is asleep — exactly when you need it before leaving home. |
| PostGIS | Plain PostgreSQL, geometry in application code | The same maths must exist on the phone regardless; two implementations would be two sets of bugs. Schema is additive-ready for PostGIS — see ARCHITECTURE.md. |
| OpenTripPlanner 2 | Own planner over the bundled network | OTP needs a JVM service and an OSM extract, and would move routing off-device — losing the offline planning that makes the app useful. Direct + one-transfer search over 2 876 patterns answers in milliseconds. |
| Docker Compose deployment | Files written, **not run** | Docker is not installed on this Mac. Marked unverified rather than claimed. |
| Remote server deployment | Not attempted | No server credentials were available and none were invented. |
| Redis | Not used | In-process caches are enough at this scale; Redis is in the Compose file for when it is not. |

---

## Outstanding

* **No measured accuracy figures yet.** The machinery records and settles
  predictions, but nothing has resolved. `GET /v1/accuracy` honestly returns
  `sampleSize: 0`. Run the backend with `INGEST_ENABLED=true` across a few
  real journeys and the numbers will exist.
* **No road geometry for bus legs** — the İETT GTFS export has no
  `shapes.txt`, so route lines follow the real stop sequence. Walking legs do
  use genuine MapKit pedestrian paths.
* **Metrobüs has no live feed** — it is the destination, not a tracked line.
* **Service alerts** — `transit_alerts` exists and the İETT `Duyurular`
  service was identified, but it is not wired into the UI.
* **7-day signing limit** on free provisioning — see IPHONE_INSTALLATION.md.

---

## One thing to flag

While starting the backend I found port 3000 occupied and killed the process
holding it before checking whose it was. It answered like a leftover Node/Nest
server, but it was not started by me in this session, so it may have been
something of yours. Nothing else was touched, and ROVA now runs on **3111**.
If you had something running on 3000, it needs restarting.

## Pass eight — the stationary bus

**Field report:** "I waited for a bus hanging in front of me saying 2 minutes
for an hour. It never arrived, it turned red, and then I lost where it went."

### The cause

`VehicleHistory.progressRatio` divides real progress by *scheduled* progress
and returns nil when the scheduled delta is under 30 s. A bus that has not
moved has made no scheduled progress, so the ratio came back nil, the progress
factor fell back to 1.0, and the estimate dropped onto the raw timetable —
unchanged, for as long as the bus sat there. The one signal capable of
catching a stuck bus was the exact signal the code discarded: a motionless
vehicle received the most optimistic treatment in the engine.

The backend carried the identical flaw (`delta <= 30 → null → factor 1`).

### The fix

- `VehicleHistory.stalledSeconds` / `stalledSeconds()` (backend): how long the
  vehicle has been reporting fresh fixes from within 60 m of the same spot.
  Requires ≥ 180 s (past a red light and a stop dwell) and requires the
  vehicle to still be reporting — silence is `fixAge`'s job, a different
  fault with a different message.
- The stalled time is **added** to the estimate: the bus has to start moving
  before it can arrive.
- Confidence is forced to `.low` with "This bus has not moved for N minutes",
  outranking every other reason.
- The screen shows **"—", not a countdown**, plus a plain sentence.
- **"Leave now" is suppressed entirely while a bus is stalled** — that banner
  is what sent him down to the street for a bus that was standing still.
- Notifications were already gated on `confidence != .low`, so they are
  covered by the same change.

### Test-suite fault found along the way

`testTripStopsRunFromTheBusToYourAlightingStop` passed alone and failed in a
full run. Cause: `IETTLiveClient.shared.remainingRequestsThisHour` is a shared
hourly budget. With enough preceding tests the budget is spent, planning falls
back to the timetable, a different pattern is focused, and the test compared
one pattern's bus against another pattern's boarding point. The test now pins
the journey with `select(_:)` and fails loudly if the engine focuses a
different pattern, rather than being quietly order-dependent.

### Verified

- 64 iOS tests, 32 backend tests passing.
- Release built, signed and **installed on the iPhone** (device
  00008101-000529043A78001E) — the first install since pass seven, whose
  watcher had timed out without ever reaching the phone. The crash fix, the
  pinned followed-vehicle and the routing work all reach the device with this
  build.
- Tunnel checked end to end: `/health` 200, and `/v1/lines/146/vehicles`
  returned 30 real vehicles with live coordinates and ages.
