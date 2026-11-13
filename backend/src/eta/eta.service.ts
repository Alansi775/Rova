import { Injectable } from '@nestjs/common';
import { NetworkService } from '../network/network.service';
import { LatLon, snap, metres } from '../common/geo';

export type Confidence = 'high' | 'medium' | 'low';
export type DataSource = 'live_vehicle_position' | 'schedule';

export interface VehicleFix {
  doorNo: string;
  lat: number;
  lon: number;
  lineCode: string;
  patternId: string;
  sourceTime: Date;
}

export interface EtaResult {
  vehicleId: string;
  routeId: string;
  patternId: string;
  stopCode: string;
  predictedArrivalMinutes: number;
  arrivalRangeMinutes: { minimum: number; maximum: number };
  lastGpsUpdateSeconds: number;
  confidence: Confidence;
  lowConfidenceReason: string | null;
  source: DataSource;
  remainingMetres: number;
  stopsAway: number;
  offRouteMetres: number;
}

export const MAX_SNAP_OFFSET = 450;
export const STALE_SECONDS = 180;

/**
 * Server-side twin of the on-device ETA engine. The base estimate is scheduled
 * time-along-route (which already encodes stop spacing, dwell and typical
 * traffic), scaled by observed progress where it is known, then reduced by the
 * age of the GPS fix.
 */
@Injectable()
export class EtaService {
  constructor(private readonly network: NetworkService) {}

