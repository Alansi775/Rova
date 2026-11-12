# ROVA

**MOVE WITH CERTAINTY.**

A personal, native iPhone app for real İETT bus travel in Istanbul. It answers
one question honestly: *when should I leave the house to catch my bus?*

ROVA tracks actual vehicle positions published by İETT, matches them to the
route they are running, and estimates arrival at **your** boarding stop — with
an explicit confidence level and the age of the GPS fix. When there is no live
vehicle, it says so and falls back to the timetable rather than pretending.

First configured journey: **Şafak Residence (Esenyurt) → Avcılar Metrobüs**.

---

## The rule this project is built on

**ROVA never presents estimated data as confirmed.** Every number on screen
carries its source, its age and its confidence. When the data goes quiet, the
app says so. It does not invent a bus position, it does not run a marker ahead
of the last published fix, and it does not describe a timetable as live
tracking.

That constraint is the design, not a disclaimer. Two examples of what it cost:

- **Motion smoothing was removed after it shipped.** Extrapolating a marker
  forward at the vehicle's measured speed looked smoother — until the next fix
  arrived showing the bus had been sitting in traffic, and the marker jumped
  *backwards*. From the pavement that reads as the app lying. The marker now
  only ever eases toward a position İETT has actually published.
- **A stationary bus used to get the engine's most optimistic estimate.** The
  progress factor divides real progress by *scheduled* progress; a parked bus
  has made none, so the ratio returned nil, the factor fell back to 1.0, and
  the estimate dropped onto the raw timetable — "2 minutes", unchanged, for an
  hour. Standing still is now detected against the ground and the app refuses
  to give a countdown at all.

---

## What is in the box

```
ROVA/
├── ios/              Native Swift / SwiftUI app (the product)
├── backend/          NestJS + PostgreSQL service (ingestion, ETA, accuracy)
├── tools/            Transit-bundle builder, measurement scripts
├── data/             Raw İETT + İBB Open Data downloads (gitignored)
└── docs              ARCHITECTURE · API · DATA_SOURCES · ETA_ENGINE
                      DEPLOYMENT · IPHONE_INSTALLATION · IMPLEMENTATION_LOG
```

The iPhone app is **self-sufficient**. It ships with the whole İETT network
(15 141 stops, 782 lines, 2 876 route variants, 134 293 scheduled departures)
in a 15 MB SQLite bundle and calls the official İETT fleet service directly.
It needs no server, no account and no internet beyond İETT itself.

The backend is optional and exists for the things a phone should not do:
continuous ingestion, position history, and **measuring** whether ROVA's
predictions were right.

---

## Quick start

### iPhone app

```bash
cd ios
xcodegen generate                       # regenerate ROVA.xcodeproj
open ROVA.xcodeproj                     # or build from the command line:

xcodebuild -project ROVA.xcodeproj -scheme ROVA \
  -destination 'platform=iOS,id=<your-device-udid>' \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <your-device-udid> \
  ~/Library/Developer/Xcode/DerivedData/ROVA-*/Build/Products/Debug-iphoneos/ROVA.app
```

See [IPHONE_INSTALLATION.md](IPHONE_INSTALLATION.md) for the exact, verified steps.

### Tests

```bash
# iOS — 37 tests (4 of them hit the real İETT service)
cd ios && xcodebuild test -project ROVA.xcodeproj -scheme ROVA \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

# Backend — 28 unit tests
cd backend && npm test

# Backend — live integration against api.ibb.gov.tr (not mocked)
cd backend && ROVA_LIVE_TESTS=1 npx jest live --runInBand
```

### Backend

```bash
cd backend
cp .env.example .env            # then set ROVA_DEVICE_TOKEN
createdb rova
npm install
npx ts-node src/db/migrate.ts   # schema
npx ts-node src/db/seed.ts      # network data from the iOS bundle
npm run start:dev
curl localhost:3111/health/detail
```

See [DEPLOYMENT.md](DEPLOYMENT.md).

### Rebuilding the transit bundle

```bash
python3 tools/build_bundle.py    # reads data/raw + data/gtfs-iett
```

---

## Honesty rules ROVA follows

These are enforced in code and covered by tests, not just stated here.

| Situation | What ROVA shows |
|---|---|
| GPS fix < 75 s old | **Live GPS** + countdown |
| 75–180 s old | **Recently updated** |
| > 180 s old | **Delayed data**, never "live" |
| No vehicle reporting | **Scheduled only** — next timetable departure, labelled as such |
| Vehicle > 450 m off its route | Discarded, not shown |
| Vehicle already past your stop | Discarded, not counted down |
| İETT rate limit hit | **Live location unavailable** with the reason |

ROVA never generates a coordinate, a vehicle id or a timestamp. Every bus you
see on the map came from `GetHatOtoKonum_json` with its own İETT door number
and its own `son_konum_zamani`.

---

## Known limitations

* **İETT rate limit** — the fleet service allows 100 requests/hour. ROVA polls
  the line you are watching once a minute (the rate at which İETT itself
  refreshes) and other lines far less often. See [DATA_SOURCES.md](DATA_SOURCES.md).
* **No GTFS-Realtime** — İBB publishes no GTFS-RT feed for İETT; the SOAP
  service is the only live source and it carries positions, not trip updates.
* **Route geometry follows stops** — the İETT GTFS export has no `shapes.txt`,
  so a route line is drawn through its real stop sequence. Walking legs use
  genuine MapKit pedestrian geometry.
* **No PostGIS** — spatial work is done in application code; see
  [ARCHITECTURE.md](ARCHITECTURE.md) for why and how to add it later.
* **Metrobüs itself is not live** — İETT's fleet service covers buses. Avcılar
  Metrobüs is handled as the destination stop, not as a tracked line.
