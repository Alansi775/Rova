# ETA_ENGINE

How ROVA decides that your bus is seven minutes away — and how sure it is.

The engine exists twice, deliberately: in Swift
(`ios/ROVA/ETA/ETAEngine.swift`) so the phone works without a server, and in
TypeScript (`backend/src/eta/eta.service.ts`) so predictions can be logged and
scored. The two implementations follow the same five steps and are covered by
parallel test suites.

---

## Step 0 — what we start with

From one İETT fix:

```
door no, lat, lon, line code, güzergah code, son_konum_zamani
```

From the bundled network, for that güzergah:

```
[(seq, stop_code, offset_sec)]   — the ordered stop list with
                                   scheduled seconds from trip start
[(lat, lon)]                     — the same stops as a polyline
```

---

## Step 1 — route matching

The fix is projected onto the pattern polyline
(`Geo.snap`): a local equirectangular projection, then a per-segment
point-to-segment solve. It returns the segment index, the position `t` within
it, the perpendicular **offset**, and the distance **along** the route.

Two rules keep GPS noise and misreported routes out:

* **offset > 450 m → the vehicle is discarded**, not guessed at. A bus whose
  fix is half a kilometre from the route it claims to run is not information.
* **projected position past the boarding stop → discarded.** ROVA never counts
  down a bus that has already gone by.

When the vehicle's own `guzergahkodu` matches a pattern that serves the stop,
only that pattern is tried. Otherwise every pattern of that line serving the
stop is tried and the earliest plausible result wins.

---

## Step 2 — travel time from the timetable, not from speed

The base estimate is the **scheduled time still to run along this route**:

```
vehicleOffset  = interpolate(offset_sec[i], offset_sec[i+1], t)
remaining      = offset_sec[stopIndex] − vehicleOffset
```

This is the single most important design decision in ROVA.

Dividing straight-line distance by instantaneous speed is wrong in a city: it
ignores stop spacing, dwell time at each door, traffic lights, and the fact
that the next three kilometres are an arterial while the three after that are
a market street. İETT's own timetable for *that specific güzergah* already
encodes all of it, averaged over real operation and varying by time of day.

So ROVA asks "how much of this trip is left, in timetable terms?" and then
corrects that with what it can actually observe.

---

## Step 3 — correction from observed progress

If the same vehicle has been watched for at least 90 seconds on the same
pattern:

```
factor = elapsed_real_seconds / elapsed_scheduled_seconds
```

A bus that covered 90 s of timetable in 180 s of clock time is running at
`factor = 2.0`. The factor is clamped to `[0.55, 1.9]` — beyond that the
measurement is more likely to be a GPS artefact than a traffic jam — and
multiplies the base estimate.

Without two usable fixes the factor is omitted entirely rather than assumed,
and the confidence drops to `medium` with the reason *"Not enough movement
observed yet."*

---

## Step 4 — staleness

The fix describes where the bus **was**, `age` seconds ago. It has been moving
since. So:

```
seconds = max(0, scheduledRemaining × factor − age)
```

and a floor of `25 s × stopsAway` is applied, because a bus physically cannot
serve six stops in forty seconds.

Age also widens the range and lowers confidence. It is never hidden: the UI
shows *"GPS 32s ago"* next to every live countdown.

---

## Step 5 — range and confidence

```
spread  = 0.14 × seconds + 45
        × 1.25            if progress was never measured
        + 0.6 × age
        + 12 × max(0, stopsAway − 6)
        + 0.25 × offRouteMetres
```

The range widens with horizon (a 40-minute prediction deserves less precision
than a 4-minute one), with staleness, with the number of stops still to serve,
and with how well the fix matched the route.

Confidence is assigned by the first rule that matches:

| Condition | Confidence | Reason shown to the user |
|---|---|---|
| fix older than 300 s | `low` | "Last GPS fix is N minutes old" |
| more than 250 m off route | `low` | "Vehicle is N m off the published route" |
| horizon over 45 min | `low` | "The bus is still far from your stop" |
| fix older than 120 s | `medium` | "GPS fix is N s old" |
| more than 12 stops away | `medium` | "N stops away — traffic can still change this" |
| no observed progress | `medium` | "Not enough movement observed yet" |
| horizon over 20 min | `medium` | "Long horizon" |
| otherwise | `high` | — |

**Anything below `high` must carry a reason.** This is asserted in the live
integration test, not left to discipline.

---

## Data states

Separate from confidence, and about the *feed* rather than the *prediction*:

| Age of fix | State | Colour |
|---|---|---|
| < 75 s | `Live GPS` | green |
| 75–180 s | `Recently updated` | amber |
| > 180 s | `Delayed data` | red |
| no vehicle | `Scheduled only` | grey |
| provider down / rate limited | `Live location unavailable` | grey |

The word *live* appears only in the first case.

---

## Example response

```json
{
  "vehicleId": "A-1539",
  "routeId": "146",
  "patternId": "146_G_D6038",
  "stopCode": "177182",
  "predictedArrivalMinutes": 25.4,
  "arrivalRangeMinutes": { "minimum": 14, "maximum": 36.9 },
  "lastGpsUpdateSeconds": 97,
  "confidence": "medium",
  "lowConfidenceReason": "31 stops away",
  "source": "live_vehicle_position",
  "remainingMetres": 10424,
  "stopsAway": 31,
  "offRouteMetres": 30
}
```

This is a real response, produced by the running backend on 2026-11-12 at
04:49 Istanbul from the live position of İETT vehicle A-1539. Note the honest
range: half an hour out, ROVA will not pretend to know the minute.

---

## Measurement

Claiming accuracy without data would violate the point of the project, so
accuracy is computed from stored outcomes only.

**Recording.** Every prediction served with `?record=true` is written to
`eta_predictions` with its predicted arrival instant, range, fix age and
confidence.

**Settling.** Every two minutes, `PredictionsService.settle()` looks for the
first fix of that vehicle within **80 m** of the stop in
`vehicle_position_history`, and stores it as `actual_arrival` with the signed
`error_seconds`.

**Reporting.** `GET /v1/accuracy` returns:

* mean absolute error
* median absolute error
* % within ±2 minutes
* % within ±5 minutes
* GPS freshness distribution (median, p90)
* the same, broken down per line

When nothing has settled yet it returns `sampleSize: 0` and a note saying
accuracy cannot be reported — which is the honest answer, and the one it
returns today:

```json
{ "sampleSize": 0,
  "note": "No resolved predictions yet — accuracy cannot be reported." }
```

**ROVA currently makes no accuracy claim.** Leave the backend running with
`INGEST_ENABLED=true` across a few days of real travel and the numbers will
exist. Until then there is nothing to quote.

---

## What the engine deliberately does not do

* It does not use traffic data. No reliable free traffic feed for these
  corridors was found, and inventing one would defeat the purpose.
* It does not extrapolate a vehicle's position forward on the map. Markers
  move only between two genuine fixes.
* It does not keep counting down a bus that disappeared from the feed; the
  vehicle drops out and the UI falls back to the next one or to the timetable.
* It does not average across vehicles. Each bus gets its own estimate, and the
  list is ordered by arrival with each one's confidence attached.
