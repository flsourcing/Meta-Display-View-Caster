import { createServer } from 'http';
import express from 'express';
import cors from 'cors';
import { WebSocketServer } from 'ws';
import { randomInt, randomUUID } from 'crypto';

const PORT = process.env.PORT || 8080;
const CODE_ROTATION_MS = 300_000;

const app = express();
app.use(cors());
app.use(express.json());

/** @type {Map<string, object>} */
const sessions = new Map();
/** @type {Map<string, string>} */
const codeIndex = new Map();

function generateCode() {
  return String(randomInt(100000, 999999));
}

function send(ws, payload) {
  if (ws?.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

function rotateCode(session) {
  if (session.code) codeIndex.delete(session.code);
  let code;
  do { code = generateCode(); } while (codeIndex.has(code));
  session.code = code;
  session.codeExpiresAt = Date.now() + CODE_ROTATION_MS;
  codeIndex.set(code, session.sessionId);
  return code;
}

function sessionPayload(session) {
  return {
    code: session.code,
    expiresIn: Math.max(0, session.codeExpiresAt - Date.now()),
    relayOnline: !!session.relayWs,
    desktopOnline: !!session.desktopWs,
    glassesOnline: !!session.glassesWs,
  };
}

function broadcast(session, payload, except = null) {
  for (const ws of [session.relayWs, session.glassesWs, session.desktopWs]) {
    if (ws && ws !== except) send(ws, payload);
  }
}

function getSession(id) {
  return id ? sessions.get(id) : null;
}

function cleanupSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  if (session.code) codeIndex.delete(session.code);
  sessions.delete(sessionId);
}

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', sessions: sessions.size, uptime: process.uptime() });
});

const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  let role = null;
  let sessionId = null;

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch {
      send(ws, { type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'register-relay': {
        role = 'relay';
        sessionId = randomUUID();
        const session = {
          sessionId,
          relayWs: ws,
          glassesWs: null,
          desktopWs: null,
          code: '',
          codeExpiresAt: 0,
        };
        rotateCode(session);
        sessions.set(sessionId, session);
        send(ws, { type: 'relay-registered', role: 'relay', sessionId, ...sessionPayload(session) });
        break;
      }

      case 'join-glasses': {
        role = 'glasses';
        const code = String(msg.code || '').replace(/\D/g, '').slice(0, 6);
        const sid = codeIndex.get(code);
        const session = getSession(sid);
        if (!session || session.code !== code || !session.relayWs) {
          send(ws, { type: 'error', message: 'Code not found. Open the phone app and use its current code.' });
          return;
        }
        session.glassesWs = ws;
        sessionId = sid;
        send(ws, { type: 'relay-ack', role: 'glasses', ...sessionPayload(session) });
        send(session.relayWs, { type: 'glasses-joined', ...sessionPayload(session) });
        if (session.desktopWs) send(session.desktopWs, { type: 'glasses-joined', ...sessionPayload(session) });
        break;
      }

      case 'pair': {
        role = 'desktop';
        const code = String(msg.code || '').replace(/\D/g, '').slice(0, 6);
        const sid = codeIndex.get(code);
        const session = getSession(sid);
        if (!session || session.code !== code || !session.relayWs) {
          send(ws, { type: 'error', message: 'Code not found. Open the phone app and use its current code.' });
          return;
        }
        session.desktopWs = ws;
        sessionId = sid;
        send(ws, { type: 'relay-ack', role: 'desktop', ...sessionPayload(session) });
        send(session.relayWs, { type: 'desktop-joined', ...sessionPayload(session) });
        if (session.glassesWs) send(session.glassesWs, { type: 'desktop-joined', ...sessionPayload(session) });
        break;
      }

      case 'start-stream':
      case 'stop-stream':
      case 'stream-started':
      case 'stream-error':
      case 'offer':
      case 'answer':
      case 'ice-candidate': {
        const session = getSession(sessionId);
        if (!session) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        broadcast(session, msg, ws);
        break;
      }

      default:
        send(ws, { type: 'error', message: `Unknown: ${msg.type}` });
    }
  });

  ws.on('close', () => {
    if (!sessionId) return;
    const session = getSession(sessionId);
    if (!session) return;

    if (role === 'relay') {
      broadcast(session, { type: 'disconnected', message: 'Phone relay closed.' }, ws);
      cleanupSession(sessionId);
    } else if (role === 'glasses') {
      session.glassesWs = null;
      broadcast(session, { type: 'glasses-left' }, ws);
    } else if (role === 'desktop') {
      session.desktopWs = null;
      broadcast(session, { type: 'desktop-left' }, ws);
    }
  });
});

setInterval(() => {
  const now = Date.now();
  for (const session of sessions.values()) {
    if (!session.desktopWs && !session.glassesWs && now >= session.codeExpiresAt) {
      rotateCode(session);
      send(session.relayWs, { type: 'code-rotated', ...sessionPayload(session) });
    }
  }
}, 1000);

httpServer.listen(PORT, () => {
  console.log(`View Caster signaling on port ${PORT}`);
});
