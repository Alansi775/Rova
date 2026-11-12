import { readFileSync } from 'fs';
import { join } from 'path';
import { Pool } from 'pg';

async function main() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error('DATABASE_URL is not set');
  const pool = new Pool({ connectionString: url });
  const sql = readFileSync(join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(sql);
  const { rows } = await pool.query(
    `SELECT table_name FROM information_schema.tables
     WHERE table_schema='public' ORDER BY table_name`);
  console.log('migrated. tables:');
  for (const r of rows) console.log('  ·', r.table_name);
  await pool.end();
}

main().catch((e) => { console.error(e.message); process.exit(1); });
