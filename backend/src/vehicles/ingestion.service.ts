import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { DbService } from '../db/db.service';
import { IettClient, RawVehicle } from '../iett/iett.client';

export interface LineHealth {
  lineCode: string;
  lastAttempt: Date | null;
  lastSuccess: Date | null;
  latestSourceTime: Date | null;
  validPositions: number;
  stalePositions: number;
  rejected: number;
  error: string | null;
}

/**
 * Polls the İETT fleet service for the configured lines, validates every fix
 * and publishes the result. It never invents a position and never reports
 * healthy live tracking when the source has stopped moving.
 */

/** How long a line stays focused after the phone last asked for it. */
const FOCUS_TTL_MS = 15 * 60_000;
/**
 * İETT's own publishing cadence, measured from recorded position history:
 * the smallest observed gap between two distinct fixes for one vehicle is
 * 11–87 s. Polling faster than this spends quota to receive the same fix.
 */
const SOURCE_CADENCE_MS = 60_000;
/**
 * İETT's ceiling is 100 requests an hour. One line at 60 s already costs 60
 * of them, so at most this many lines can be kept near the source's cadence
 * at once; they share the interval between them.
 */
const MAX_FOCUSED = 2;

@Injectable()
export class IngestionService implements OnModuleInit {
  private readonly log = new Logger(IngestionService.name);
  readonly lines: string[] = (process.env.INGEST_LINES ?? '142,146')
    .split(',').map((s) => s.trim()).filter(Boolean);

  /**
   * A fix older than this is reported as stale rather than live.
   *
   * İETT publishes roughly every 60 s and this backend polls on its own clock,
   * so a healthy vehicle's fix is routinely over two minutes old. 180 s made
   * normal vehicles flap between live and stale; 330 s is five publish cycles,
   * which a working feed never reaches.
   */
  static readonly STALE_SECONDS = 330;

  private health = new Map<string, LineHealth>();
  private cursor = 0;
  /** line → when the phone last said it was watching it. */
  private focused = new Map<string, number>();
  private lastFetch = new Map<string, number>();
  private listeners = new Set<(line: string, vehicles: RawVehicle[]) => void>();

  constructor(private readonly db: DbService, private readonly iett: IettClient) {}

  async onModuleInit() {
    // Re-adopt the lines this backend has watched before.
    //
    // `watch()` only ever added to an in-memory list, so every restart threw
    // away everything the phone had asked for and fell back to the two seed
    // lines. Accuracy measurement then covered almost nothing: 275 stored
    // Metrobüs positions stopped being refreshed the moment the process
    // bounced, and the sampler saw a single bus.
    try {
      const seen = await this.db.query<{ line_code: string }>(
        `SELECT DISTINCT line_code FROM vehicle_positions
          WHERE source_time > now() - interval '7 days'
          LIMIT 40`);
      for (const r of seen) {
        if (r.line_code && !this.lines.includes(r.line_code)) this.lines.push(r.line_code);
      }
    } catch {
      // A cold database is not a reason to refuse to start.
    }

    for (const l of this.lines) {
      this.health.set(l, {
        lineCode: l, lastAttempt: null, lastSuccess: null, latestSourceTime: null,
        validPositions: 0, stalePositions: 0, rejected: 0, error: null,
      });
    }
    this.log.log(`ingesting lines: ${this.lines.join(', ')}`);
  }

