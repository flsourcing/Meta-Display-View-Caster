import { createServer } from 'http';
import express from 'express';
import cors from 'cors';
import { WebSocketServer } from 'ws';
import { randomInt } from 'crypto';
import { v4 as uuidv4 } from 'uuid';

const PORT = process.env.PORT || 8080;
const CODE_ROTATION_MS = 60_000;

const app = express();
app.use(cors());
app.use(express.json());

/** @type {Map<string, { sessionId: string, glassesWs: import('ws').WebSocket, code: string, codeExpiresAt: number, desktopWs: import('ws').WebSocket | null, paired: boolean }>} */
const sessions = new Map();

/** @type {Map<string, string>} code -> sessionId */
const codeIndex = new Map();

function generateCode() {
  return String(randomInt(100000, 999999));
}

function rotateCode(session) {
  if (session.code) {
    codeIndex.delete(session.code);
  }
  let code;
  do {
    code = generateCode();
  } while (codeIndex.has(code));
  session.code = code;
  session.codeExpiresAt = Date.now() + CODE_ROTATION_MS;
  codeIndex.set(code, session.sessionId);
  return code;
}

function getSessionPayload(session) {
  return {
    type: 'code',
    code: session.code,
    expiresIn: Math.max(0, session.codeExpiresAt - Date.now()),
    paired: session.paired,
  };
}

function send(ws, payload) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function broadcastSessionState(session) {
  send(session.glassesWs, { type: 'session', ...getSessionPayload(session), role: 'glasses' });
  if (session.desktopWs) {
    send(session.desktopWs, { type: 'session', ...getSessionPayload(session), role: 'desktop', connected: session.paired });
  }
}

function cleanupSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  if (session.code) codeIndex.delete(session.code);
  sessions.delete(sessionId);
}

function relay(fromWs, session, payload) {
  const target = fromWs === session.glassesWs ? session.desktopWs : session.glassesWs;
  send(target, payload);
}

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', sessions: sessions.size });
});

const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  let role = null;
  let sessionId = null;

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      send(ws, { type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'register-glasses': {
        role = 'glasses';
        sessionId = uuidv4();
        const session = {
          sessionId,
          glassesWs: ws,
          code: '',
          codeExpiresAt: 0,
          desktopWs: null,
          paired: false,
        };
        rotateCode(session);
        sessions.set(sessionId, session);
        send(ws, { type: 'registered', sessionId, role: 'glasses', ...getSessionPayload(session) });
        break;
      }

      case 'pair': {
        role = 'desktop';
        const code = String(msg.code || '').trim();
        const targetSessionId = codeIndex.get(code);
        if (!targetSessionId) {
          send(ws, { type: 'error', message: 'Invalid or expired code. Check the code on your glasses.' });
          return;
        }
        const session = sessions.get(targetSessionId);
        if (!session || session.code !== code) {
          send(ws, { type: 'error', message: 'Code expired. Enter the new code shown on your glasses.' });
          return;
        }
        if (session.paired && session.desktopWs && session.desktopWs !== ws) {
          send(ws, { type: 'error', message: 'This session is already connected to another device.' });
          return;
        }
        session.desktopWs = ws;
        session.paired = true;
        sessionId = targetSessionId;
        send(ws, { type: 'paired', sessionId, role: 'desktop', connected: true });
        send(session.glassesWs, { type: 'paired', sessionId, role: 'glasses', connected: true });
        broadcastSessionState(session);
        break;
      }

      case 'start-stream':
      case 'stop-stream':
      case 'offer':
      case 'answer':
      case 'ice-candidate': {
        const session = sessions.get(sessionId);
        if (!session || !session.paired) {
          send(ws, { type: 'error', message: 'Not connected to a session.' });
          return;
        }
        relay(ws, session, msg);
        break;
      }

      default:
        send(ws, { type: 'error', message: `Unknown message type: ${msg.type}` });
    }
  });

  ws.on('close', () => {
    if (!sessionId) return;
    const session = sessions.get(sessionId);
    if (!session) return;

    if (role === 'glasses') {
      if (session.desktopWs) {
        send(session.desktopWs, { type: 'disconnected', message: 'Glasses disconnected.' });
      }
      cleanupSession(sessionId);
    } else if (role === 'desktop') {
      session.desktopWs = null;
      session.paired = false;
      send(session.glassesWs, { type: 'disconnected', message: 'Desktop disconnected.' });
      broadcastSessionState(session);
    }
  });
});

setInterval(() => {
  const now = Date.now();
  for (const session of sessions.values()) {
    if (now >= session.codeExpiresAt) {
      rotateCode(session);
      broadcastSessionState(session);
    }
  }
}, 1000);

httpServer.listen(PORT, () => {
  console.log(`Meta Display View Caster signaling server on port ${PORT}`);
});
