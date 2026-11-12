#!/usr/bin/env python3
"""ROVA transit bundle builder.
Produces a compact SQLite database from:
  - IETT UlasimAnaVeri SOAP (authoritative stops + lines)
  - IBB Open Data IETT GTFS (patterns, stop sequences, schedules)
Output: ios/ROVA/Resources/rova-transit.sqlite
"""
import csv, html, json, os, re, sqlite3, sys, math, unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "data", "raw")
GTFS = os.path.join(ROOT, "data", "gtfs-iett")
OUT = os.path.join(ROOT, "ios", "ROVA", "Resources", "rova-transit.sqlite")

def soap_payload(path, tag):
    raw = open(path, encoding="utf-8").read()
    m = re.search(r"<%s>(.*)</%s>" % (tag, tag), raw, re.S)
    return json.loads(html.unescape(m.group(1)))

def fix_mojibake(s):
    """routes/trips CSVs hold UTF-8 bytes that were mis-read as cp1252 then
    re-encoded as UTF-8. Undo it character by character (mixed codecs)."""
    if not s or all(ord(c) < 0x80 for c in s):
        return s
    out = bytearray()
    for ch in s:
        if ord(ch) < 0x80:
            out.append(ord(ch))
            continue
        for enc in ("cp1252", "latin-1"):
            try:
                out += ch.encode(enc)
                break
            except Exception:
                continue
        else:
            out += ch.encode("utf-8")
    try:
        return out.decode("utf-8", "strict")
    except Exception:
        return s


def read_semicolon(path, mojibake=False):
    with open(path, encoding="utf-8-sig", newline="") as f:
        rdr = csv.DictReader(f, delimiter=";")
        for row in rdr:
            if mojibake:
                row = {k: (fix_mojibake(v) if isinstance(v, str) else v) for k, v in row.items()}
            yield row

def hav(a, b, c, d):
    R = 6371000.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = p2 - p1, math.radians(d - b)
    x = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(x))

# ---------------------------------------------------------------- stops / lines
print("· reading IETT stops …")
stops_api = soap_payload(os.path.join(RAW, "duraklar.raw"), "GetDurak_jsonResult")
WKT = re.compile(r"POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)")
stops = {}
for s in stops_api:
    m = WKT.match((s.get("KOORDINAT") or "").strip())
    if not m:
        continue
    lon, lat = float(m.group(1)), float(m.group(2))
    if not (40.6 < lat < 41.7 and 27.5 < lon < 30.2):
        continue
    code = str(s["SDURAKKODU"]).strip()
    stops[code] = dict(code=code, name=(s.get("SDURAKADI") or "").strip(),
                       lat=lat, lon=lon, district=(s.get("ILCEADI") or "").strip(),
                       direction=(s.get("SYON") or "").strip(),
                       smart=(s.get("AKILLI") == "VAR"))
print(f"  {len(stops)} stops")

print("· reading IETT lines …")
lines = {}
for l in soap_payload(os.path.join(RAW, "hatlar.raw"), "GetHat_jsonResult"):
    code = (l.get("SHATKODU") or "").strip()
    if not code:
        continue
    lines[code] = dict(code=code, name=(l.get("SHATADI") or "").strip(),
                       length_km=float(l.get("HAT_UZUNLUGU") or 0),
                       trip_min=float(l.get("SEFER_SURESI") or 0),
                       fare=(l.get("TARIFE") or "").strip())
print(f"  {len(lines)} lines")

# ------------------------------------------------- GTFS stop_id -> IETT code
print("· mapping GTFS stop ids …")
gtfs_stop = {}
for r in read_semicolon(os.path.join(GTFS, "stops.csv")):
    sid = (r.get("stop_id") or "").strip()
    code = (r.get("stop_code") or "").strip()
    if sid and code in stops:
        gtfs_stop[sid] = code
print(f"  {len(gtfs_stop)} mapped")

# ---------------------------------------------------------------- GTFS routes
print("· reading GTFS routes …")
routes = {}
for r in read_semicolon(os.path.join(GTFS, "routes.csv"), mojibake=True):
    rid = (r.get("route_id") or "").strip()
    code = (r.get("route_code") or "").strip()
    if not rid or not code:
        continue
    parts = code.split("_")
    routes[rid] = dict(pattern=code, line=(r.get("route_short_name") or parts[0]).strip(),
                       direction=parts[1] if len(parts) > 1 else "",
                       headsign=(r.get("route_long_name") or "").strip(),
                       note=(r.get("route_desc") or "").strip())
