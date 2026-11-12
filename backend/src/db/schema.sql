-- ROVA schema (PostgreSQL 16).
--
-- Geometry is stored as plain lat/lon doubles and all spatial work is done in
-- the application layer. PostGIS is not required for this deployment; see
-- ARCHITECTURE.md for the reasoning and the migration path if it is added.

CREATE TABLE IF NOT EXISTS transport_routes (
  line_code     TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  length_km     DOUBLE PRECISION,
  trip_minutes  DOUBLE PRECISION,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transport_stops (
  stop_code   TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  lat         DOUBLE PRECISION NOT NULL,
  lon         DOUBLE PRECISION NOT NULL,
  district    TEXT,
  direction   TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_stops_latlon ON transport_stops (lat, lon);

CREATE TABLE IF NOT EXISTS transit_patterns (
  pattern_id  TEXT PRIMARY KEY,
  line_code   TEXT NOT NULL,
  direction   TEXT,
  headsign    TEXT,
  stop_count  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_patterns_line ON transit_patterns (line_code);

CREATE TABLE IF NOT EXISTS route_stops (
  pattern_id  TEXT NOT NULL,
  seq         INTEGER NOT NULL,
  stop_code   TEXT NOT NULL,
  offset_sec  INTEGER NOT NULL,
  PRIMARY KEY (pattern_id, seq)
);
CREATE INDEX IF NOT EXISTS ix_route_stops_stop ON route_stops (stop_code);

CREATE TABLE IF NOT EXISTS transit_trips (
  pattern_id  TEXT NOT NULL,
  service_id  TEXT NOT NULL,
  start_sec   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_trips_pattern ON transit_trips (pattern_id, service_id, start_sec);

CREATE TABLE IF NOT EXISTS vehicles (
  door_no     TEXT PRIMARY KEY,
  line_code   TEXT,
  pattern_id  TEXT,
  first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Latest known position per vehicle (one row per vehicle, upserted).
CREATE TABLE IF NOT EXISTS vehicle_positions (
  door_no       TEXT PRIMARY KEY,
  line_code     TEXT NOT NULL,
  pattern_id    TEXT,
  lat           DOUBLE PRECISION NOT NULL,
  lon           DOUBLE PRECISION NOT NULL,
  source_time   TIMESTAMPTZ NOT NULL,   -- İETT's son_konum_zamani
  received_at   TIMESTAMPTZ NOT NULL,   -- when ROVA fetched it
  near_stop     TEXT,
  stale         BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS ix_positions_line ON vehicle_positions (line_code);

-- Distinct observed fixes. Duplicates (same door + same source_time) are
-- rejected by the primary key, so a stalled feed does not inflate the table.
CREATE TABLE IF NOT EXISTS vehicle_position_history (
  door_no      TEXT NOT NULL,
  source_time  TIMESTAMPTZ NOT NULL,
  line_code    TEXT NOT NULL,
  pattern_id   TEXT,
  lat          DOUBLE PRECISION NOT NULL,
  lon          DOUBLE PRECISION NOT NULL,
  received_at  TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (door_no, source_time)
);
CREATE INDEX IF NOT EXISTS ix_history_time ON vehicle_position_history (source_time);

CREATE TABLE IF NOT EXISTS transit_alerts (
  id          BIGSERIAL PRIMARY KEY,
  line_code   TEXT,
  severity    TEXT NOT NULL,
  message     TEXT NOT NULL,
  starts_at   TIMESTAMPTZ,
  ends_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Every prediction ROVA makes, so accuracy can be measured rather than claimed.
CREATE TABLE IF NOT EXISTS eta_predictions (
  id                 BIGSERIAL PRIMARY KEY,
  door_no            TEXT NOT NULL,
  line_code          TEXT NOT NULL,
  pattern_id         TEXT,
  stop_code          TEXT NOT NULL,
  predicted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  predicted_arrival  TIMESTAMPTZ NOT NULL,
  range_low_min      DOUBLE PRECISION,
  range_high_min     DOUBLE PRECISION,
  fix_age_sec        DOUBLE PRECISION,
  confidence         TEXT NOT NULL,
  source             TEXT NOT NULL,
  actual_arrival     TIMESTAMPTZ,
  error_seconds      DOUBLE PRECISION
);
CREATE INDEX IF NOT EXISTS ix_pred_open ON eta_predictions (door_no, stop_code)
  WHERE actual_arrival IS NULL;
CREATE INDEX IF NOT EXISTS ix_pred_line ON eta_predictions (line_code, predicted_at);

CREATE TABLE IF NOT EXISTS journey_search_history (
  id          BIGSERIAL PRIMARY KEY,
  origin_lat  DOUBLE PRECISION NOT NULL,
  origin_lon  DOUBLE PRECISION NOT NULL,
  dest_lat    DOUBLE PRECISION NOT NULL,
  dest_lon    DOUBLE PRECISION NOT NULL,
  searched_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ingestion_log (
  id            BIGSERIAL PRIMARY KEY,
  line_code     TEXT NOT NULL,
  at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  ok            BOOLEAN NOT NULL,
  vehicles      INTEGER NOT NULL DEFAULT 0,
  stale         INTEGER NOT NULL DEFAULT 0,
  rejected      INTEGER NOT NULL DEFAULT 0,
  latency_ms    INTEGER,
  error         TEXT
);
CREATE INDEX IF NOT EXISTS ix_ingest_at ON ingestion_log (at DESC);
