export interface LatLon { lat: number; lon: number }

const R = 6_371_000;

export function metres(a: LatLon, b: LatLon): number {
  const p1 = (a.lat * Math.PI) / 180;
  const p2 = (b.lat * Math.PI) / 180;
  const dp = p2 - p1;
  const dl = ((b.lon - a.lon) * Math.PI) / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export interface Projection {
  segment: number;
  t: number;
  offset: number;
  along: number;
  point: LatLon;
}

/** Snap a point onto a polyline; returns null for degenerate input. */
export function snap(p: LatLon, line: LatLon[]): Projection | null {
  if (line.length < 2) return null;
  const k = Math.cos((p.lat * Math.PI) / 180);
  const px = ((p.lon - line[0].lon) * Math.PI) / 180 * R * k;
  const py = ((p.lat - line[0].lat) * Math.PI) / 180 * R;
  const proj = (c: LatLon) => ({
    x: ((c.lon - line[0].lon) * Math.PI) / 180 * R * k,
    y: ((c.lat - line[0].lat) * Math.PI) / 180 * R,
  });

  let best: Projection | null = null;
  let cum = 0;
  let cumAtBest = 0;
  for (let i = 0; i < line.length - 1; i++) {
    const a = proj(line[i]);
    const b = proj(line[i + 1]);
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    const segLen = Math.sqrt(len2);
    if (len2 > 0.01) {
      let t = ((px - a.x) * dx + (py - a.y) * dy) / len2;
      t = Math.min(1, Math.max(0, t));
      const cx = a.x + t * dx;
      const cy = a.y + t * dy;
      const off = Math.hypot(px - cx, py - cy);
      if (!best || off < best.offset) {
        best = {
          segment: i, t, offset: off, along: 0,
          point: {
            lat: line[i].lat + (line[i + 1].lat - line[i].lat) * t,
            lon: line[i].lon + (line[i + 1].lon - line[i].lon) * t,
          },
        };
        cumAtBest = cum + segLen * t;
      }
    }
    cum += segLen;
  }
  return best ? { ...best, along: cumAtBest } : null;
}

export function cumulative(line: LatLon[]): number[] {
  const out = [0];
  for (let i = 1; i < line.length; i++) out.push(out[i - 1] + metres(line[i - 1], line[i]));
  return out;
}