print(f"  {len(routes)} route patterns")

print("· reading GTFS trips …")
trip_route = {}
for r in read_semicolon(os.path.join(GTFS, "trips.csv"), mojibake=True):
    tid = (r.get("trip_id") or "").strip()
    rid = (r.get("route_id") or "").strip()
    sid = (r.get("service_id") or "").strip()
    if tid and rid in routes:
        trip_route[tid] = (rid, sid)
print(f"  {len(trip_route)} trips")

# ---------------------------------------------------------------- stop_times
print("· streaming stop_times (150 MB) …")
def tsec(t):
    t = (t or "").strip()
    if not t:
        return None
    p = t.split(":")
    try:
        return int(p[0])*3600 + int(p[1])*60 + int(p[2])
    except Exception:
        return None

# per trip: ordered [(seq, stop_code, sec|None)]
cur_trip, cur_rows = None, []
pattern_seq = {}          # pattern -> [stop_code, …]   (longest observed)
pattern_times = defaultdict(list)  # pattern -> [(seq_idx, sec)] samples for offsets
departures = defaultdict(set)      # (pattern, service) -> {start_sec}

def flush(tid, rows):
    if not tid or tid not in trip_route or not rows:
        return
    rid, svc = trip_route[tid]
    pat = routes[rid]["pattern"]
    rows.sort(key=lambda x: x[0])
    codes = [gtfs_stop.get(r[1]) for r in rows]
    if any(c is None for c in codes):
        codes = [c for c in codes if c]
    if len(codes) < 2:
        return
    prev = pattern_seq.get(pat)
    if prev is None or len(codes) > len(prev):
        pattern_seq[pat] = codes
    times = [(i, r[2]) for i, r in enumerate(rows) if r[2] is not None]
    if times:
        base = times[0][1]
        departures[(pat, svc)].add(base)
        if len(times) > 1 and len(pattern_times[pat]) < 400:
            pattern_times[pat].append([(i, s - base) for i, s in times])

with open(os.path.join(GTFS, "st", "stop_times.txt"), encoding="utf-8-sig", newline="") as f:
    rdr = csv.reader(f)
    header = next(rdr)
    ix = {k: i for i, k in enumerate(header)}
    it, ist, iseq, iarr = ix["trip_id"], ix["stop_id"], ix["stop_sequence"], ix["arrival_time"]
    n = 0
    for row in rdr:
        n += 1
        if n % 1000000 == 0:
            print(f"    {n//1000000}M …")
        tid = row[it]
        if tid != cur_trip:
            flush(cur_trip, cur_rows)
            cur_trip, cur_rows = tid, []
        try:
            cur_rows.append((int(row[iseq]), row[ist], tsec(row[iarr])))
        except Exception:
            pass
    flush(cur_trip, cur_rows)
print(f"  {n} stop_time rows · {len(pattern_seq)} patterns with sequences")