  estimate(
    fix: VehicleFix,
    patternId: string,
    stopCode: string,
    progressFactor: number | null = null,
    now: number = Date.now(),
    /// Recent fixes for this vehicle, oldest first, used to tell a bus that is
    /// stuck from one that is merely slow. Optional: callers without history
    /// get the old behaviour rather than a wrong claim.
    fixHistory: { lat: number; lon: number; sourceTime: Date }[] | null = null,
  ): EtaResult | null {
    const ps = this.network.stopsOf(patternId);
    if (ps.length < 2) return null;
    const stopIndex = ps.findIndex((s) => s.stop_code === stopCode);
    if (stopIndex <= 0) return null;

    const shape = this.network.shape(patternId);
    if (shape.length !== ps.length) return null;

    const p = snap({ lat: fix.lat, lon: fix.lon }, shape);
    if (!p || p.offset > MAX_SNAP_OFFSET) return null;

    const i = Math.min(p.segment, ps.length - 2);
    const vehicleOffset = ps[i].offset_sec + (ps[i + 1].offset_sec - ps[i].offset_sec) * p.t;
    const targetOffset = ps[stopIndex].offset_sec;
    // When the fix lands exactly on a vertex the projection reports the
    // previous segment with t = 1; treat that as standing at the later stop.
    const vehicleIndex = i + (p.t >= 0.999 ? 1 : 0);
    const stopsAway = stopIndex - vehicleIndex;
    if (stopsAway < 0) return null;

    let scheduledRemaining = targetOffset - vehicleOffset;
    if (scheduledRemaining < -90) return null;        // already passed the stop
    scheduledRemaining = Math.max(0, scheduledRemaining);

    const cum = this.network.cumulative(patternId);
    const remainingMetres = Math.max(0, cum[stopIndex] - p.along);

    const factor = progressFactor === null
      ? 1
      : Math.min(1.9, Math.max(0.55, progressFactor));

    const age = Math.max(0, (now - fix.sourceTime.getTime()) / 1000);
    let scheduled = scheduledRemaining * factor;

    // Sanity against the ground, not just against the timetable. A few İETT
    // patterns carry almost no timepoints, so the interpolated offsets
    // collapse and the schedule claims kilometres covered in seconds. Tested
    // before staleness is subtracted, because that subtraction is itself a
    // legitimate reason for a short remaining time.
    const IMPLAUSIBLE_SPEED = 17;   // m/s — 61 km/h door to door
    // Same number, different job: the fastest a bus could conceivably
    // average, used to bound how soon it could physically be here.
    const MAX_CONCEIVABLE_SPEED = 17;
    const MAX_USABLE_FIX_AGE = 900; // s — 15 minutes
    const TYPICAL_BUS_SPEED = 7;    // m/s — 25 km/h including dwell
    let scheduleSuspect = false;
    if (remainingMetres > 400 && scheduled > 0
        && remainingMetres / scheduled > IMPLAUSIBLE_SPEED) {
      scheduled = remainingMetres / TYPICAL_BUS_SPEED;
      scheduleSuspect = true;
    }

    // A bus that is not moving does not get the timetable's optimism: the
    // time it has already stood still is added, because it has to start
    // moving again before it can arrive.
    const stalled = fixHistory ? stalledSeconds(fixHistory, now) : null;
    if (stalled !== null) scheduled += stalled;

    // Beyond this a position is not evidence about where a bus is now. İETT
    // keeps publishing the last known position of vehicles that finished for
    // the day: on line 34BZ at 02:07, 112 were listed and none had reported
    // within three minutes — median fix 2.5 hours, oldest 11 hours.
    if (age > MAX_USABLE_FIX_AGE) return null;

    let seconds = Math.max(0, scheduled - age);
    if (stopsAway > 0) seconds = Math.max(seconds, 25 * stopsAway);

    // A bus cannot arrive sooner than the road allows, and that bounds the
    // estimate itself, not only the early end of its range. Bounding only the
    // range produced a headline of "8 min" above a range of "21–293 min".
    seconds = Math.max(seconds, remainingMetres / MAX_CONCEIVABLE_SPEED);

    let spread = 0.14 * seconds + 45;
    if (progressFactor === null) spread *= 1.25;
    if (scheduleSuspect) spread *= 1.6;
    spread += age * 0.6;
    spread += Math.max(0, stopsAway - 6) * 12;
    spread += p.offset * 0.25;

    let { confidence, reason } = classify(age, p.offset, stopsAway, progressFactor !== null, seconds);
    if (scheduleSuspect) {
      if (confidence === 'high' || confidence === 'medium') confidence = 'low';
      reason = 'İETT publishes almost no timing for this route — estimated from distance alone';
    }
    if (stalled !== null) {
      // Outranks every other reason: a number means little beside the fact
      // that the bus is standing still.
      confidence = 'low';
      reason = `This bus has not moved for ${Math.round(stalled / 60)} minutes`;
      spread = Math.max(spread, stalled);
    }

    return {
      vehicleId: fix.doorNo,
      routeId: fix.lineCode,
      patternId,
      stopCode,
      predictedArrivalMinutes: round(seconds / 60),
      arrivalRangeMinutes: {
        // Bounded by the road, not only by the spread: a wide spread used to
        // drag this to zero, and a zero early bound reads as "leave now" for
        // a bus that is kilometres away.
        minimum: round(Math.max(0,
          Math.max(remainingMetres / MAX_CONCEIVABLE_SPEED, seconds - spread) / 60)),
        maximum: round((seconds + spread) / 60),
      },
      lastGpsUpdateSeconds: Math.round(age),
      confidence,
      lowConfidenceReason: reason,
      source: 'live_vehicle_position',
      remainingMetres: Math.round(remainingMetres),
      stopsAway,
      offRouteMetres: Math.round(p.offset),
    };
  }

