import { EtaService, progressRatio, stalledSeconds, VehicleFix } from '../src/eta/eta.service';
import { LatLon } from '../src/common/geo';

/**
 * A synthetic but realistic corridor: eight stops roughly 500 m apart heading
 * east, 90 s of scheduled running time between each.
 *
 * Only the *geometry* is synthetic. The engine under test is the same code the
 * API serves, and the fixtures mirror the shape of real İETT data.
 */
const STOPS = Array.from({ length: 8 }, (_, i) => ({
  seq: i,
  stop_code: `S${i}`,
  offset_sec: i * 90,
}));
const SHAPE: LatLon[] = Array.from({ length: 8 }, (_, i) => ({
  lat: 41.0,
  lon: 28.70 + i * 0.006,          // ≈ 500 m per step at this latitude
}));

const network: any = {
  stopsOf: (p: string) => (p === 'L_D_0' ? STOPS : []),
  shape: (p: string) => (p === 'L_D_0' ? SHAPE : []),
  cumulative: (p: string) => {
    const out = [0];
    for (let i = 1; i < SHAPE.length; i++) {
      out.push(out[i - 1] + 0.006 * 111_320 * Math.cos((41 * Math.PI) / 180));
    }
    return out;
  },
  patternsOfLine: (l: string) =>
    l === 'L' ? [{ pattern_id: 'L_D_0', line_code: 'L', direction: 'D', headsign: 'X', stop_count: 8 }] : [],
  indexOf: (p: string, s: string) => STOPS.findIndex((x) => x.stop_code === s),
  stop: (c: string) => ({ stop_code: c, name: c, lat: 41, lon: 28.7, district: '', direction: '' }),
};

const eta = new EtaService(network);
const NOW = Date.UTC(2026, 10, 12, 6, 0, 0);

function fixAt(index: number, ageSeconds = 0, offsetLat = 0): VehicleFix {
  return {
    doorNo: 'B-1887',
    lat: SHAPE[index].lat + offsetLat,
    lon: SHAPE[index].lon,
    lineCode: 'L',
    patternId: 'L_D_0',
    sourceTime: new Date(NOW - ageSeconds * 1000),
  };
}

