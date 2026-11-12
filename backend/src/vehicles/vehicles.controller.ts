import { Controller, Get, Post, Param, Query, UseGuards, BadRequestException } from '@nestjs/common';
import { DeviceTokenGuard } from '../common/auth.guard';
import { DbService } from '../db/db.service';
import { NetworkService } from '../network/network.service';
import { EtaService, VehicleFix, progressRatio } from '../eta/eta.service';
import { PredictionsService } from '../predictions/predictions.service';
import { IngestionService } from './ingestion.service';

@Controller('v1')
@UseGuards(DeviceTokenGuard)
export class VehiclesController {
  constructor(
    private readonly db: DbService,
    private readonly network: NetworkService,
    private readonly eta: EtaService,
    private readonly predictions: PredictionsService,
    private readonly ingestion: IngestionService,
  ) {}

  /**
   * The app declares which line it is watching. The backend then refreshes
   * that line at the source's cadence, and the phone can poll this server
   * freely without spending any of İETT's hourly quota.
   */
  @Post('watch/:line')
  async watch(@Param('line') line: string) {
    this.ingestion.watch(line);
    // A line watched for the first time has nothing stored yet; fetch it once
    // now rather than letting the phone wait for the next tick.
    let h = this.ingestion.healthReport.find((x) => x.lineCode === line) ?? null;
    const age = h?.lastSuccess ? Date.now() - new Date(h.lastSuccess).getTime() : Infinity;
    if (process.env.INGEST_ENABLED === 'true' && age > 90_000) {
      h = await this.ingestion.ingest(line);
    }
    return {
      watching: line,
      ingestEnabled: process.env.INGEST_ENABLED === 'true',
      lastSuccess: h?.lastSuccess ?? null,
      latestSourceTime: h?.latestSourceTime ?? null,
      budgetRemaining: this.ingestion.budgetRemaining,
    };
  }

  /** Latest validated positions for a line. */
  @Get('lines/:line/vehicles')
  async vehicles(@Param('line') line: string) {
    const rows = await this.db.query(
      `SELECT door_no, line_code, pattern_id, lat, lon, source_time, received_at, near_stop, stale
       FROM vehicle_positions WHERE line_code = $1 ORDER BY source_time DESC`, [line]);
    return {
      lineCode: line,
      count: rows.length,
      watching: this.ingestion.focus,
      vehicles: rows.map((r: any) => ({
        vehicleId: r.door_no,
        patternId: r.pattern_id,
        position: { lat: r.lat, lon: r.lon },
        sourceTime: r.source_time,
        receivedAt: r.received_at,
        ageSeconds: Math.round((Date.now() - new Date(r.source_time).getTime()) / 1000),
        nearStopCode: r.near_stop,
        stale: r.stale,
      })),
    };
  }

  @Get('stops/:stop/arrivals')
  async arrivals(@Param('stop') stopCode: string,
                 @Query('line') line?: string,
                 @Query('record') record?: string) {
    if (!this.network.stop(stopCode)) throw new BadRequestException('unknown stop code');

    const lines = line ? [line] : this.ingestion.lines;
    const out: any[] = [];

    for (const l of lines) {
      const rows = await this.db.query(
        `SELECT door_no, line_code, pattern_id, lat, lon, source_time
         FROM vehicle_positions WHERE line_code = $1`, [l]);
      if (!rows.length) continue;

      const fixes: VehicleFix[] = rows.map((r: any) => ({
        doorNo: r.door_no, lat: r.lat, lon: r.lon,
        lineCode: r.line_code, patternId: r.pattern_id ?? '',
        sourceTime: new Date(r.source_time),
      }));

      const progress = new Map<string, number>();
      // Keyed by door: the same rows answer two different questions — how fast
      // the bus is running, and whether it is running at all.
      const histories = new Map<string, { lat: number; lon: number; sourceTime: Date }[]>();
      for (const f of fixes) {
        const hist = await this.db.query(
          `SELECT lat, lon, source_time FROM vehicle_position_history
           WHERE door_no = $1 AND source_time > now() - interval '20 minutes'
           ORDER BY source_time`, [f.doorNo]);
        if (hist.length < 2) continue;
        histories.set(f.doorNo, hist.map((h: any) => ({
          lat: h.lat, lon: h.lon, sourceTime: new Date(h.source_time),
        })));
        // Stall detection needs no pattern; the progress ratio does.
        if (!f.patternId) continue;
        const shape = this.network.shape(f.patternId);
        const offsets = this.network.stopsOf(f.patternId).map((s) => s.offset_sec);
        if (shape.length < 2) continue;
        const r = progressRatio(
          { lat: hist[0].lat, lon: hist[0].lon, sourceTime: new Date(hist[0].source_time) },
          { lat: hist[hist.length - 1].lat, lon: hist[hist.length - 1].lon,
            sourceTime: new Date(hist[hist.length - 1].source_time) },
          shape, offsets);
        if (r !== null) progress.set(f.doorNo, r);
      }

      const ranked = this.eta.rank(fixes, l, stopCode, progress, Date.now(), histories);
      out.push(...ranked);
    }

    out.sort((a, b) => a.predictedArrivalMinutes - b.predictedArrivalMinutes);
    if (record === 'true') {
      for (const e of out.slice(0, 3)) {
        try { await this.predictions.record(e); } catch { /* measurement must not break reads */ }
      }
    }
    return {
      stopCode,
      stopName: this.network.stop(stopCode)?.name,
      generatedAt: new Date().toISOString(),
      arrivals: out,
      note: out.length ? undefined
        : 'No vehicle with a valid GPS position is currently approaching this stop on the requested lines.',
    };
  }

  @Get('accuracy')
  async accuracy(@Query('line') line?: string) {
    return this.predictions.accuracy(line);
  }

  @Get('stops/near')
  async near(@Query('lat') lat: string, @Query('lon') lon: string,
             @Query('radius') radius = '600') {
    const p = { lat: Number(lat), lon: Number(lon) };
    if (!Number.isFinite(p.lat) || !Number.isFinite(p.lon)) {
      throw new BadRequestException('lat and lon are required');
    }
    return {
      stops: this.network.nearStops(p, Number(radius)).map((s) => ({
        stopCode: s.stop.stop_code, name: s.stop.name, district: s.stop.district,
        lat: s.stop.lat, lon: s.stop.lon, distanceMetres: Math.round(s.distance),
      })),
    };
  }
}
