import { metres, snap, cumulative } from '../src/common/geo';

describe('geometry', () => {
  const istanbul = { lat: 41.0, lon: 28.7 };

  it('measures distance against a known pair', () => {
    // Şafak Residence → Avcılar Metrobüs, straight line.
    const d = metres({ lat: 41.016013, lon: 28.683227 }, { lat: 40.985755, lon: 28.724028 });
    expect(d).toBeGreaterThan(4300);
    expect(d).toBeLessThan(5000);
  });

  it('is symmetric and zero for identical points', () => {
    expect(metres(istanbul, istanbul)).toBeCloseTo(0, 6);
    const b = { lat: 41.01, lon: 28.71 };
    expect(metres(istanbul, b)).toBeCloseTo(metres(b, istanbul), 6);
  });

  it('snaps a point onto the nearest segment', () => {
    const line = [{ lat: 41.0, lon: 28.7 }, { lat: 41.0, lon: 28.8 }, { lat: 41.1, lon: 28.8 }];
    const p = snap({ lat: 41.0005, lon: 28.75 }, line)!;
    expect(p.segment).toBe(0);
    expect(p.t).toBeGreaterThan(0.4);
    expect(p.t).toBeLessThan(0.6);
    expect(p.offset).toBeLessThan(80);
    const cum = cumulative(line);
    expect(p.along).toBeGreaterThan(0);
    expect(p.along).toBeLessThan(cum[1]);
  });

  it('reports a large offset for an off-route point', () => {
    const line = [{ lat: 41.0, lon: 28.7 }, { lat: 41.0, lon: 28.8 }];
    expect(snap({ lat: 41.05, lon: 28.75 }, line)!.offset).toBeGreaterThan(4000);
  });

  it('returns null for a degenerate line', () => {
    expect(snap(istanbul, [])).toBeNull();
    expect(snap(istanbul, [istanbul])).toBeNull();
  });

  it('accumulates distance monotonically', () => {
    const cum = cumulative([{ lat: 41, lon: 28.7 }, { lat: 41, lon: 28.75 }, { lat: 41, lon: 28.8 }]);
    expect(cum[0]).toBe(0);
    expect(cum[1]).toBeLessThan(cum[2]);
  });
});