  onVehicles(cb: (line: string, vehicles: RawVehicle[]) => void) {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  /**
   * The app tells the backend which line it is watching, so the quota is spent
   * where it matters: the watched line is refreshed at the source's own 60 s
   * cadence and everything else far more slowly. The phone then polls the
   * backend as often as it likes at no cost to the İETT budget.
   */
  watch(lineCode: string) {
    const line = lineCode.trim();
    if (!line) return;
    if (!this.lines.includes(line)) {
      this.lines.push(line);
      this.health.set(line, {
        lineCode: line, lastAttempt: null, lastSuccess: null, latestSourceTime: null,
        validPositions: 0, stalePositions: 0, rejected: 0, error: null,
      });
    }
    // Focus is a small set, not a single slot.
    //
    // It used to be one line. A journey that changes from a bus to the
    // Metrobüs involves two, so watching the second silently demoted the
    // first to the seven-minute schedule — measured in production as a p10
    // gap of 421 s on the user's own lines against 119 s on a focused one.
    // The bus they were actually waiting for was the stale one.
    this.focused.set(line, Date.now());
    for (const [l, at] of this.focused) {
      if (Date.now() - at >= FOCUS_TTL_MS) this.focused.delete(l);
    }
    // Keep the newest few; the quota cannot stretch further than that.
    if (this.focused.size > MAX_FOCUSED) {
      const oldest = [...this.focused.entries()].sort((a, b) => a[1] - b[1]);
      for (const [l] of oldest.slice(0, this.focused.size - MAX_FOCUSED)) {
        this.focused.delete(l);
      }
    }
  }

  /** Lines the phone is actively travelling on; forgotten when it stops asking. */
  private get activeFocusSet(): string[] {
    const now = Date.now();
    return [...this.focused.entries()]
      .filter(([, at]) => now - at < FOCUS_TTL_MS)
      .map(([l]) => l);
  }

  /** Back-compat: the most recently watched line. */
  private get activeFocus(): string | null {
    const now = Date.now();
    let best: string | null = null;
    let bestAt = 0;
    for (const [l, at] of this.focused) {
      if (now - at < FOCUS_TTL_MS && at > bestAt) { best = l; bestAt = at; }
    }
    return best;
  }

  /**
   * İETT's ceiling is 100 requests an hour, which is a hard arithmetic limit
   * on how many lines can be kept fresh: one line at the source's own 60 s
   * cadence already costs 60 of them. So the watched line gets that cadence
   * and the rest are refreshed every 7 minutes — about 86 requests an hour in
   * total. Opening one of the alternatives makes it the watched line, and it
   * becomes fresh within seconds.
   */
  private intervalFor(line: string): number {
    const focused = this.activeFocusSet;
    if (!focused.includes(line)) return 420_000;
    // Share the focused half of the budget between the focused lines, and
    // never go below the source's own cadence — asking faster than İETT
    // publishes spends quota to receive the same fix twice.
    return Math.max(SOURCE_CADENCE_MS, focused.length * SOURCE_CADENCE_MS);
  }

  get focus(): string | null { return this.activeFocus; }
  get focusSet(): string[] { return this.activeFocusSet; }

  get healthReport(): LineHealth[] { return [...this.health.values()]; }
  get budgetRemaining(): number { return this.iett.budget.remaining; }

  /**
   * One line per tick, round-robin.
   *
   * İETT publishes a new fix about every 60 s (measured 2026-11-12: gaps of
   * 53–67 s), and the service documents a 100 requests/hour ceiling. A 45 s
   * tick is 80 requests/hour in total — below the ceiling — and with three
   * ingested lines each line refreshes every ~2¼ minutes.
   */
  @Interval(15_000)
  async tick() {
    // Ingestion stays opt-in: when the phone calls İETT directly from the same
    // network, both share one hourly quota. Turn it on with INGEST_ENABLED=true
    // where the backend is the caller that matters.
    if (process.env.INGEST_ENABLED !== 'true') return;
    if (!this.lines.length) return;

    // Most overdue line first, measured against its own target interval, so a
    // single tick never bursts the quota.
    const now = Date.now();
    const due = this.lines
      .map((l) => ({ l, r: (now - (this.lastFetch.get(l) ?? 0)) / this.intervalFor(l) }))
      .filter((x) => x.r >= 1)
      .sort((a, b) => b.r - a.r);
    if (!due.length) return;
    if (this.iett.budget.remaining <= 0) return;

    this.lastFetch.set(due[0].l, now);
    await this.ingest(due[0].l);
  }

  async ingest(lineCode: string): Promise<LineHealth> {
    const h = this.health.get(lineCode) ?? {
      lineCode, lastAttempt: null, lastSuccess: null, latestSourceTime: null,
      validPositions: 0, stalePositions: 0, rejected: 0, error: null,
    };
    h.lastAttempt = new Date();

    try {
      const { vehicles, rejected, latencyMs } = await this.iett.vehicles(lineCode);
      const now = Date.now();
      let stale = 0;
      for (const v of vehicles) {
        const age = (now - v.sourceTime.getTime()) / 1000;
        if (age > IngestionService.STALE_SECONDS) stale++;
      }

      await this.persist(vehicles, now);

      h.lastSuccess = new Date();
      h.validPositions = vehicles.length;
      h.stalePositions = stale;
      h.rejected = rejected;
      h.latestSourceTime = vehicles.length
        ? new Date(Math.max(...vehicles.map((v) => v.sourceTime.getTime())))
        : null;
      h.error = null;

      await this.logIngest(lineCode, true, vehicles.length, stale, rejected, latencyMs, null);
      for (const cb of this.listeners) cb(lineCode, vehicles);
    } catch (e: any) {
      h.error = e.message;
      await this.logIngest(lineCode, false, 0, 0, 0, null, e.message);
      this.log.warn(`${lineCode}: ${e.message}`);
    }
    this.health.set(lineCode, h);
    return h;
  }

  private async persist(vehicles: RawVehicle[], now: number) {
    if (!vehicles.length) return;
    const received = new Date(now);
    for (const v of vehicles) {
      const stale = (now - v.sourceTime.getTime()) / 1000 > IngestionService.STALE_SECONDS;
      try {
        await this.db.query(
          `INSERT INTO vehicles (door_no, line_code, pattern_id, last_seen)
           VALUES ($1,$2,$3,$4)
           ON CONFLICT (door_no) DO UPDATE
             SET line_code=$2, pattern_id=$3, last_seen=$4`,
          [v.doorNo, v.lineCode, v.patternId || null, received]);

        await this.db.query(
          `INSERT INTO vehicle_positions
             (door_no,line_code,pattern_id,lat,lon,source_time,received_at,near_stop,stale)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
           ON CONFLICT (door_no) DO UPDATE SET
             line_code=$2, pattern_id=$3, lat=$4, lon=$5,
             source_time=$6, received_at=$7, near_stop=$8, stale=$9
           WHERE vehicle_positions.source_time <= $6`,
          [v.doorNo, v.lineCode, v.patternId || null, v.lat, v.lon,
           v.sourceTime, received, v.nearStopCode, stale]);

        // Duplicate fixes collapse on the primary key — a frozen feed costs nothing.
        await this.db.query(
          `INSERT INTO vehicle_position_history
             (door_no,source_time,line_code,pattern_id,lat,lon,received_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7)
           ON CONFLICT (door_no, source_time) DO NOTHING`,
          [v.doorNo, v.sourceTime, v.lineCode, v.patternId || null, v.lat, v.lon, received]);
      } catch (e: any) {
        this.log.warn(`persist ${v.doorNo}: ${e.message}`);
      }
    }
  }

  private async logIngest(line: string, ok: boolean, vehicles: number, stale: number,
                          rejected: number, latency: number | null, error: string | null) {
    try {
      await this.db.query(
        `INSERT INTO ingestion_log (line_code, ok, vehicles, stale, rejected, latency_ms, error)
         VALUES ($1,$2,$3,$4,$5,$6,$7)`,
        [line, ok, vehicles, stale, rejected, latency, error]);
    } catch { /* logging must never break ingestion */ }
  }

  /** Retention: raw history is pruned every hour. */
  @Interval(3_600_000)
  async prune() {
    const hours = Number(process.env.POSITION_HISTORY_HOURS ?? 72);
    try {
      await this.db.query(
        `DELETE FROM vehicle_position_history WHERE source_time < now() - ($1 || ' hours')::interval`,
        [String(hours)]);
      await this.db.query(
        `DELETE FROM ingestion_log WHERE at < now() - interval '7 days'`);
    } catch (e: any) {
      this.log.warn(`prune failed: ${e.message}`);
    }
  }
}