# ------------------------------------------------- offsets per pattern stop
print("· computing travel-time offsets …")
pattern_offsets = {}
for pat, seq in pattern_seq.items():
    n = len(seq)
    # median observed offset per index
    acc = defaultdict(list)
    for sample in pattern_times.get(pat, []):
        for i, off in sample:
            if 0 <= i < n and off >= 0:
                acc[i].append(off)
    known = {}
    for i, vals in acc.items():
        vals.sort()
        known[i] = vals[len(vals)//2]
    known[0] = 0
    # geometric interpolation for unknown indices
    dist = [0.0]
    for i in range(1, n):
        a, b = stops.get(seq[i-1]), stops.get(seq[i])
        d = hav(a["lat"], a["lon"], b["lat"], b["lon"]) if a and b else 400.0
        dist.append(dist[-1] + max(d, 1.0))
    idxs = sorted(known)
    offs = [None]*n
    for i in idxs:
        offs[i] = known[i]
    # ensure monotonic on knowns
    last = 0
    for i in idxs:
        if offs[i] < last:
            offs[i] = last + 30
        last = offs[i]
    if idxs[-1] < n-1:
        # extrapolate tail using average speed so far
        span = max(dist[idxs[-1]], 1.0)
        spd = max(offs[idxs[-1]] / span, 1/14.0)  # s per metre, >= ~50 km/h cap
        for i in range(idxs[-1]+1, n):
            offs[i] = int(offs[idxs[-1]] + (dist[i]-dist[idxs[-1]])*spd)
    for k in range(len(idxs)-1):
        a, b = idxs[k], idxs[k+1]
        if b - a <= 1:
            continue
        dd = dist[b]-dist[a]
        for i in range(a+1, b):
            frac = (dist[i]-dist[a])/dd if dd > 0 else (i-a)/(b-a)
            offs[i] = int(offs[a] + frac*(offs[b]-offs[a]))
    pattern_offsets[pat] = [int(o or 0) for o in offs]

# ---------------------------------------------------------------- write db
print("· writing SQLite …")
os.makedirs(os.path.dirname(OUT), exist_ok=True)
if os.path.exists(OUT):
    os.remove(OUT)
db = sqlite3.connect(OUT)
db.executescript("""
PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
CREATE TABLE stop(code TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL,
                  district TEXT, direction TEXT, smart INTEGER);
CREATE TABLE line(code TEXT PRIMARY KEY, name TEXT, length_km REAL,
                  trip_min REAL, fare TEXT);
CREATE TABLE pattern(id TEXT PRIMARY KEY, line TEXT, direction TEXT,
                     headsign TEXT, note TEXT, stop_count INTEGER);
CREATE TABLE pattern_stop(pattern TEXT, seq INTEGER, stop TEXT, offset_sec INTEGER,
                          PRIMARY KEY(pattern, seq)) WITHOUT ROWID;
CREATE TABLE departure(pattern TEXT, service TEXT, start_sec INTEGER);
CREATE TABLE service(id TEXT PRIMARY KEY, name TEXT, mon INT, tue INT, wed INT,
                     thu INT, fri INT, sat INT, sun INT, start_date TEXT, end_date TEXT);
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
""")
db.executemany("INSERT INTO stop VALUES(?,?,?,?,?,?,?)",
               [(s["code"], s["name"], s["lat"], s["lon"], s["district"],
                 s["direction"], 1 if s["smart"] else 0) for s in stops.values()])
db.executemany("INSERT INTO line VALUES(?,?,?,?,?)",
               [(l["code"], l["name"], l["length_km"], l["trip_min"], l["fare"])
                for l in lines.values()])
pat_rows, ps_rows = [], []
for pat, seq in pattern_seq.items():
    r = next((v for v in routes.values() if v["pattern"] == pat), None)
    terminus = stops.get(seq[-1], {}).get("name", "")
    head = terminus or (r["headsign"] if r else "")
    pat_rows.append((pat, r["line"] if r else pat.split("_")[0],
                     r["direction"] if r else "", head,
                     r["note"] if r else "", len(seq)))
    offs = pattern_offsets[pat]
    for i, code in enumerate(seq):
        ps_rows.append((pat, i, code, offs[i]))
db.executemany("INSERT INTO pattern VALUES(?,?,?,?,?,?)", pat_rows)
db.executemany("INSERT INTO pattern_stop VALUES(?,?,?,?)", ps_rows)
db.executemany("INSERT INTO departure VALUES(?,?,?)",
               [(p, s, t) for (p, s), ts in departures.items() for t in sorted(ts)])
for r in read_semicolon(os.path.join(GTFS, "calendar.csv")):
    db.execute("INSERT OR REPLACE INTO service VALUES(?,?,?,?,?,?,?,?,?,?,?)",
               (r["service_id"], r["service_name"], int(r["monday"]), int(r["tuesday"]),
                int(r["wednesday"]), int(r["thursday"]), int(r["friday"]),
                int(r["saturday"]), int(r["sunday"]), r["start_date"], r["end_date"]))
db.executescript("""
CREATE INDEX ix_ps_stop ON pattern_stop(stop);
CREATE INDEX ix_pat_line ON pattern(line);
CREATE INDEX ix_dep ON departure(pattern, service, start_sec);
CREATE INDEX ix_stop_geo ON stop(lat, lon);
""")
import datetime
db.executemany("INSERT INTO meta VALUES(?,?)", [
    ("built_at", datetime.datetime.now(datetime.timezone.utc).isoformat()),
    ("source_stops", "IETT UlasimAnaVeri GetDurak_json"),
    ("source_lines", "IETT UlasimAnaVeri GetHat_json"),
    ("source_schedule", "IBB Open Data — iett-gtfs-verisi"),
    ("stop_count", str(len(stops))), ("line_count", str(len(lines))),
    ("pattern_count", str(len(pattern_seq))),
])
db.commit()
print(f"  patterns={len(pat_rows)} pattern_stops={len(ps_rows)} "
      f"departures={sum(len(v) for v in departures.values())}")
print(f"✓ {OUT}  ({os.path.getsize(OUT)/1e6:.1f} MB)")
