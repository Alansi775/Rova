import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { LatLon, cumulative, metres } from '../common/geo';

export interface StopRow {
  stop_code: string;
  name: string;
  lat: number;
  lon: number;
  district: string;
  direction: string;
}
export interface PatternRow {
  pattern_id: string;
  line_code: string;
  direction: string;
  headsign: string;
  stop_count: number;
}
export interface PatternStopRow { seq: number; stop_code: string; offset_sec: number }

/** In-memory view of the static network. It is small (~15k stops) and read-only. */
@Injectable()
export class NetworkService implements OnModuleInit {
  private readonly log = new Logger(NetworkService.name);
  private stops = new Map<string, StopRow>();
  private patterns = new Map<string, PatternRow>();
  private patternStops = new Map<string, PatternStopRow[]>();
  private shapes = new Map<string, LatLon[]>();
  private loaded = false;

  constructor(private readonly db: DbService) {}

  async onModuleInit() {
    try {
      await this.load();
    } catch (e: any) {
      this.log.error(`network load failed: ${e.message}`);
    }
  }

  get isLoaded() { return this.loaded; }
  get stopCount() { return this.stops.size; }
  get patternCount() { return this.patterns.size; }

  async load() {
    const stops = await this.db.query<StopRow>(
      'SELECT stop_code,name,lat,lon,district,direction FROM transport_stops',
    );
    this.stops = new Map(stops.map((s) => [s.stop_code, s]));

    const pats = await this.db.query<PatternRow>(
      'SELECT pattern_id,line_code,direction,headsign,stop_count FROM transit_patterns',
    );
    this.patterns = new Map(pats.map((p) => [p.pattern_id, p]));

    const rs = await this.db.query<PatternStopRow & { pattern_id: string }>(
      'SELECT pattern_id,seq,stop_code,offset_sec FROM route_stops ORDER BY pattern_id, seq',
    );
    this.patternStops = new Map();
    for (const r of rs) {
      const list = this.patternStops.get(r.pattern_id) ?? [];
      list.push({ seq: r.seq, stop_code: r.stop_code, offset_sec: r.offset_sec });
      this.patternStops.set(r.pattern_id, list);
    }
    this.shapes.clear();
    this.loaded = this.stops.size > 0 && this.patterns.size > 0;
    this.log.log(`network: ${this.stops.size} stops, ${this.patterns.size} patterns`);
  }

  stop(code: string) { return this.stops.get(code) ?? null; }
  pattern(id: string) { return this.patterns.get(id) ?? null; }
  stopsOf(patternId: string) { return this.patternStops.get(patternId) ?? []; }

  shape(patternId: string): LatLon[] {
    const cached = this.shapes.get(patternId);
    if (cached) return cached;
    const pts = this.stopsOf(patternId)
      .map((s) => this.stops.get(s.stop_code))
      .filter(Boolean)
      .map((s) => ({ lat: s!.lat, lon: s!.lon }));
    this.shapes.set(patternId, pts);
    return pts;
  }

  cumulative(patternId: string) { return cumulative(this.shape(patternId)); }

  patternsOfLine(lineCode: string): PatternRow[] {
    return [...this.patterns.values()].filter((p) => p.line_code === lineCode);
  }

  /** Index of a stop within a pattern, or -1. */
  indexOf(patternId: string, stopCode: string): number {
    return this.stopsOf(patternId).findIndex((s) => s.stop_code === stopCode);
  }

  nearStops(p: LatLon, radius: number, limit = 20) {
    const out: Array<{ stop: StopRow; distance: number }> = [];
    for (const s of this.stops.values()) {
      if (Math.abs(s.lat - p.lat) > 0.02 || Math.abs(s.lon - p.lon) > 0.03) continue;
      const d = metres(p, s);
      if (d <= radius) out.push({ stop: s, distance: d });
    }
    return out.sort((a, b) => a.distance - b.distance).slice(0, limit);
  }
}
