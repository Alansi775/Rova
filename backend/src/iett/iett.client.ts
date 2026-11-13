import { Injectable, Logger } from '@nestjs/common';

export interface RawVehicle {
  doorNo: string;
  lat: number;
  lon: number;
  lineCode: string;
  patternId: string;
  lineName: string;
  direction: string;
  sourceTime: Date;
  nearStopCode: string | null;
}

export interface FetchResult {
  vehicles: RawVehicle[];
  rejected: number;
  latencyMs: number;
}

/** Sliding-window limiter for İETT's published 100 requests/hour ceiling. */
export class RequestBudget {
  private stamps: number[] = [];
  constructor(private readonly limit: number) {}
  private prune() {
    const cutoff = Date.now() - 3_600_000;
    this.stamps = this.stamps.filter((s) => s > cutoff);
  }
  consume(): boolean {
    this.prune();
    if (this.stamps.length >= this.limit) return false;
    this.stamps.push(Date.now());
    return true;
  }
  get remaining(): number { this.prune(); return Math.max(0, this.limit - this.stamps.length); }
}

@Injectable()
export class IettClient {
  private readonly log = new Logger(IettClient.name);
  private readonly fleetUrl =
    process.env.IETT_FLEET_URL ?? 'https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx';
  private readonly networkUrl =
    process.env.IETT_NETWORK_URL ?? 'https://api.ibb.gov.tr/iett/UlasimAnaVeri/HatDurakGuzergah.asmx';
  /**
   * İETT publishes a ceiling of about 100 requests an hour per caller. Running
   * at 90 left no room for the retries above, and none for a manual probe or a
   * restart that re-reads a few lines. 75 is a ceiling with headroom, which is
   * the only kind worth having: the cost of being slightly slower is a fix one
   * minute older, and the cost of being over is every line going dark at once.
   */
  readonly budget = new RequestBudget(Number(process.env.IETT_HOURLY_LIMIT ?? 75));

  /**
   * Backoff is deliberately split in two, because the two failure modes have
   * different blast radii and conflating them silenced the whole app.
   *
   * `quotaBackoffUntil` is global and correct: "Policy Falsified" is Layer7
   * refusing this *IP address*, so no line can be fetched and trying another
   * one only digs deeper.
   *
   * `lineBackoff` is per line, and replaces a global one that was wrong. The
   * fleet service returns a sporadic HTTP 503 for a single line while serving
   * the rest perfectly. The old code let that one failure stop every line for
   * up to fifteen minutes, so the whole map froze on one line's hiccup. The
   * ingestion log shows the amplification plainly: in the 10:00 hour on
   * 2026-11-13, 17 real 503s produced 107 further attempts refused by our own
   * backoff — six fabricated failures for every genuine one, and ~40 minutes
   * where not a single request left the machine while most lines would have
   * answered. That was ours, not İETT's.
   */
  private quotaBackoffUntil = 0;
  private lineBackoff = new Map<string, { until: number; failures: number }>();

  /** Longest a single line is rested after transport failures. */
  static readonly MAX_LINE_BACKOFF_MS = 5 * 60_000;

  get isBackingOff(): boolean { return Date.now() < this.quotaBackoffUntil; }
  backoffFor(lineCode: string): number {
    const b = this.lineBackoff.get(lineCode);
    return b ? Math.max(0, b.until - Date.now()) : 0;
  }
  get consecutiveFailures(): number {
    let n = 0;
    for (const b of this.lineBackoff.values()) n = Math.max(n, b.failures);
    return n;
  }

