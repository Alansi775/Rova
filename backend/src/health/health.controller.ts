import { Controller, Get } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { NetworkService } from '../network/network.service';
import { IngestionService } from '../vehicles/ingestion.service';

@Controller('health')
export class HealthController {
  constructor(
    private readonly db: DbService,
    private readonly network: NetworkService,
    private readonly ingestion: IngestionService,
  ) {}

  /** Unauthenticated liveness probe — carries no transit data. */
  @Get()
  async root() {
    return { service: 'rova-backend', version: '1.0.0', status: 'up', time: new Date().toISOString() };
  }

  /**
   * Honest provider health. `liveTrackingHealthy` is only true when a line has
   * fresh positions whose own source timestamps are still moving.
   */
  @Get('detail')
  async detail() {
    const dbOk = await this.db.ping();
    const lines = this.ingestion.healthReport.map((h) => {
      const sourceAge = h.latestSourceTime
        ? Math.round((Date.now() - h.latestSourceTime.getTime()) / 1000)
        : null;
      return {
        lineCode: h.lineCode,
        lastSuccessfulFetch: h.lastSuccess?.toISOString() ?? null,
        latestSourceTimestamp: h.latestSourceTime?.toISOString() ?? null,
        latestSourceAgeSeconds: sourceAge,
        validPositions: h.validPositions,
        stalePositions: h.stalePositions,
        rejectedRecords: h.rejected,
        error: h.error,
        liveTrackingHealthy:
          h.error === null &&
          h.validPositions > 0 &&
          sourceAge !== null &&
          sourceAge <= IngestionService.STALE_SECONDS,
      };
    });

    return {
      status: dbOk ? 'ok' : 'degraded',
      database: dbOk ? 'up' : 'down',
      network: {
        loaded: this.network.isLoaded,
        stops: this.network.stopCount,
        patterns: this.network.patternCount,
      },
      provider: {
        name: 'İETT FiloDurum/SeferGerceklesme — GetHatOtoKonum_json',
        hourlyRequestsRemaining: this.ingestion.budgetRemaining,
        lines,
        anyLineHealthy: lines.some((l) => l.liveTrackingHealthy),
      },
      time: new Date().toISOString(),
    };
  }
}
