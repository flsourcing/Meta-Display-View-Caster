import { createServer } from 'http';
import express from 'express';
import cors from 'cors';
import { WebSocketServer } from 'ws';
import { randomInt, randomUUID } from 'crypto';

const PORT = process.env.PORT || 8080;
const CODE_ROTATION_MS = 300_000;
const RELAY_GRACE_MS = 900_000;
const VIEWER_PASSWORD = process.env.VIEWER_PASSWORD || 'Wedding';

function passwordsMatch(input, expected) {
  return String(input || '').trim().toLowerCase() === String(expected || '').trim().toLowerCase();
}

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
    desktopOnline: !!session.desktopWs || session.viewers.size > 0,
    glassesOnline: !!session.glassesWs,
    streaming: !!session.streaming,
    viewerCount: session.viewers.size,
  };
}

function sanitizeViewerName(raw) {
  const name = String(raw || '').trim().replace(/\s+/g, ' ').slice(0, 32);
  return name.length >= 1 ? name : '';
}

function buildViewerList(session) {
  const list = [];
  for (const [viewerId, viewer] of session.viewers.entries()) {
    list.push({
      viewerId,
      name: viewer.name || 'Guest',
      status: viewer.status || 'waiting',
    });
  }
  list.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
  return list;
}

function viewerSocket(viewer) {
  return viewer?.ws ?? viewer;
}

function broadcastViewerList(session, except = null) {
  const payload = { type: 'viewer-list-updated', viewers: buildViewerList(session) };
  if (session.relayWs && session.relayWs !== except) send(session.relayWs, payload);
  for (const viewer of session.viewers.values()) {
    const socket = viewerSocket(viewer);
    if (socket && socket !== except) send(socket, payload);
  }
}

function setAllViewerStatuses(session, status) {
  for (const viewer of session.viewers.values()) {
    viewer.status = status;
  }
}