  /** Live vehicle positions for one line code. */
  async vehicles(lineCode: string): Promise<FetchResult> {
    if (this.isBackingOff) {
      throw new Error('İETT quota exhausted for this address — backing off');
    }
    if (this.backoffFor(lineCode) > 0) {
      throw new Error(
        `backing off ${lineCode} for ${Math.round(this.backoffFor(lineCode) / 1000)}s ` +
        'after repeated failures on this line');
    }
    if (!this.budget.consume()) throw new Error('hourly İETT request budget exhausted');

    const body = soapEnvelope('GetHatOtoKonum_json', `<tns:HatKodu>${escapeXml(lineCode)}</tns:HatKodu>`);
    const started = Date.now();

    // The İETT gateway returns a sporadic 503 for an otherwise valid request,
    // so one transient failure is retried before the line is marked unhealthy.
    //
    // The retry *is* charged to the budget. It used to be free, on the
    // reasoning that a failed request is not a served request — but İETT
    // counts HTTP calls at its gateway, not our successes, and the invisible
    // second call is exactly what broke us on 2026-11-13: running pinned at
    // our 90/hour ceiling against İETT's ~100/hour limit, a burst of 17 503s
    // in one hour fired 17 uncounted retries, pushed the real rate past 100,
    // and Layer7 answered "Policy Falsified" — turning a patch of transient
    // faults into a flat lockout of every line. A budget that does not count
    // every call it makes is not a budget.
    let text: string | null = null;
    let lastError = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const res = await fetch(this.fleetUrl, {
          method: 'POST',
          headers: {
            'Content-Type': 'text/xml; charset=utf-8',
            SOAPAction: '"http://tempuri.org/GetHatOtoKonum_json"',
            'User-Agent': 'ROVA/1.0 (personal transit client)',
          },
          body,
          signal: AbortSignal.timeout(20_000),
        });
        const payloadText = await res.text();
        if (!res.ok) {
          lastError = extract(payloadText, 'faultstring') ?? `HTTP ${res.status}`;
          // "Policy Falsified" is Layer7's generic assertion failure, not a
          // quota message as this code once assumed. On 2026-11-13 we logged
          // it while making 40 calls an hour against a ~100 ceiling — and a
          // minute later the gateway was returning a bare HTML 503 for the
          // Metro endpoint too, so the whole of api.ibb.gov.tr was down. A
          // quota diagnosis there would have been a confident lie in our own
          // health output. Only an explicit quota assertion is treated as one.
          if (/policy falsified/i.test(lastError) && /quota|rate|throttl/i.test(payloadText)) {
            this.quotaBackoffUntil = Date.now() + 10 * 60_000;
            throw new Error('İETT rate limit reached (Policy Falsified) — backing off 10 min');
          }
          if (res.status >= 500 && attempt === 0 && this.budget.consume()) {
            await new Promise((r) => setTimeout(r, 1500));
            continue;
          }
          throw new Error(lastError);
        }
        text = payloadText;
        break;
      } catch (e: any) {
        lastError = e.message;
        if (attempt === 0 && this.budget.consume()) {
          await new Promise((r) => setTimeout(r, 1500));
          continue;
        }
        this.noteFailure(lineCode);
        throw new Error(`İETT fleet service: ${lastError}`);
      }
    }
    if (text === null) {
      this.noteFailure(lineCode);
      throw new Error(`İETT fleet service: ${lastError}`);
    }

    const payload = extract(text, 'GetHatOtoKonum_jsonResult');
    if (payload === null) {
      this.noteFailure(lineCode);
      throw new Error('İETT returned no result element');
    }

    const { vehicles, rejected } = parseVehicles(payload, lineCode);
    // A line that answers is healthy again; its own history is cleared, and
    // no other line's state is touched.
    this.lineBackoff.delete(lineCode);
    this.quotaBackoffUntil = 0;
    return { vehicles, rejected, latencyMs: Date.now() - started };
  }

  /** Full stop list — reference data, fetched rarely. */
  async stops(): Promise<any[]> {
    const body = soapEnvelope('GetDurak_json', '<tns:DurakKodu></tns:DurakKodu>');
    const res = await fetch(this.networkUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'text/xml; charset=utf-8',
                 SOAPAction: '"http://tempuri.org/GetDurak_json"' },
      body, signal: AbortSignal.timeout(120_000),
    });
    const payload = extract(await res.text(), 'GetDurak_jsonResult');
    return payload ? JSON.parse(payload) : [];
  }

  async lines(): Promise<any[]> {
    const body = soapEnvelope('GetHat_json', '<tns:HatKodu></tns:HatKodu>');
    const res = await fetch(this.networkUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'text/xml; charset=utf-8',
                 SOAPAction: '"http://tempuri.org/GetHat_json"' },
      body, signal: AbortSignal.timeout(120_000),
    });
    const payload = extract(await res.text(), 'GetHat_jsonResult');
    return payload ? JSON.parse(payload) : [];
  }

  private noteFailure(lineCode: string) {
    const prev = this.lineBackoff.get(lineCode);
    const failures = (prev?.failures ?? 0) + 1;
    const wait = Math.min(
      IettClient.MAX_LINE_BACKOFF_MS,
      20_000 * 2 ** Math.min(4, failures - 1));
    this.lineBackoff.set(lineCode, { until: Date.now() + wait, failures });
    this.log.warn(
      `İETT failure #${failures} on ${lineCode}; resting that line ${Math.round(wait / 1000)}s`);
  }
}

