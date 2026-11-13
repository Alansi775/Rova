/**
 * The failure that froze the map.
 *
 * İETT's fleet service returns a sporadic HTTP 503 for one line while serving
 * the others normally. The client used to answer that with a single global
 * backoff, so one line's hiccup stopped every line for up to fifteen minutes
 * and the whole map went stale at once.
 *
 * The ingestion log for 2026-11-13 measures the amplification: in the 10:00
 * hour, 17 genuine 503s produced 107 further attempts refused by our own
 * backoff, and for roughly forty minutes no request left the machine at all.
 *
 * These tests use a fake transport, so they assert our backoff policy rather
 * than İETT's availability. The live tests cover the real service.
 */
import { IettClient } from '../src/iett/iett.client';

/** Fails for `failing`, answers an empty but valid payload for anything else. */
function stubFetch(failing: Set<string>, status = 503) {
  return jest.fn(async (_url: any, init: any) => {
    const line = /<tns:HatKodu>([^<]*)</.exec(String(init.body))?.[1] ?? '';
    if (failing.has(line)) {
      return { ok: false, status, text: async () => 'Service Unavailable' } as any;
    }
    return {
      ok: true,
      status: 200,
      text: async () =>
        '<GetHatOtoKonum_jsonResult>[]</GetHatOtoKonum_jsonResult>',
    } as any;
  });
}

describe('İETT backoff is scoped to the line that failed', () => {
  const realFetch = global.fetch;
  afterEach(() => { global.fetch = realFetch; jest.useRealTimers(); });

  it('does not stop a healthy line because another line is failing', async () => {
    global.fetch = stubFetch(new Set(['142'])) as any;
    const c = new IettClient();

    await expect(c.vehicles('142')).rejects.toThrow(/503|fleet service/);
    expect(c.backoffFor('142')).toBeGreaterThan(0);

    // The line that never failed must still be fetchable. This is the whole
    // bug: before the fix, this call threw "backing off".
    expect(c.backoffFor('34BZ')).toBe(0);
    await expect(c.vehicles('34BZ')).resolves.toMatchObject({ vehicles: [] });
  });

  it('rests a repeatedly failing line for longer, but never past the cap', async () => {
    global.fetch = stubFetch(new Set(['142'])) as any;
    const c = new IettClient();

    const waits: number[] = [];
    for (let i = 0; i < 7; i++) {
      // Expire the rest without forgetting the failures, which is what
      // actually happens when the clock moves on.
      const b = (c as any).lineBackoff.get('142');
      if (b) b.until = 0;
      await expect(c.vehicles('142')).rejects.toThrow();
      waits.push(c.backoffFor('142'));
    }

    expect(waits[1]).toBeGreaterThan(waits[0]);                  // it escalates
    expect(waits[6]).toBe(IettClient.MAX_LINE_BACKOFF_MS);       // and then stops
    for (const w of waits) {
      expect(w).toBeLessThanOrEqual(IettClient.MAX_LINE_BACKOFF_MS);
    }
  }, 30_000);

  it('clears a line\'s history as soon as that line answers', async () => {
    const failing = new Set(['142']);
    global.fetch = stubFetch(failing) as any;
    const c = new IettClient();

    await expect(c.vehicles('142')).rejects.toThrow();
    expect(c.backoffFor('142')).toBeGreaterThan(0);

    failing.delete('142');
    (c as any).lineBackoff.delete('142');
    await c.vehicles('142');
    expect(c.backoffFor('142')).toBe(0);
    expect(c.consecutiveFailures).toBe(0);
  });

  it('stops everything when the quota is genuinely refused, because that is IP-wide', async () => {
    // A real quota refusal says so. That is not about one line, so resting a
    // single line would be the wrong response: every other line would be
    // refused too, burning what little budget is left.
    global.fetch = jest.fn(async () => ({
      ok: false, status: 500,
      text: async () =>
        '<faultstring>Policy Falsified</faultstring>' +
        '<l7:policyResult status="Exceeded Quota"/>',
    })) as any;
    const c = new IettClient();

    await expect(c.vehicles('142')).rejects.toThrow(/Policy Falsified/);
    expect(c.isBackingOff).toBe(true);
    await expect(c.vehicles('34BZ')).rejects.toThrow(/quota exhausted/);
  }, 15_000);

  it('does not call an outage a quota problem', async () => {
    // On 2026-11-13 the gateway returned "Policy Falsified" while we were
    // making 40 calls an hour against a ~100 ceiling, and was serving bare
    // HTML 503s for İBB's Metro endpoint at the same moment: the whole of
    // api.ibb.gov.tr was down. Blaming our quota there would have put a
    // confident falsehood in our own health output and sent us hunting the
    // wrong bug. Without an explicit quota assertion it is just a failure,
    // so it rests one line and leaves the rest free to try.
    global.fetch = jest.fn(async () => ({
      ok: false, status: 500,
      text: async () =>
        '<faultstring>Policy Falsified</faultstring>' +
        '<l7:policyResult status="Error in Assertion Processing"/>',
    })) as any;
    const c = new IettClient();

    await expect(c.vehicles('142')).rejects.toThrow();
    expect(c.isBackingOff).toBe(false);
    expect(c.backoffFor('142')).toBeGreaterThan(0);
    expect(c.backoffFor('34BZ')).toBe(0);
  }, 15_000);
});

describe('the request budget counts every call that reaches İETT', () => {
  const realFetch = global.fetch;
  afterEach(() => { global.fetch = realFetch; });

  it('charges the 5xx retry, so a fault burst cannot overrun the quota', async () => {
    // One logical fetch that hits a 503 makes two HTTP calls. İETT counts
    // both. Before the fix the second was free, and a burst of them took the
    // real rate past İETT's ceiling while our own counter still looked safe.
    let calls = 0;
    global.fetch = jest.fn(async () => {
      calls++;
      return { ok: false, status: 503, text: async () => 'Service Unavailable' } as any;
    }) as any;

    const c = new IettClient();
    const before = c.budget.remaining;
    await expect(c.vehicles('142')).rejects.toThrow();

    expect(calls).toBe(2);
    expect(before - c.budget.remaining).toBe(calls);
  }, 15_000);

  it('does not retry when the budget cannot afford it', async () => {
    let calls = 0;
    global.fetch = jest.fn(async () => {
      calls++;
      return { ok: false, status: 503, text: async () => 'Service Unavailable' } as any;
    }) as any;

    const c = new IettClient();
    // Exactly one slot left: the first attempt may go, the retry may not.
    (c as any).budget = {
      remaining: 1,
      consume() { if (this.remaining <= 0) return false; this.remaining--; return true; },
    };

    await expect(c.vehicles('142')).rejects.toThrow();
    expect(calls).toBe(1);
  }, 15_000);

  it('leaves headroom under İETT\'s published ceiling', () => {
    // İETT publishes ~100/hour. A ceiling with no slack is not a ceiling.
    expect(new IettClient().budget.remaining).toBeLessThanOrEqual(80);
  });
});
