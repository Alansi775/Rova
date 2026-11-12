# ARCHITECTURE

## The shaping decision

The brief asked for an iPhone client talking to a NestJS backend. Partway
through, one fact changed the shape of the system:

> İETT's fleet service is **public, unauthenticated, and rate limited to 100
> requests per hour**.

A phone can call it directly. And a phone that calls it directly keeps working
when the Mac is asleep, when you are on cellular in Esenyurt, and when the
backend is down — which is exactly when you need to know whether to leave the
house.

So ROVA is built the other way round from the usual:

```
┌──────────────────────────── iPhone ─────────────────────────────┐
│  SwiftUI · MapKit                                               │
│  JourneyPlanner ─┐                                              │
│  ETAEngine ──────┼── TransitStore (15 MB SQLite, bundled)       │
│  IETTLiveClient ─┘                                              │
└───────┬─────────────────────────────────────────┬───────────────┘
        │ SOAP, ≤70 req/h                          │ optional
        ▼                                          ▼
  api.ibb.gov.tr/iett                      ROVA backend (NestJS)
  FiloDurum/SeferGerceklesme.asmx          ├── IngestionService
                                           ├── EtaService
                                           ├── PredictionsService ← accuracy
                                           ├── TrackingGateway (WS)
                                           └── PostgreSQL
```

The backend is not a proxy the app depends on. It is the part of the system
that does what a phone should not: poll continuously, keep position history,
and **measure whether ROVA's predictions were right**. The app has a
configurable backend URL in Settings and works with the field empty.

A consequence worth stating: when both the phone and the backend run on the
same home network they share one public IP and therefore one İETT quota.
Backend ingestion is therefore `INGEST_ENABLED=false` by default.

---

## iOS app

Swift 6 · SwiftUI · MapKit · deployment target iOS 18, built with Xcode 27.

```
ios/ROVA/
├── App/            ROVAApp, SplashView, RootView, JourneyEngine,
│                   Settings, LocationService
├── DesignSystem/   Theme (colour, type, spacing), Marks (logo), Format
├── Models/         Stop, BusLine, Pattern, Vehicle, DataState,
│                   Confidence, ETA, JourneyLeg/Option, LiveJourney
├── Data/           TransitStore (SQLite), Geo (projection, snapping)
├── Live/           IETTLiveClient (SOAP + budget), Notifications
├── Planner/        JourneyPlanner
├── ETA/            ETAEngine, VehicleHistory
├── Map/            JourneyMapView, markers, WalkRouteCache
├── Features/       Routes (sheet), Search, Settings
└── Resources/      rova-transit.sqlite, Assets.xcassets
```

**Pattern.** MVVM with a single observable coordinator. `JourneyEngine` is the
only `@MainActor` object that mutates journey state; views read published
properties. `IETTLiveClient` is an `actor`, so the request budget and cache
cannot race. `TransitStore` is read-only after load and therefore shareable.

**Rendering discipline.** Vehicle markers are keyed by door number, so a
position update re-renders those annotations and nothing else. The route
polyline is rebuilt only when the selected journey changes. The one-second
clock in the sheet drives only the text that actually counts down.

### The bundled network

`tools/build_bundle.py` produces `rova-transit.sqlite` (15.5 MB):

| Table | Rows | Source |
|---|---|---|
| `stop` | 15 141 | İETT `GetDurak_json` (authoritative names and WKT coordinates) |
| `line` | 782 | İETT `GetHat_json` |
| `pattern` | 2 876 | GTFS `routes.route_code`, terminus name taken from the last stop |
| `pattern_stop` | 128 559 | GTFS `stop_times`, with interpolated `offset_sec` |
| `departure` | 134 293 | GTFS trip start times per service |
| `service` | 3 | GTFS `calendar` |

Bundling rather than fetching means: no cold start, no network dependency for
planning, and no server to keep alive. The cost is that a network change needs
a new build — acceptable for a feed republished a few times a year.

---

## Backend

NestJS 10 · TypeScript · PostgreSQL 16 · `ws`.

