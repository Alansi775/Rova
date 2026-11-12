import { Injectable, OnModuleDestroy, Logger } from '@nestjs/common';
import { Pool, QueryResultRow } from 'pg';

@Injectable()
export class DbService implements OnModuleDestroy {
  private readonly log = new Logger(DbService.name);
  private readonly pool: Pool;
  private healthy = false;

  constructor() {
    this.pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 8,
      idleTimeoutMillis: 30_000,
    });
    this.pool.on('error', (e) => this.log.error(`pool error: ${e.message}`));
  }

  async query<T extends QueryResultRow = any>(sql: string, params: any[] = []): Promise<T[]> {
    const r = await this.pool.query<T>(sql, params);
    this.healthy = true;
    return r.rows;
  }

  async ping(): Promise<boolean> {
    try { await this.pool.query('SELECT 1'); this.healthy = true; }
    catch { this.healthy = false; }
    return this.healthy;
  }

  get isHealthy() { return this.healthy; }

  async onModuleDestroy() { await this.pool.end(); }
}
