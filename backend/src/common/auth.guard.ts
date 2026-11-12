import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';

/**
 * ROVA is a single-user product, so there is no account system — but the
 * backend is never left open. Every /v1 route requires the private device
 * token from ROVA_DEVICE_TOKEN. The guard is written so that swapping in a
 * per-user token table later does not change any controller.
 */
@Injectable()
export class DeviceTokenGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const expected = process.env.ROVA_DEVICE_TOKEN;
    if (!expected) {
      throw new UnauthorizedException('ROVA_DEVICE_TOKEN is not configured on the server');
    }
    const req = ctx.switchToHttp().getRequest();
    const header: string = req.headers?.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!token || !timingSafeEqual(token, expected)) {
      throw new UnauthorizedException('invalid device token');
    }
    return true;
  }
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
