import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { DbService } from '../db/db.service';
import { NetworkService } from '../network/network.service';
import { EtaService, VehicleFix } from '../eta/eta.service';
import { snap } from '../common/geo';
import { IngestionService } from '../vehicles/ingestion.service';
import { PredictionsService } from './predictions.service';

/**
 * Generates the predictions whose accuracy is later measured.
 *
 * Recording used to be opt-in: `GET /v1/stops/:stop/arrivals?record=true`.
 * Nothing ever passed it — the iPhone computes its estimates on the device and
 * never calls that endpoint at all — so `eta_predictions` held one row and
 * `/v1/accuracy` honestly reported `sampleSize: 0`. The project's central
 * claim had no evidence behind it, not because measurement was missing but
 * because nothing triggered it.
 *
 * So measurement no longer waits for a client. For every vehicle being
 * ingested, this records what the engine predicts for stops at a spread of
 * distances ahead of it. As the bus advances, the same arrival is predicted
 * again from closer in, which is what makes error-by-horizon reportable:
 * a 20-minute estimate and a 3-minute estimate for the same event.
 *
 * `PredictionsService.settle()` then matches each prediction against the
 * first observed fix within 80 m of that stop.
 *
 * **This measures the engine, not a mock.** The predictions are made by the
 * same `EtaService` that serves the API, from real ingested positions, and are
 * settled against real observed arrivals.
 */
@Injectable()
export class SamplerService {
  private readonly log = new Logger(SamplerService.name);

  /**
   * Stops ahead of the vehicle to predict for. Chosen to spread the horizon:
   * roughly a few minutes, ten minutes, and far out.
   */
  static readonly STOPS_AHEAD = [2, 5, 12];

  /** One prediction per vehicle/stop per this long, so polling cannot flood. */
  static readonly DEDUPE_MS = 4 * 60_000;

  /**
   * How old a fix may be and still be worth predicting from.
   *
   * This must exceed the slowest ingestion interval, or the sampler starves
   * itself: it was first written at 5 minutes while unfocused lines are
   * refreshed every 7, so their positions were *always* too old to qualify
   * and 275 stored Metrobüs fixes produced nothing. The engine subtracts fix
   * age and lowers confidence accordingly, so predicting from an older fix is
   * measuring exactly what the app would have shown.
   */
  static readonly MAX_FIX_AGE_MINUTES = 10;

  private lastRecorded = new Map<string, number>();

  constructor(
    private readonly db: DbService,
    private readonly network: NetworkService,
    private readonly eta: EtaService,
    private readonly ingestion: IngestionService,
    private readonly predictions: PredictionsService,
  ) {}

  @Interval(60_000)
  async sample() {
    try {
      await this.runOnce();
    } catch (e: any) {
      // Measurement must never take the service down with it.
      this.log.warn(`sampling failed: ${e?.message ?? e}`);
    }
  }

  async runOnce(now = Date.now()): Promise<number> {
    let recorded = 0;
    for (const line of this.ingestion.lines) {
      const rows = await this.db.query(
        `SELECT door_no, line_code, pattern_id, lat, lon, source_time
           FROM vehicle_positions
          WHERE line_code = $1
            AND source_time > now() - ($2 || ' minutes')::interval`,
        [line, String(SamplerService.MAX_FIX_AGE_MINUTES)]);

      for (const r of rows) {
        const patternId: string = r.pattern_id ?? '';
        // A vehicle that does not say which güzergah it runs cannot be
        // matched to a stop sequence with any confidence, and a guessed
        // pattern would poison the measurement rather than enrich it.
        if (!patternId) continue;

        const stops = this.network.stopsOf(patternId);
        if (stops.length < 3) continue;

        const fix: VehicleFix = {
          doorNo: r.door_no, lat: r.lat, lon: r.lon,
          lineCode: r.line_code, patternId,
          sourceTime: new Date(r.source_time),
        };

        const here = this.positionIndex(fix, patternId);
        if (here < 0) continue;

        for (const ahead of SamplerService.STOPS_AHEAD) {
          const target = stops[here + ahead];
          if (!target) continue;

          const key = `${fix.doorNo}|${target.stop_code}`;
          const last = this.lastRecorded.get(key) ?? 0;
          if (now - last < SamplerService.DEDUPE_MS) continue;

          const estimate = this.eta.estimate(
            fix, patternId, target.stop_code, null, now);
          if (!estimate) continue;

          await this.predictions.record(estimate, new Date(now));
          this.lastRecorded.set(key, now);
          recorded++;
        }
      }
    }

    // Keep the dedupe map from growing without bound.
    for (const [k, at] of this.lastRecorded) {
      if (now - at > 2 * 60 * 60_000) this.lastRecorded.delete(k);
    }
    return recorded;
  }

  /** Index of the stop the vehicle has most recently reached. */
  private positionIndex(fix: VehicleFix, patternId: string): number {
    const stops = this.network.stopsOf(patternId);
    const cum = this.network.cumulative(patternId);
    const shape = this.network.shape(patternId);
    if (shape.length < 2 || cum.length !== stops.length) return -1;

    const p = snap({ lat: fix.lat, lon: fix.lon }, shape);
    if (!p || p.offset > 450) return -1;
    return Math.min(p.segment, stops.length - 2);
  }
}
