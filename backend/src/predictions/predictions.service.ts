import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { DbService } from '../db/db.service';
import { NetworkService } from '../network/network.service';
import { EtaResult } from '../eta/eta.service';
import { metres } from '../common/geo';

/**
 * Stores every prediction and later matches it against the moment the vehicle
 * actually reached the stop, so accuracy is measured instead of asserted.
 *
 * "Actual arrival" is defined as the first observed fix within
 * `ARRIVAL_RADIUS` metres of the stop, taken from vehicle_position_history.
 */
@Injectable()
export class PredictionsService {
  private readonly log = new Logger(PredictionsService.name);
  static readonly ARRIVAL_RADIUS = 80;

  constructor(private readonly db: DbService, private readonly network: NetworkService) {}

  async record(e: EtaResult, now = new Date()) {
    const predictedArrival = new Date(now.getTime() + e.predictedArrivalMinutes * 60_000);
    await this.db.query(
      `INSERT INTO eta_predictions
         (door_no,line_code,pattern_id,stop_code,predicted_at,predicted_arrival,
          range_low_min,range_high_min,fix_age_sec,confidence,source)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
      [e.vehicleId, e.routeId, e.patternId, e.stopCode, now, predictedArrival,
       e.arrivalRangeMinutes.minimum, e.arrivalRangeMinutes.maximum,
       e.lastGpsUpdateSeconds, e.confidence, e.source]);
  }

  /** Resolve open predictions against observed history. */
  @Interval(120_000)
  async settle() {
    let open: any[];
    try {
      open = await this.db.query(
        `SELECT id, door_no, stop_code, predicted_at, predicted_arrival
         FROM eta_predictions
         WHERE actual_arrival IS NULL AND predicted_at > now() - interval '6 hours'
         LIMIT 500`);
    } catch { return; }

    for (const p of open) {
      const stop = this.network.stop(p.stop_code);
      if (!stop) continue;
      const fixes = await this.db.query(
        `SELECT lat, lon, source_time FROM vehicle_position_history
         WHERE door_no = $1 AND source_time BETWEEN $2 AND $2 + interval '2 hours'
         ORDER BY source_time`,
        [p.door_no, p.predicted_at]);

      const hit = fixes.find(
        (f: any) => metres({ lat: f.lat, lon: f.lon }, stop) <= PredictionsService.ARRIVAL_RADIUS);
      if (!hit) continue;

      const actual = new Date(hit.source_time);
      const error = (actual.getTime() - new Date(p.predicted_arrival).getTime()) / 1000;
      await this.db.query(
        'UPDATE eta_predictions SET actual_arrival=$1, error_seconds=$2 WHERE id=$3',
        [actual, error, p.id]);
    }
  }

  /** Measured accuracy. Returns nulls rather than guesses when there is no data. */
  async accuracy(lineCode?: string) {
    const where = lineCode ? 'AND line_code = $1' : '';
    const params = lineCode ? [lineCode] : [];
    const rows = await this.db.query<{ error_seconds: number; fix_age_sec: number;
                                       line_code: string; confidence: string;
                                       horizon_sec: number }>(
      `SELECT error_seconds, fix_age_sec, line_code, confidence,
              EXTRACT(EPOCH FROM (predicted_arrival - predicted_at)) AS horizon_sec
       FROM eta_predictions
       WHERE actual_arrival IS NOT NULL ${where}`, params);

    if (!rows.length) {
      return {
        sampleSize: 0,
        note: 'No resolved predictions yet — accuracy cannot be reported.',
        meanAbsoluteErrorSeconds: null,
        medianAbsoluteErrorSeconds: null,
        within2MinutesPercent: null,
        within5MinutesPercent: null,
        gpsFreshnessSeconds: null,
        byLine: {},
        byHorizon: {},
        byConfidence: {},
      };
    }

    const abs = rows.map((r) => Math.abs(Number(r.error_seconds))).sort((a, b) => a - b);
    const ages = rows.map((r) => Number(r.fix_age_sec ?? 0)).sort((a, b) => a - b);
    const pct = (limit: number) =>
      Math.round((abs.filter((e) => e <= limit).length / abs.length) * 1000) / 10;

    const byLine: Record<string, any> = {};
    for (const line of new Set(rows.map((r) => r.line_code))) {
      const sub = rows.filter((r) => r.line_code === line)
        .map((r) => Math.abs(Number(r.error_seconds))).sort((a, b) => a - b);
      byLine[line] = {
        sampleSize: sub.length,
        medianAbsoluteErrorSeconds: Math.round(sub[Math.floor(sub.length / 2)]),
        within2MinutesPercent:
          Math.round((sub.filter((e) => e <= 120).length / sub.length) * 1000) / 10,
      };
    }

    // Error by horizon. A 30-minute estimate being wrong by 3 minutes is a
    // different thing from a 3-minute estimate being wrong by 3 minutes, and
    // one figure averaged over both describes neither.
    const horizonBands: [string, number, number][] = [
      ['under5min', 0, 300],
      ['5to15min', 300, 900],
      ['over15min', 900, Infinity],
    ];
    const byHorizon: Record<string, any> = {};
    for (const [name, lo, hi] of horizonBands) {
      const sub = rows
        .filter((r) => { const h = Number(r.horizon_sec ?? 0); return h >= lo && h < hi; })
        .map((r) => Math.abs(Number(r.error_seconds))).sort((a, b) => a - b);
      byHorizon[name] = sub.length ? {
        sampleSize: sub.length,
        medianAbsoluteErrorSeconds: Math.round(sub[Math.floor(sub.length / 2)]),
        within2MinutesPercent:
          Math.round((sub.filter((e) => e <= 120).length / sub.length) * 1000) / 10,
      } : { sampleSize: 0 };
    }

    // Error by confidence band. This is the one that can falsify the app's
    // own labelling: if "high" is not measurably better than "low", then the
    // badge is decoration and should be removed rather than defended.
    const byConfidence: Record<string, any> = {};
    for (const band of ['high', 'medium', 'low']) {
      const sub = rows.filter((r) => r.confidence === band)
        .map((r) => Math.abs(Number(r.error_seconds))).sort((a, b) => a - b);
      byConfidence[band] = sub.length ? {
        sampleSize: sub.length,
        medianAbsoluteErrorSeconds: Math.round(sub[Math.floor(sub.length / 2)]),
        within2MinutesPercent:
          Math.round((sub.filter((e) => e <= 120).length / sub.length) * 1000) / 10,
      } : { sampleSize: 0 };
    }

    return {
      sampleSize: abs.length,
      meanAbsoluteErrorSeconds: Math.round(abs.reduce((a, b) => a + b, 0) / abs.length),
      medianAbsoluteErrorSeconds: Math.round(abs[Math.floor(abs.length / 2)]),
      within2MinutesPercent: pct(120),
      within5MinutesPercent: pct(300),
      gpsFreshnessSeconds: {
        median: Math.round(ages[Math.floor(ages.length / 2)]),
        p90: Math.round(ages[Math.floor(ages.length * 0.9)]),
      },
      byLine,
      byHorizon,
      byConfidence,
    };
  }
}
