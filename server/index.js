import { createServer } from 'http';
import express from 'express';
import cors from 'cors';
import { WebSocketServer } from 'ws';
import { randomInt, randomUUID } from 'crypto';

const PORT = process.env.PORT || 8080;
const CODE_ROTATION_MS = 300_000;
const RELAY_GRACE_MS = 900_000;

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

function findSessionByCode(code) {
  const sid = codeIndex.get(code);
  return sid ? sessions.get(sid) : null;
}

function joinError(session, code) {
  if (!session) {
    return 'Code not found. Open the phone app, wait for a 6-digit code, then enter it here.';
  }
  if (session.code !== code) {
    return 'Code expired. Check the phone app for the current 6-digit code.';
  }
  return null;
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
        const reconnectId = typeof msg.sessionId === 'string' ? msg.sessionId : '';
        let session = reconnectId ? getSession(reconnectId) : null;

        if (session) {
          session.relayWs = ws;
          session.relayDetachedAt = 0;
          sessionId = session.sessionId;
          if (!session.code || !codeIndex.has(session.code)) {
            rotateCode(session);
          } else {
            session.codeExpiresAt = Date.now() + CODE_ROTATION_MS;
          }
        } else {
          sessionId = randomUUID();
          session = {
            sessionId,
            relayWs: ws,
            glassesWs: null,
            desktopWs: null,
            code: '',
            codeExpiresAt: 0,
            relayDetachedAt: 0,
          };
          rotateCode(session);
          sessions.set(sessionId, session);
        }

        send(ws, { type: 'relay-registered', role: 'relay', sessionId, ...sessionPayload(session) });
        if (session.glassesWs) {
          send(session.glassesWs, { type: 'relay-online', ...sessionPayload(session) });
        }
        if (session.desktopWs) {
          send(session.desktopWs, { type: 'relay-online', ...sessionPayload(session) });
        }
        break;
      }

      case 'join-glasses': {
        role = 'glasses';
        const code = String(msg.code || '').replace(/\D/g, '').slice(0, 6);
        const session = findSessionByCode(code);
        const err = joinError(session, code);
        if (err) {
          send(ws, { type: 'error', message: err });
          return;
        }
        session.glassesWs = ws;
        sessionId = session.sessionId;
        send(ws, { type: 'relay-ack', role: 'glasses', ...sessionPayload(session) });
        if (session.relayWs) {
          send(session.relayWs, { type: 'glasses-joined', ...sessionPayload(session) });
        }
        if (session.desktopWs) {
          send(session.desktopWs, { type: 'glasses-joined', ...sessionPayload(session) });
        }
        break;
      }

      case 'pair': {
        role = 'desktop';
        const code = String(msg.code || '').replace(/\D/g, '').slice(0, 6);
        const session = findSessionByCode(code);
        const err = joinError(session, code);
        if (err) {
          send(ws, { type: 'error', message: err });
          return;
        }
        session.desktopWs = ws;
        sessionId = session.sessionId;
        send(ws, { type: 'relay-ack', role: 'desktop', ...sessionPayload(session) });
        if (session.relayWs) {
          send(session.relayWs, { type: 'desktop-joined', ...sessionPayload(session) });
        }
        if (session.glassesWs) {
          send(session.glassesWs, { type: 'desktop-joined', ...sessionPayload(session) });
        }
        break;
      }

      case 'start-stream': {
        const session = getSession(sessionId);
        if (!session) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        if (!session.relayWs) {
          send(ws, {
            type: 'stream-error',
            message: 'Phone relay offline — open View Caster on your phone first.',
          });
          return;
        }
        broadcast(session, msg, ws);
        break;
      }

      case 'stop-stream':
      case 'stream-starting':
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
      session.relayWs = null;
      session.relayDetachedAt = Date.now();
      broadcast(session, { type: 'relay-offline', message: 'Phone relay paused — reopen the phone app.' }, ws);
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
  for (const [sessionId, session] of sessions.entries()) {
    const relayGone = !session.relayWs;
    const idle = !session.desktopWs && !session.glassesWs;

    if (relayGone && session.relayDetachedAt && now - session.relayDetachedAt > RELAY_GRACE_MS && idle) {
      cleanupSession(sessionId);
      continue;
    }

    if (session.relayWs && idle && now >= session.codeExpiresAt) {
      rotateCode(session);
      send(session.relayWs, { type: 'code-rotated', ...sessionPayload(session) });
    }
  }
}, 1000);

httpServer.listen(PORT, () => {
  console.log(`View Caster signaling on port ${PORT}`);
});
