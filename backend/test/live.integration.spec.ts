/**
 * Integration tests that talk to the real İETT service.
 *
 * These are NOT mocked. They are skipped only when ROVA_LIVE_TESTS is unset,
 * so a CI run without outbound network does not report a false pass.
 *
 *   ROVA_LIVE_TESTS=1 npx jest live
 */
import { IettClient, parseVehicles } from '../src/iett/iett.client';

const live = process.env.ROVA_LIVE_TESTS ? describe : describe.skip;

live('İETT live service', () => {
  jest.setTimeout(90_000);
  const client = new IettClient();

  it('answers GetHatOtoKonum_json with a parseable payload', async () => {
    const res = await client.vehicles('146');
    expect(Array.isArray(res.vehicles)).toBe(true);
    expect(res.latencyMs).toBeLessThan(25_000);
    // An empty list is a legitimate answer outside service hours; what must
    // hold is that every record we *did* accept is well formed.
    for (const v of res.vehicles) {
      expect(v.doorNo).toBeTruthy();
      expect(v.lat).toBeGreaterThan(40.5);
      expect(v.lat).toBeLessThan(41.9);
      expect(v.lon).toBeGreaterThan(27.0);
      expect(v.lon).toBeLessThan(30.5);
      expect(v.sourceTime.getTime()).toBeLessThanOrEqual(Date.now() + 120_000);
      expect(v.patternId).toMatch(/^[A-Z0-9]+_[DG]_/);
    }
    console.log(`  146 → ${res.vehicles.length} vehicles in ${res.latencyMs} ms`);
  });

  it('reports fresh source timestamps while buses are running', async () => {
    const res = await client.vehicles('146');
    if (!res.vehicles.length) {
      console.warn('  no vehicles on 146 right now — freshness not asserted');
      return;
    }
    const ages = res.vehicles.map((v) => (Date.now() - v.sourceTime.getTime()) / 1000);
    const youngest = Math.min(...ages);
    console.log(`  freshest fix: ${Math.round(youngest)} s old`);
    expect(youngest).toBeLessThan(900);
  });

  it('refuses to exceed the hourly request budget', async () => {
    const tiny = new IettClient();
    (tiny as any).budget = { consume: () => false, remaining: 0 };
    await expect(tiny.vehicles('146')).rejects.toThrow(/budget/);
  });

  it('observes movement between two polls of the same line', async () => {
    const first = await client.vehicles('146');
    if (!first.vehicles.length) {
      console.warn('  no vehicles on 146 right now — movement not asserted');
      return;
    }
    await new Promise((r) => setTimeout(r, 45_000));
    const second = await client.vehicles('146');
    const byDoor = new Map(first.vehicles.map((v) => [v.doorNo, v]));
    const moved = second.vehicles.filter((v) => {
      const a = byDoor.get(v.doorNo);
      return a && a.sourceTime.getTime() !== v.sourceTime.getTime();
    });
    console.log(`  ${moved.length}/${second.vehicles.length} vehicles reported a new fix in 45 s`);
    // Movement is a property of the city, not of ROVA, so this is reported
    // rather than asserted — but the timestamps must never go backwards.
    for (const v of second.vehicles) {
      const a = byDoor.get(v.doorNo);
      if (a) expect(v.sourceTime.getTime()).toBeGreaterThanOrEqual(a.sourceTime.getTime());
    }
  });

  it('reads the full stop list from the network service', async () => {
    const stops = await client.stops();
    expect(stops.length).toBeGreaterThan(10_000);
    const sample = stops.find((s: any) => String(s.SDURAKKODU) === '101452');
    expect(sample?.SDURAKADI).toContain('AVCILAR');
  });
});

describe('parser contract (offline)', () => {
  it('matches the shape İETT actually returns', () => {
    const captured = `[{"kapino":"B-1887","boylam":"28.66874","enlem":"41.06737","hatkodu":"146","guzergahkodu":"146_G_D6038","hatad":"X","yon":"Y","son_konum_zamani":"2026-11-12 04:30:54","yakinDurakKodu":"128071"}]`;
    expect(parseVehicles(captured, '146').vehicles).toHaveLength(1);
  });
});