// ---------------------------------------------------------------- helpers

export function soapEnvelope(method: string, inner: string): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tns="http://tempuri.org/">
  <soap:Body><tns:${method}>${inner}</tns:${method}></soap:Body>
</soap:Envelope>`;
}

export function escapeXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function extract(xml: string, tag: string): string | null {
  const open = `<${tag}>`;
  const close = `</${tag}>`;
  const a = xml.indexOf(open);
  const b = xml.indexOf(close);
  if (a < 0 || b < a) return null;
  return unescapeXml(xml.slice(a + open.length, b));
}

export function unescapeXml(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
          .replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

/** Istanbul is UTC+3 all year, so the offset is a constant. */
export function parseIstanbulTime(s: string | null | undefined): Date | null {
  if (!s) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/.exec(s.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, se] = m;
  return new Date(Date.UTC(+y, +mo - 1, +d, +h - 3, +mi, +se));
}

export function parseVehicles(json: string, requestedLine: string):
    { vehicles: RawVehicle[]; rejected: number } {
  let raw: any[];
  try { raw = JSON.parse(json); } catch { return { vehicles: [], rejected: 0 }; }
  if (!Array.isArray(raw)) return { vehicles: [], rejected: 0 };

  const vehicles: RawVehicle[] = [];
  let rejected = 0;
  const seen = new Set<string>();

  for (const r of raw) {
    const door = pickString(r, ['kapino', 'KAPINO', 'KapiNo']);
    const lat = pickNumber(r, ['enlem', 'ENLEM', 'Enlem']);
    const lon = pickNumber(r, ['boylam', 'BOYLAM', 'Boylam']);
    const sourceTime = parseIstanbulTime(pickString(r, ['son_konum_zamani', 'SON_KONUM_ZAMANI']));

    if (!door || lat === null || lon === null) { rejected++; continue; }
    // Greater Istanbul bounding box — the feed emits 0,0 for vehicles with no fix.
    if (lat < 40.5 || lat > 41.9 || lon < 27.0 || lon > 30.5) { rejected++; continue; }
    if (!sourceTime || Number.isNaN(sourceTime.getTime())) { rejected++; continue; }
    // A timestamp far in the future means the provider clock is wrong; do not trust it.
    if (sourceTime.getTime() > Date.now() + 120_000) { rejected++; continue; }

    const key = `${door}|${sourceTime.getTime()}`;
    if (seen.has(key)) { rejected++; continue; }
    seen.add(key);

    vehicles.push({
      doorNo: door,
      lat, lon,
      lineCode: pickString(r, ['hatkodu', 'HATKODU']) ?? requestedLine,
      patternId: pickString(r, ['guzergahkodu', 'GUZERGAHKODU']) ?? '',
      lineName: pickString(r, ['hatad', 'HATAD']) ?? '',
      direction: pickString(r, ['yon', 'YON']) ?? '',
      sourceTime,
      nearStopCode: pickString(r, ['yakinDurakKodu', 'YAKINDURAKKODU']),
    });
  }
  return { vehicles, rejected };
}

function pickString(r: any, keys: string[]): string | null {
  for (const k of keys) {
    const v = r?.[k];
    if (typeof v === 'string' && v.trim()) return v.trim();
    if (typeof v === 'number') return String(v);
  }
  return null;
}

function pickNumber(r: any, keys: string[]): number | null {
  for (const k of keys) {
    const v = r?.[k];
    if (typeof v === 'number' && Number.isFinite(v)) return v;
    if (typeof v === 'string') {
      const n = Number(v.trim().replace(',', '.'));
      if (Number.isFinite(n)) return n;
    }
  }
  return null;
}