function broadcast(session, payload, except = null) {
  const targets = [
    session.relayWs,
    session.glassesWs,
    session.desktopWs,
    ...[...session.viewers.values()].map(viewerSocket),
  ];
  for (const ws of targets) {
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

function findViewableSession() {
  for (const session of sessions.values()) {
    if (session.relayWs && session.streaming) return session;
  }
  for (const session of sessions.values()) {
    if (session.relayWs) return session;
  }
  return null;
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

function removeViewer(session, viewerId) {
  if (!viewerId) return;
  session.viewers.delete(viewerId);
  broadcastViewerList(session);
  if (session.relayWs) {
    send(session.relayWs, { type: 'viewer-left', viewerId, viewerCount: session.viewers.size });
  }
}

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', sessions: sessions.size, uptime: process.uptime() });
});

app.get('/live-status', (_req, res) => {
  const session = findViewableSession();
  res.json({
    relayOnline: !!session?.relayWs,
    streaming: !!session?.streaming,
    viewerCount: session?.viewers.size ?? 0,
  });
});

const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  let role = null;
  let sessionId = null;
  let viewerId = null;

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
          if (!session.viewers) session.viewers = new Map();
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
            viewers: new Map(),
            code: '',
            codeExpiresAt: 0,
            relayDetachedAt: 0,
            streaming: false,
          };
          rotateCode(session);
          sessions.set(sessionId, session);
        }

        send(ws, { type: 'relay-registered', role: 'relay', sessionId, ...sessionPayload(session) });
        if (session.glassesWs) {
          send(session.glassesWs, { type: 'relay-online', ...sessionPayload(session) });
        }
        for (const viewer of session.viewers.values()) {
          send(viewerSocket(viewer), { type: 'relay-online', ...sessionPayload(session) });
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
        for (const viewer of session.viewers.values()) {
          send(viewerSocket(viewer), { type: 'glasses-joined', ...sessionPayload(session) });
        }
        if (session.desktopWs) {
          send(session.desktopWs, { type: 'glasses-joined', ...sessionPayload(session) });
        }
        break;
      }

      case 'verify-viewer-password': {
        const password = String(msg.password || '').trim();
        if (!passwordsMatch(password, VIEWER_PASSWORD)) {
          send(ws, { type: 'error', message: 'Wrong password.' });
          return;
        }
        const session = findViewableSession();
        send(ws, {
          type: 'viewer-password-ok',
          relayOnline: !!session?.relayWs,
          streaming: !!session?.streaming,
        });
        break;
      }

      case 'join-viewer': {
        role = 'viewer';
        const password = String(msg.password || '').trim();
        if (!passwordsMatch(password, VIEWER_PASSWORD)) {
          send(ws, { type: 'error', message: 'Wrong password.' });
          return;
        }
        const name = sanitizeViewerName(msg.name);
        if (!name) {
          send(ws, { type: 'error', message: 'Enter a viewer name.' });
          return;
        }
        const session = findViewableSession();
        if (!session?.relayWs) {
          send(ws, { type: 'error', message: 'No cast active yet — keep View Caster open on the phone.' });
          return;
        }
        viewerId = randomUUID();
        session.viewers.set(viewerId, {
          ws,
          name,
          status: session.streaming ? 'watching' : 'waiting',
        });
        sessionId = session.sessionId;
        ws.viewerId = viewerId;
        const viewers = buildViewerList(session);
        send(ws, {
          type: 'viewer-ack',
          role: 'viewer',
          viewerId,
          viewers,
          ...sessionPayload(session),
        });
        broadcastViewerList(session, ws);
        send(session.relayWs, {
          type: 'viewer-joined',
          viewerId,
          name,
          status: session.streaming ? 'watching' : 'waiting',
          viewerCount: session.viewers.size,
          streaming: session.streaming,
          viewers,
        });
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

      case 'stop-stream': {
        const session = getSession(sessionId);
        if (session) {
          session.streaming = false;
          setAllViewerStatuses(session, 'waiting');
          broadcastViewerList(session);
        }
        const s = getSession(sessionId);
        if (!s) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        broadcast(s, msg, ws);
        break;
      }

      case 'stream-starting':
      case 'stream-error': {
        const session = getSession(sessionId);
        if (!session) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        broadcast(session, msg, ws);
        break;
      }

      case 'stream-started': {
        const session = getSession(sessionId);
        if (session) {
          session.streaming = true;
          setAllViewerStatuses(session, 'watching');
          broadcastViewerList(session);
        }
        const s = getSession(sessionId);
        if (!s) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        broadcast(s, msg, ws);
        break;
      }

      case 'offer': {
        const session = getSession(sessionId);
        if (!session) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        const targetViewer = msg.viewerId;
        if (targetViewer && session.viewers.has(targetViewer)) {
          send(viewerSocket(session.viewers.get(targetViewer)), msg);
        } else if (session.desktopWs) {
          send(session.desktopWs, msg);
        } else {
          for (const viewer of session.viewers.values()) send(viewerSocket(viewer), msg);
        }
        break;
      }

      case 'answer': {
        const session = getSession(sessionId);
        if (!session?.relayWs) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        send(session.relayWs, msg);
        break;
      }

      case 'ice-candidate': {
        const session = getSession(sessionId);
        if (!session) {
          send(ws, { type: 'error', message: 'Not in a session.' });
          return;
        }
        if (role === 'relay') {
          const targetViewer = msg.viewerId;
          if (targetViewer && session.viewers.has(targetViewer)) {
            send(viewerSocket(session.viewers.get(targetViewer)), msg);
          } else if (session.desktopWs) {
            send(session.desktopWs, msg);
          } else {
            for (const viewer of session.viewers.values()) send(viewerSocket(viewer), msg);
          }
        } else if (session.relayWs) {
          send(session.relayWs, msg);
        }
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
      session.streaming = false;
      broadcast(session, { type: 'relay-offline', message: 'Phone relay paused — reopen the phone app.' }, ws);
    } else if (role === 'glasses') {
      session.glassesWs = null;
      broadcast(session, { type: 'glasses-left' }, ws);
    } else if (role === 'desktop') {
      session.desktopWs = null;
      broadcast(session, { type: 'desktop-left' }, ws);
    } else if (role === 'viewer' && viewerId) {
      removeViewer(session, viewerId);
    }
  });
});

setInterval(() => {
  const now = Date.now();
  for (const [sessionId, session] of sessions.entries()) {
    const relayGone = !session.relayWs;
    const idle = !session.desktopWs && !session.glassesWs && session.viewers.size === 0;

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
