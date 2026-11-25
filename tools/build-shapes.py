#!/usr/bin/env python3
"""Add real İETT route geometry to the bundled transit database.

İETT does publish route alignments. They are not in the SOAP services — the
WSDLs expose only stops, lines and garages, which is why this project spent
weeks drawing routes by asking Apple Maps for *driving* directions between
consecutive stops and stitching the answers together. That produced a car's
path, not a bus's, and when a leg failed to route the line simply broke in
half, which is exactly what riders saw on the map.

The alignments live on İstanbul's open data portal instead, as GeoJSON:

    data.ibb.gov.tr → "İETT Hat Güzergahları Verisi"

7 401 LineString features keyed by GUZERGAH_KODU, which is byte for byte the
pattern id this app already uses ("401_G_D0"). 2 868 of our 2 876 patterns are
covered.

Usage:
    python3 tools/build-shapes.py <geojson> <sqlite>

Coordinates are stored as packed float32 lat/lon pairs. Simplification is
Ramer-Douglas-Peucker with a tolerance of ~9 m: far below the width of the
road as drawn at any zoom a rider uses, so the line still follows the street.
"""
import json, math, sqlite3, struct, sys

TOLERANCE_DEG = 0.00008          # ~9 m


def rdp(points, eps):
    """Ramer-Douglas-Peucker, iterative so a 4 000-point route cannot blow the stack."""
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        ax, ay = points[lo]
        bx, by = points[hi]
        dx, dy = bx - ax, by - ay
        denom = dx * dx + dy * dy
        worst, idx = 0.0, -1
        for i in range(lo + 1, hi):
            px, py = points[i]
            if denom == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denom))
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > worst:
                worst, idx = d, i
        if worst > eps and idx > 0:
            keep[idx] = True
            stack.append((lo, idx))
            stack.append((idx, hi))
    return [p for p, k in zip(points, keep) if k]


def main(geo_path, db_path):
    db = sqlite3.connect(db_path)
    wanted = {r[0] for r in db.execute("SELECT id FROM pattern")}
    print(f"patterns in the app : {len(wanted)}")

    with open(geo_path, encoding="utf-8") as fh:
        data = json.load(fh)
    print(f"features in GeoJSON : {len(data['features'])}")

    rows, total_in, total_out = [], 0, 0
    for feat in data["features"]:
        pid = (feat["properties"].get("GUZERGAH_KODU") or "").strip()
        if pid not in wanted:
            continue
        geom = feat.get("geometry") or {}
        if geom.get("type") != "LineString":
            continue
        coords = geom["coordinates"]
        if len(coords) < 2:
            continue
        total_in += len(coords)
        simplified = rdp([(float(x), float(y)) for x, y, *_ in coords], TOLERANCE_DEG)
        total_out += len(simplified)
        # Stored lat,lon to match CoreLocation, not GeoJSON's lon,lat order.
        blob = b"".join(struct.pack("<ff", y, x) for x, y in simplified)
        rows.append((pid, len(simplified), blob))

    db.execute("DROP TABLE IF EXISTS pattern_shape")
    db.execute("CREATE TABLE pattern_shape("
               "pattern TEXT PRIMARY KEY, points INTEGER NOT NULL, poly BLOB NOT NULL)")
    db.executemany("INSERT OR REPLACE INTO pattern_shape VALUES (?,?,?)", rows)
    db.execute("INSERT OR REPLACE INTO meta VALUES ('shape_source',?)",
               ("İBB Open Data — İETT Hat Güzergahları Verisi (GeoJSON)",))
    db.commit()

    covered = len(rows)
    print(f"patterns with real geometry : {covered} ({round(100*covered/len(wanted))}%)")
    print(f"points {total_in} -> {total_out} after simplification")
    missing = sorted(wanted - {r[0] for r in rows})
    print(f"patterns WITHOUT geometry   : {len(missing)}")
    for m in missing[:10]:
        print("   ", m)
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
