import { parseVehicles, parseIstanbulTime, extract, soapEnvelope } from '../src/iett/iett.client';

/** A verbatim response captured from the live İETT service on 2026-11-12. */
const REAL_RESPONSE = `[{"kapino":"B-1887","boylam":"28.66874","enlem":"41.06737","hatkodu":"146","guzergahkodu":"146_G_D6038","hatad":"BOĞAZKÖY / BAHÇEŞEHİR - BAKIRKÖY","yon":"BOĞAZKÖY SON DURAK","son_konum_zamani":"2026-11-12 04:30:54","yakinDurakKodu":"128071"}]`;

describe('İETT response parsing', () => {
  it('parses a real captured response', () => {
    const { vehicles, rejected } = parseVehicles(REAL_RESPONSE, '146');
    expect(rejected).toBe(0);
    expect(vehicles).toHaveLength(1);
    const v = vehicles[0];
    expect(v.doorNo).toBe('B-1887');
    expect(v.lat).toBeCloseTo(41.06737, 5);
    expect(v.lon).toBeCloseTo(28.66874, 5);
    expect(v.lineCode).toBe('146');
    expect(v.patternId).toBe('146_G_D6038');
    expect(v.nearStopCode).toBe('128071');
    // 04:30:54 Istanbul == 01:30:54 UTC
    expect(v.sourceTime.toISOString()).toBe('2026-11-12T01:30:54.000Z');
  });

  it('returns an empty list for a line with no vehicles running', () => {
    expect(parseVehicles('[]', '142').vehicles).toHaveLength(0);
  });

  it('rejects placeholder coordinates outside Istanbul', () => {
    const json = JSON.stringify([
      { kapino: 'X-1', enlem: '0', boylam: '0', son_konum_zamani: '2026-11-12 04:30:54' },
      { kapino: 'X-2', enlem: '41.0', boylam: '28.7', son_konum_zamani: '2026-11-12 04:30:54' },
    ]);
    const { vehicles, rejected } = parseVehicles(json, '146');
    expect(vehicles.map((v) => v.doorNo)).toEqual(['X-2']);
    expect(rejected).toBe(1);
  });

  it('rejects records without a usable timestamp', () => {
    const json = JSON.stringify([
      { kapino: 'X-1', enlem: '41.0', boylam: '28.7' },
      { kapino: 'X-2', enlem: '41.0', boylam: '28.7', son_konum_zamani: 'not a date' },
    ]);
    expect(parseVehicles(json, '146').vehicles).toHaveLength(0);
    expect(parseVehicles(json, '146').rejected).toBe(2);
  });

  it('rejects a timestamp from the future', () => {
    const future = new Date(Date.now() + 3600_000);
    const pad = (n: number) => String(n).padStart(2, '0');
    const istanbul = new Date(future.getTime() + 3 * 3600_000);
    const s = `${istanbul.getUTCFullYear()}-${pad(istanbul.getUTCMonth() + 1)}-${pad(istanbul.getUTCDate())} ` +
              `${pad(istanbul.getUTCHours())}:${pad(istanbul.getUTCMinutes())}:${pad(istanbul.getUTCSeconds())}`;
    const json = JSON.stringify([{ kapino: 'X', enlem: '41.0', boylam: '28.7', son_konum_zamani: s }]);
    expect(parseVehicles(json, '146').rejected).toBe(1);
  });

  it('collapses duplicate records for the same fix', () => {
    const one = { kapino: 'D-1', enlem: '41.0', boylam: '28.7', son_konum_zamani: '2026-11-12 04:30:54' };
    const { vehicles, rejected } = parseVehicles(JSON.stringify([one, { ...one }]), '146');
    expect(vehicles).toHaveLength(1);
    expect(rejected).toBe(1);
  });

  it('reads Istanbul time as UTC+3', () => {
    expect(parseIstanbulTime('2026-11-12 04:30:54')!.toISOString())
      .toBe('2026-11-12T01:30:54.000Z');
    expect(parseIstanbulTime('nonsense')).toBeNull();
    expect(parseIstanbulTime(null)).toBeNull();
  });

  it('extracts and unescapes a SOAP element', () => {
    expect(extract('<a>x &amp; y</a>', 'a')).toBe('x & y');
    expect(extract('<a>x</a>', 'b')).toBeNull();
  });

  it('escapes the line code in the request envelope', () => {
    expect(soapEnvelope('M', '<tns:HatKodu>1&2</tns:HatKodu>')).toContain('1&2');
  });
});