describe('ETA engine', () => {
  it('predicts scheduled running time for a fresh fix', () => {
    const r = eta.estimate(fixAt(2), 'L_D_0', 'S5', null, NOW)!;
    expect(r).not.toBeNull();
    // 3 stops × 90 s = 270 s = 4.5 min
    expect(r.predictedArrivalMinutes).toBeCloseTo(4.5, 1);
    expect(r.stopsAway).toBe(3);
    expect(r.source).toBe('live_vehicle_position');
    expect(r.lastGpsUpdateSeconds).toBe(0);
  });

  // The "2 minutes for an hour" regression. A bus parked at stop 2 used to
  // be reported at its scheduled time indefinitely, because a vehicle with no
  // progress produced no progress ratio and so got the timetable untouched.
  it('refuses to give a confident time for a bus that is not moving', () => {
    const parked = Array.from({ length: 12 }, (_, i) => ({
      lat: SHAPE[2].lat,
      lon: SHAPE[2].lon,
      sourceTime: new Date(NOW - (11 - i) * 60_000),
    }));
    expect(stalledSeconds(parked, NOW)).toBeGreaterThanOrEqual(600);

    const moving = eta.estimate(fixAt(2), 'L_D_0', 'S5', null, NOW)!;
    const stuck = eta.estimate(fixAt(2), 'L_D_0', 'S5', null, NOW, parked)!;
    expect(stuck.predictedArrivalMinutes).toBeGreaterThan(moving.predictedArrivalMinutes);
    expect(stuck.confidence).toBe('low');
    expect(stuck.lowConfidenceReason).toMatch(/has not moved/);
  });

  it('does not accuse a moving bus of standing still', () => {
    const running = SHAPE.slice(0, 6).map((c, i) => ({
      lat: c.lat, lon: c.lon, sourceTime: new Date(NOW - (5 - i) * 60_000),
    }));
    expect(stalledSeconds(running, NOW)).toBeNull();
  });

  // Silence is a different fault with a different message.
  it('does not call a silent bus stalled', () => {
    const silent = Array.from({ length: 6 }, (_, i) => ({
      lat: SHAPE[2].lat, lon: SHAPE[2].lon,
      sourceTime: new Date(NOW - 3_600_000 + i * 60_000),
    }));
    expect(stalledSeconds(silent, NOW)).toBeNull();
  });

  it('never uses straight-line distance ÷ speed', () => {
    // Two stops apart is 180 s scheduled even though the straight line is 1 km,
    // which at a naive 40 km/h would be 90 s.
    const r = eta.estimate(fixAt(0), 'L_D_0', 'S2', null, NOW)!;
    expect(r.predictedArrivalMinutes).toBeCloseTo(3.0, 1);
  });

  it('subtracts the age of a stale fix and lowers confidence', () => {
    const fresh = eta.estimate(fixAt(2), 'L_D_0', 'S5', null, NOW)!;
    const stale = eta.estimate(fixAt(2, 150), 'L_D_0', 'S5', null, NOW)!;
    expect(stale.predictedArrivalMinutes).toBeLessThan(fresh.predictedArrivalMinutes);
    expect(stale.lastGpsUpdateSeconds).toBe(150);
    expect(stale.confidence).toBe('medium');
    expect(stale.lowConfidenceReason).toMatch(/GPS fix is/);
  });

  it('drops to low confidence once the fix is very old', () => {
    const r = eta.estimate(fixAt(2, 600), 'L_D_0', 'S5', null, NOW)!;
    expect(r.confidence).toBe('low');
    expect(r.lowConfidenceReason).toMatch(/minutes old/);
  });

  it('widens the range as the fix ages', () => {
    const fresh = eta.estimate(fixAt(2), 'L_D_0', 'S5', null, NOW)!;
    const stale = eta.estimate(fixAt(2, 150), 'L_D_0', 'S5', null, NOW)!;
    const span = (r: any) => r.arrivalRangeMinutes.maximum - r.arrivalRangeMinutes.minimum;
    expect(span(stale)).toBeGreaterThan(span(fresh));
  });

  it('returns null when the bus has already passed the stop', () => {
    expect(eta.estimate(fixAt(5), 'L_D_0', 'S2', null, NOW)).toBeNull();
  });

  it('rejects a vehicle far off the published route', () => {
    expect(eta.estimate(fixAt(2, 0, 0.02), 'L_D_0', 'S5', null, NOW)).toBeNull();
  });

  it('slows the estimate when observed progress is behind schedule', () => {
    const onTime = eta.estimate(fixAt(2), 'L_D_0', 'S5', 1.0, NOW)!;
    const slow = eta.estimate(fixAt(2), 'L_D_0', 'S5', 1.6, NOW)!;
    expect(slow.predictedArrivalMinutes).toBeGreaterThan(onTime.predictedArrivalMinutes);
  });

  it('clamps an implausible progress factor', () => {
    const wild = eta.estimate(fixAt(2), 'L_D_0', 'S5', 99, NOW)!;
    const capped = eta.estimate(fixAt(2), 'L_D_0', 'S5', 1.9, NOW)!;
    expect(wild.predictedArrivalMinutes).toBeCloseTo(capped.predictedArrivalMinutes, 5);
  });

  it('ranks several vehicles nearest-first', () => {
    const ranked = eta.rank([fixAt(1), fixAt(3), fixAt(0)], 'L', 'S5', new Map(), NOW);
    expect(ranked.map((r) => r.stopsAway)).toEqual([2, 4, 5]);
  });

  it('reports no arrivals for a line that does not serve the stop', () => {
    expect(eta.rank([fixAt(1)], 'OTHER', 'S5', new Map(), NOW)).toEqual([]);
  });

  it('measures progress against the timetable', () => {
    // Moved one stop (90 s scheduled) but took 180 s — running at half pace.
    const r = progressRatio(
      { ...SHAPE[1], sourceTime: new Date(NOW - 180_000) },
      { ...SHAPE[2], sourceTime: new Date(NOW) },
      SHAPE,
      STOPS.map((s) => s.offset_sec),
    );
    expect(r).toBeCloseTo(2.0, 1);
  });

  it('refuses to measure progress over too short a window', () => {
    const r = progressRatio(
      { ...SHAPE[1], sourceTime: new Date(NOW - 30_000) },
      { ...SHAPE[2], sourceTime: new Date(NOW) },
      SHAPE,
      STOPS.map((s) => s.offset_sec),
    );
    expect(r).toBeNull();
  });
});
