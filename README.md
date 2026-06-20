# Meta Display View Caster

Cast the live view from your Meta Display glasses to a desktop browser. Pair your glasses with a 6-digit code that rotates every minute, then start a live WebRTC stream from your computer.

## How it works

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│  Glasses        │◄───────►│  Signaling       │◄───────►│  Desktop        │
│  glasses.html   │   WS    │  Server          │   WS    │  index.html     │
│  (pairing code) │         │  (pair + relay)  │         │  (enter code)   │
└────────┬────────┘         └──────────────────┘         └────────┬────────┘
         │                                                         │
         └──────────────── WebRTC video stream ────────────────────┘
```

1. **Glasses** — Open `glasses.html` on your Meta Display. A 6-digit code appears and refreshes every 60 seconds.
2. **Desktop** — Open the GitHub Pages site, enter the code, and click **Connect**.
3. **Both devices** show **Connected**.
4. **Desktop** — Click **Live Stream** to receive the glasses camera feed in your browser.

## URLs (after deployment)

| Page | URL | Device |
|------|-----|--------|
| Desktop viewer | `https://flsourcing.github.io/Meta-Display-View-Caster/` | Computer |
| Glasses app | `https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html` | Meta Display glasses |

## Setup

### 1. Enable GitHub Pages

1. Push this repo to [github.com/flsourcing/Meta-Display-View-Caster](https://github.com/flsourcing/Meta-Display-View-Caster).
2. Go to **Settings → Pages**.
3. Under **Build and deployment**, set **Source** to **GitHub Actions**.
4. Push to `main` — the workflow deploys the `docs/` folder automatically.

### 2. Deploy the signaling server

GitHub Pages serves static files only. WebRTC pairing and signaling need a small Node.js server.

**Option A — [Render](https://render.com) (free tier)**

1. Create a new **Web Service** connected to this repo.
2. Set **Root Directory** to `server`.
3. Build command: `npm install`
4. Start command: `npm start`
5. Copy your service URL (e.g. `https://meta-display-view-caster.onrender.com`).

**Option B — Local development**

```bash
cd server
npm install
npm run dev
```

Server runs at `http://localhost:8080`. For local testing, use a tunnel like [ngrok](https://ngrok.com) and set the `wss://` URL in config.

### 3. Configure the signaling URL

Edit [`docs/config.js`](docs/config.js) and set `SIGNALING_URL` to your deployed server:

```js
window.CASTER_CONFIG = {
  SIGNALING_URL: 'wss://your-server.onrender.com',
  // ...
};
```

Commit and push — GitHub Pages will redeploy.

### 4. Add the glasses web app

1. Enable **Developer Mode** in the Meta AI app (tap the app version in Settings).
2. Go to **Display Glasses → App connections → Web apps → Add a web app**.
3. Enter: `https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

## Meta Display camera note

Meta Ray-Ban Display [Web Apps do not yet support camera access](https://wearables.developer.meta.com/docs/develop/webapps/build). The pairing UI runs on the glasses; live camera streaming requires the [Device Access Toolkit](https://wearables.developer.meta.com/docs/develop/dat/build-overview/) in a companion mobile app.

This project implements the full pairing + WebRTC pipeline. When camera APIs become available on Display Web Apps (or via a DAT mobile bridge), the stream path is already wired up.

For development, open `glasses.html` in a phone browser to test camera streaming end-to-end.

## Project structure

```
docs/                 GitHub Pages site (desktop + glasses UI)
server/               WebSocket signaling + pairing server
.github/workflows/    GitHub Pages deployment
```

## License

MIT
