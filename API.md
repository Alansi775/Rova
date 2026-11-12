# API

Base URL in development: `http://localhost:3111`

Every `/v1/*` route requires the private device token:

```
Authorization: Bearer <ROVA_DEVICE_TOKEN>
```

`/health*` is unauthenticated and exposes no transit data.

All timestamps are ISO-8601 UTC. All coordinates are WGS84.

---

## GET /health

Liveness probe.

```json
{"service":"rova-backend","version":"1.0.0","status":"up",
 "time":"2026-11-12T01:39:40.841Z"}
```

---

## GET /health/detail

Provider and ingestion health. `liveTrackingHealthy` is true **only** when a
line has valid positions whose own source timestamps are younger than 180 s —
the backend never reports healthy live tracking for a feed that has stopped
moving.

```json
{
  "status": "ok",
  "database": "up",
  "network": { "loaded": true, "stops": 15141, "patterns": 2876 },
  "provider": {
    "name": "İETT FiloDurum/SeferGerceklesme — GetHatOtoKonum_json",
    "hourlyRequestsRemaining": 59,
    "lines": [
      {
        "lineCode": "146",
        "lastSuccessfulFetch": "2026-11-12T01:48:49.733Z",
        "latestSourceTimestamp": "2026-11-12T01:47:52.000Z",
        "latestSourceAgeSeconds": 80,
        "validPositions": 2,
        "stalePositions": 0,
        "rejectedRecords": 0,
        "error": null,
        "liveTrackingHealthy": true
      }
    ],
    "anyLineHealthy": true
  },
  "time": "2026-11-12T01:49:10.000Z"
}
```

`error` carries the provider's own message, e.g.
`"İETT rate limit reached (Policy Falsified) — backing off 10 min"`.

---

## GET /v1/lines/:line/vehicles

Latest validated position per vehicle on a line.

```
curl -H "Authorization: Bearer $TOKEN" localhost:3111/v1/lines/146/vehicles
```

```json
{
  "lineCode": "146",
  "count": 2,
  "vehicles": [
    {
      "vehicleId": "A-1539",
      "patternId": "146_G_D6038",
      "position": { "lat": 41.084543, "lon": 28.6758011666667 },
      "sourceTime": "2026-11-12T01:47:52.000Z",
      "receivedAt": "2026-11-12T01:48:49.733Z",
      "ageSeconds": 86,
      "nearStopCode": "301651",
      "stale": false
    }
  ]
}
```

`vehicleId` is İETT's own door number. `sourceTime` is İETT's
`son_konum_zamani`; `receivedAt` is when ROVA fetched it. The difference
between the two is how long ROVA itself added to the latency.

---

## GET /v1/stops/:stop/arrivals

ETA for every live vehicle approaching a stop.

| Query | Default | Meaning |
|---|---|---|
| `line` | all ingested lines | restrict to one line code |
| `record` | `false` | `true` stores the top 3 predictions for accuracy measurement |

```
curl -H "Authorization: Bearer $TOKEN" \
  "localhost:3111/v1/stops/177182/arrivals?line=146&record=true"
```

```json
{
  "stopCode": "177182",
  "stopName": "PARK",
  "generatedAt": "2026-11-12T01:49:28.896Z",
  "arrivals": [
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
  ]
}
```

When no vehicle qualifies the array is empty and a `note` explains why:

```json
{ "stopCode": "177182", "arrivals": [],
  "note": "No vehicle with a valid GPS position is currently approaching this stop on the requested lines." }
```

An empty `arrivals` means exactly that — it is never padded with timetable
rows dressed up as arrivals.

`confidence` is `high | medium | low`. Anything below `high` carries
`lowConfidenceReason`.

**400** — unknown stop code.

---

## GET /v1/stops/near

| Query | Default |
|---|---|
| `lat`, `lon` | required |
| `radius` | `600` (metres) |

```json
{ "stops": [
  { "stopCode": "130661", "name": "ADİLE NAŞİT CADDESİ", "district": "Esenyurt",
    "lat": 41.0151580005557, "lon": 28.6825989999754, "distanceMetres": 109 }
]}
```

---

## GET /v1/accuracy

Measured prediction accuracy. Optional `?line=146`.

With resolved predictions:

```json
{
  "sampleSize": 128,
  "meanAbsoluteErrorSeconds": 96,
  "medianAbsoluteErrorSeconds": 71,
  "within2MinutesPercent": 78.9,
  "within5MinutesPercent": 95.3,
  "gpsFreshnessSeconds": { "median": 48, "p90": 132 },
  "byLine": { "146": { "sampleSize": 83, "medianAbsoluteErrorSeconds": 64,
                       "within2MinutesPercent": 81.9 } }
}
```

*(shape only — ROVA has not yet accumulated a sample)*

Without:

```json
{ "sampleSize": 0,
  "note": "No resolved predictions yet — accuracy cannot be reported.",
  "meanAbsoluteErrorSeconds": null, "medianAbsoluteErrorSeconds": null,
  "within2MinutesPercent": null, "within5MinutesPercent": null,
  "gpsFreshnessSeconds": null, "byLine": {} }
```

---

## WebSocket /ws

```
ws://localhost:3111/ws
```

Server greets:

```json
{ "type": "hello", "authRequired": true }
```

Client authenticates, then subscribes:

```json
{ "type": "auth", "token": "<ROVA_DEVICE_TOKEN>" }
{ "type": "subscribe", "lines": ["146", "142"] }
```

An unauthenticated socket is closed with code `4001`. Updates are pushed only
for subscribed lines, so a bus on a line you are not watching costs the client
nothing:

```json
{
  "type": "vehicles",
  "lineCode": "146",
  "at": "2026-11-12T01:48:49.733Z",
  "vehicles": [
    { "vehicleId": "A-1539", "patternId": "146_G_D6038",
      "position": { "lat": 41.084543, "lon": 28.675801 },
      "sourceTime": "2026-11-12T01:47:52.000Z", "ageSeconds": 86 }
  ]
}
```

---

## Errors

| Status | Meaning |
|---|---|
| 400 | malformed or unknown parameter |
| 401 | missing or invalid device token |
| 500 | unexpected server error |

Provider problems are **not** errors: they are reported in the body of a 200
(`note`, empty `arrivals`) or in `/health/detail`, so the client can tell the
difference between "ROVA is broken" and "İETT has nothing to say right now".