  /** Best estimate across every vehicle of a line for one stop. */
  rank(
    fixes: VehicleFix[],
    lineCode: string,
    stopCode: string,
    progress: Map<string, number> = new Map(),
    now: number = Date.now(),
    histories: Map<string, { lat: number; lon: number; sourceTime: Date }[]> = new Map(),
  ): EtaResult[] {
    const patterns = this.network
      .patternsOfLine(lineCode)
      .filter((p) => this.network.indexOf(p.pattern_id, stopCode) > 0);
    if (!patterns.length) return [];

    const out: EtaResult[] = [];
    for (const f of fixes) {
      // A vehicle that reports its own güzergah is taken at its word. If that
      // güzergah does not call at this stop, it is not coming here — usually
      // it is the same line running the other way. Falling back to "try every
      // pattern" is what used to invent an approaching bus.
      if (f.patternId && !patterns.some((p) => p.pattern_id === f.patternId)) continue;
      const tryPatterns = f.patternId
        ? [f.patternId]
        : patterns.map((p) => p.pattern_id);
      let best: EtaResult | null = null;
      for (const pid of tryPatterns) {
        const r = this.estimate(f, pid, stopCode, progress.get(f.doorNo) ?? null, now,
                                histories.get(f.doorNo) ?? null);
        if (r && (!best || r.predictedArrivalMinutes < best.predictedArrivalMinutes)) best = r;
      }
      if (best) out.push(best);
    }
    return out.sort((a, b) => a.predictedArrivalMinutes - b.predictedArrivalMinutes);
  }
}

function classify(age: number, offset: number, stopsAway: number,
                  hasProgress: boolean, horizon: number):
  { confidence: Confidence; reason: string | null } {
  if (age > 300) return { confidence: 'low', reason: `Last GPS fix is ${Math.round(age / 60)} minutes old` };
  if (offset > 250) return { confidence: 'low', reason: `Vehicle is ${Math.round(offset)} m off the published route` };
  if (horizon > 45 * 60) return { confidence: 'low', reason: 'The bus is still far from the stop' };
  if (age > 120) return { confidence: 'medium', reason: `GPS fix is ${Math.round(age)} s old` };
  if (stopsAway > 12) return { confidence: 'medium', reason: `${stopsAway} stops away` };
  if (!hasProgress) return { confidence: 'medium', reason: 'Not enough movement observed yet' };
  if (horizon > 20 * 60) return { confidence: 'medium', reason: 'Long horizon' };
  return { confidence: 'high', reason: null };
}

function round(n: number) { return Math.round(n * 10) / 10; }

/**
 * How long a vehicle has been reporting from the same spot, in seconds, or
 * null if it is moving or has gone silent.
 *
 * A stationary bus used to be the best case in this engine: `progressRatio`
 * divides by scheduled progress, a parked bus has made none, so the ratio came
 * back null, the factor fell back to 1, and the answer dropped onto the raw
 * timetable — "2 minutes", unchanged, for as long as the bus sat there.
 *
 * Silence is a different fault (`age` already covers it) and is not reported
 * here. Three minutes is past a red light and past a stop dwell.
 */
export function stalledSeconds(
  fixes: { lat: number; lon: number; sourceTime: Date }[],
  now: number,
): number | null {
  if (fixes.length < 2) return null;
  const last = fixes[fixes.length - 1];
  if ((now - last.sourceTime.getTime()) / 1000 >= 240) return null;
  let span = 0;
  for (let i = fixes.length - 2; i >= 0; i--) {
    if (metres(fixes[i], last) > 60) break;
    span = (last.sourceTime.getTime() - fixes[i].sourceTime.getTime()) / 1000;
  }
  return span >= 180 ? span : null;
}

/** Real progress ÷ scheduled progress from two observed fixes on one pattern. */
export function progressRatio(
  first: { lat: number; lon: number; sourceTime: Date },
  last: { lat: number; lon: number; sourceTime: Date },
  shape: LatLon[],
  offsets: number[],
): number | null {
  const dt = (last.sourceTime.getTime() - first.sourceTime.getTime()) / 1000;
  if (dt < 90) return null;
  const a = snap(first, shape);
  const b = snap(last, shape);
  if (!a || !b || a.offset > MAX_SNAP_OFFSET || b.offset > MAX_SNAP_OFFSET) return null;
  const sched = (p: { segment: number; t: number }) => {
    const i = Math.min(p.segment, offsets.length - 2);
    return offsets[i] + (offsets[i + 1] - offsets[i]) * p.t;
  };
  const delta = sched(b) - sched(a);
  if (delta <= 30) return null;
  return dt / delta;
}
