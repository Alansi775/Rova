import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ScheduleModule } from '@nestjs/schedule';
import { DbModule } from './db/db.module';
import { NetworkService } from './network/network.service';
import { IettClient } from './iett/iett.client';
import { IngestionService } from './vehicles/ingestion.service';
import { VehiclesController } from './vehicles/vehicles.controller';
import { EtaService } from './eta/eta.service';
import { PredictionsService } from './predictions/predictions.service';
import { SamplerService } from './predictions/sampler.service';
import { TrackingGateway } from './tracking/tracking.gateway';
import { HealthController } from './health/health.controller';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ScheduleModule.forRoot(),
    DbModule,
  ],
  controllers: [HealthController, VehiclesController],
  providers: [NetworkService, IettClient, IngestionService, EtaService,
              PredictionsService, SamplerService, TrackingGateway],
})
export class AppModule {}
