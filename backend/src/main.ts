import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Logger } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import { AppModule } from './app.module';

async function bootstrap() {
  const log = new Logger('ROVA');

  if (process.env.NODE_ENV === 'production' && process.env.ROVA_DEMO_MODE === 'true') {
    log.error('ROVA_DEMO_MODE cannot be enabled in production. Refusing to start.');
    process.exit(1);
  }
  if (!process.env.ROVA_DEVICE_TOKEN) {
    log.warn('ROVA_DEVICE_TOKEN is not set — every /v1 request will be rejected.');
  }

  const app = await NestFactory.create(AppModule, { cors: false });
  app.useWebSocketAdapter(new WsAdapter(app));
  app.enableShutdownHooks();

  const port = Number(process.env.PORT ?? 3000);
  await app.listen(port, '0.0.0.0');
  log.log(`ROVA backend listening on :${port}`);
}

bootstrap();
