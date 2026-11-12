import { Logger, OnModuleInit } from '@nestjs/common';
import {
  OnGatewayConnection, OnGatewayDisconnect, WebSocketGateway, WebSocketServer,
} from '@nestjs/websockets';
import { Server, WebSocket } from 'ws';
import { IngestionService } from '../vehicles/ingestion.service';

interface Client { socket: WebSocket; lines: Set<string>; authed: boolean }

/**
 * Pushes validated vehicle updates to subscribed clients. Clients authenticate
 * with the same device token as the REST API and subscribe per line, so a bus
 * moving on one line never wakes a client watching another.
 */
@WebSocketGateway({ path: '/ws' })
export class TrackingGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit {
  private readonly log = new Logger(TrackingGateway.name);
  @WebSocketServer() server: Server;
  private clients = new Map<WebSocket, Client>();

  constructor(private readonly ingestion: IngestionService) {}

  onModuleInit() {
    this.ingestion.onVehicles((line, vehicles) => {
      const payload = JSON.stringify({
        type: 'vehicles',
        lineCode: line,
        at: new Date().toISOString(),
        vehicles: vehicles.map((v) => ({
          vehicleId: v.doorNo,
          patternId: v.patternId,
          position: { lat: v.lat, lon: v.lon },
          sourceTime: v.sourceTime.toISOString(),
          ageSeconds: Math.round((Date.now() - v.sourceTime.getTime()) / 1000),
        })),
      });
      for (const c of this.clients.values()) {
        if (c.authed && c.lines.has(line) && c.socket.readyState === c.socket.OPEN) {
          c.socket.send(payload);
        }
      }
    });
  }

  handleConnection(socket: WebSocket) {
    this.clients.set(socket, { socket, lines: new Set(), authed: false });
    socket.on('message', (raw) => this.onMessage(socket, raw.toString()));
    socket.send(JSON.stringify({ type: 'hello', authRequired: true }));
  }

  handleDisconnect(socket: WebSocket) { this.clients.delete(socket); }

  private onMessage(socket: WebSocket, raw: string) {
    const c = this.clients.get(socket);
    if (!c) return;
    let msg: any;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.type === 'auth') {
      const expected = process.env.ROVA_DEVICE_TOKEN;
      c.authed = Boolean(expected) && msg.token === expected;
      socket.send(JSON.stringify({ type: 'auth', ok: c.authed }));
      if (!c.authed) socket.close(4001, 'invalid device token');
      return;
    }
    if (!c.authed) return;

    if (msg.type === 'subscribe' && Array.isArray(msg.lines)) {
      c.lines = new Set(msg.lines.map(String));
      // Subscribing is the statement "I am travelling on these lines", so it
      // must also drive ingestion focus. Without this a socket client was
      // pushed updates promptly — but only every seven minutes, because
      // nothing had told the ingester the line mattered.
      for (const l of c.lines) this.ingestion.watch(l);
      socket.send(JSON.stringify({
        type: 'subscribed',
        lines: [...c.lines],
        focused: this.ingestion.focusSet,
      }));
    }

    // Keep the subscription alive without re-subscribing: the focus TTL is
    // 15 minutes and a long ride outlasts it.
    if (msg.type === 'ping') {
      for (const l of c.lines) this.ingestion.watch(l);
      socket.send(JSON.stringify({ type: 'pong', at: new Date().toISOString() }));
    }
  }
}