| Module | Responsibility |
|---|---|
| `DbModule` | `pg` pool, health ping |
| `NetworkService` | loads the static network into memory (~15 k stops) |
| `IettClient` | SOAP client, request budget, retry, rate-limit detection, exponential backoff |
| `IngestionService` | round-robin polling, validation, persistence, retention, health |
| `EtaService` | server-side twin of the on-device engine |
| `PredictionsService` | records predictions, settles them against history, reports accuracy |
| `TrackingGateway` | authenticated per-line WebSocket push |
| `HealthController` | unauthenticated liveness + detailed provider health |

### Why there is no PostGIS

The brief asked for PostGIS. ROVA does not use it, and this is a deliberate,
reversible choice:

* The only spatial operations needed are *point → polyline projection* and
  *great-circle distance*. Both are ~40 lines of arithmetic and run in
  microseconds on data this size.
* The identical computation has to exist on the phone anyway, where PostGIS
  does not. Two different implementations of route matching — one in SQL, one
  in Swift — would be two sets of rounding behaviour and two sets of bugs.
  Instead there are two ports of the same algorithm with parallel tests.
* Homebrew's PostGIS does not build against the installed `postgresql@16` on
  this machine without a server upgrade, which is a poor trade for arithmetic
  that is already written.

**Migration path if it is wanted later:** add
`ALTER TABLE transport_stops ADD COLUMN geom geography(Point,4326)` and a
`route_geom` column on `transit_patterns`, backfill from the existing lat/lon
columns, and replace `NetworkService.nearStops` / `snap` with
`ST_DWithin` / `ST_LineLocatePoint`. No table needs to be dropped — the schema
was written with plain lat/lon doubles precisely so this is additive.

### Retention

`vehicle_position_history` has primary key `(door_no, source_time)`, so a
frozen feed inserts nothing: duplicate fixes collapse instead of accumulating.
An hourly job deletes history older than `POSITION_HISTORY_HOURS` (default 72)
and ingestion logs older than 7 days. `vehicle_positions` holds exactly one
row per vehicle.

### Security

No accounts, no login, no registration — but nothing is open either. Every
`/v1/*` route and every WebSocket session requires the private
`ROVA_DEVICE_TOKEN` (compared in constant time). `/health` is unauthenticated
and returns no transit data.

`DeviceTokenGuard` is the only place that knows how a caller is identified, so
multi-user support later is a change to that one class plus a tokens table —
not a rewrite of the controllers.

Secrets live in `.env`, which is gitignored; `.env.example` documents every
variable and contains no values.

---

## Data flow for one refresh

1. `JourneyEngine.tick()` fires every 10 s and picks the single most overdue
   line — the watched line at 60 s, others at 600 s. One line per tick means
   the quota can never be spent in a burst.
2. `IETTLiveClient.vehicles(line:)` checks its 20 s cache, then the sliding
   budget, then the throttle flag, then calls SOAP.
3. The response is parsed; records with impossible coordinates, missing or
   future timestamps, or duplicate `(door, time)` pairs are dropped.
4. Each accepted fix is appended to that vehicle's `VehicleHistory`.
5. `recompute()` runs the ETA engine for the first bus leg of every journey
   option and publishes `[(option, bestETA, alternatives)]`.
6. SwiftUI updates the affected markers and the countdown. Nothing else
   redraws.

---

## Testing

| Suite | Count | Nature |
|---|---|---|
| `backend/test/parsing.spec.ts` | 8 | parser contract against a captured real response |
| `backend/test/geo.spec.ts` | 6 | projection and distance |
| `backend/test/eta.spec.ts` | 14 | ETA behaviour, staleness, ranking |
| `backend/test/live.integration.spec.ts` | 6 | **real calls to api.ibb.gov.tr** |
| `ios/ROVATests/ROVATests.swift` | 33 | bundle integrity, verified coordinates, planner, parser, ETA, formatting |
| `ios/ROVATests/LiveIntegrationTests.swift` | 4 | **real calls from the app's own client**, end to end |

The live suites are skipped — not faked — when `ROVA_LIVE_TESTS` is unset, so
an offline run can never report a false pass.
