/**
 * Seeds PostgreSQL from the ROVA transit bundle that ships with the iOS app
 * (built by tools/build_bundle.py from the İETT SOAP service + İBB GTFS).
 *
 *   npx ts-node src/db/seed.ts [path-to-rova-transit.sqlite]
 */
import { DatabaseSync } from 'node:sqlite';
import { Pool } from 'pg';
import { join } from 'path';

const bundle =
  process.argv[2] ?? join(__dirname, '../../../ios/ROVA/Resources/rova-transit.sqlite');

async function main() {
  const lite = new DatabaseSync(bundle, { readOnly: true });
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  const client = await pool.connect();

  const copy = async (
    label: string,
    sql: string,
    target: string,
    cols: string[],
    map: (r: any) => any[],
    conflict: string,
  ) => {
    const rows = lite.prepare(sql).all() as any[];
    await client.query('BEGIN');
    await client.query(`DELETE FROM ${target}`);
    const chunk = 1000;
    for (let i = 0; i < rows.length; i += chunk) {
      const slice = rows.slice(i, i + chunk);
      const values: any[] = [];
      const tuples = slice.map((r, j) => {
        const v = map(r);
        values.push(...v);
        return `(${v.map((_, k) => `$${j * v.length + k + 1}`).join(',')})`;
      });
      await client.query(
        `INSERT INTO ${target} (${cols.join(',')}) VALUES ${tuples.join(',')} ${conflict}`,
        values,
      );
    }
    await client.query('COMMIT');
    console.log(`  · ${label}: ${rows.length}`);
  };

  console.log(`seeding from ${bundle}`);

  await copy(
    'stops',
    'SELECT code,name,lat,lon,district,direction FROM stop',
    'transport_stops',
    ['stop_code', 'name', 'lat', 'lon', 'district', 'direction'],
    (r) => [r.code, r.name, r.lat, r.lon, r.district, r.direction],
    'ON CONFLICT (stop_code) DO NOTHING',
  );

  await copy(
    'lines',
    'SELECT code,name,length_km,trip_min FROM line',
    'transport_routes',
    ['line_code', 'name', 'length_km', 'trip_minutes'],
    (r) => [r.code, r.name, r.length_km, r.trip_min],
    'ON CONFLICT (line_code) DO NOTHING',
  );

  await copy(
    'patterns',
    'SELECT id,line,direction,headsign,stop_count FROM pattern',
    'transit_patterns',
    ['pattern_id', 'line_code', 'direction', 'headsign', 'stop_count'],
    (r) => [r.id, r.line, r.direction, r.headsign, r.stop_count],
    'ON CONFLICT (pattern_id) DO NOTHING',
  );

  await copy(
    'route stops',
    'SELECT pattern,seq,stop,offset_sec FROM pattern_stop',
    'route_stops',
    ['pattern_id', 'seq', 'stop_code', 'offset_sec'],
    (r) => [r.pattern, r.seq, r.stop, r.offset_sec],
    'ON CONFLICT (pattern_id, seq) DO NOTHING',
  );

  await copy(
    'trips',
    'SELECT pattern,service,start_sec FROM departure',
    'transit_trips',
    ['pattern_id', 'service_id', 'start_sec'],
    (r) => [r.pattern, r.service, r.start_sec],
    '',
  );

  client.release();
  await pool.end();
  lite.close();
  console.log('seed complete');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
