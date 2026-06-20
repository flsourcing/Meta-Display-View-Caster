# Meta Display View Caster

Cast the live view from your Meta Display glasses to a desktop browser.

## Live site

| Page | URL | Device |
|------|-----|--------|
| Desktop viewer | https://flsourcing.github.io/Meta-Display-View-Caster/ | Computer |
| Glasses app | https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html | Meta Display glasses |
| Phone camera | https://flsourcing.github.io/Meta-Display-View-Caster/capture.html | iPhone / Android |

## One-time setup: deploy the signaling server

GitHub Pages serves the UI only. Pairing requires a small WebSocket server (free on Render):

1. Go to [render.com](https://render.com) and sign in with GitHub.
2. Click **New → Blueprint** and connect repo `flsourcing/Meta-Display-View-Caster`.
3. Render reads `render.yaml` and deploys the server automatically.
4. Copy your service URL (e.g. `https://meta-display-view-caster.onrender.com`).
5. Edit `docs/config.js` — set `SIGNALING_URL` to `wss://your-service.onrender.com` and push.

The config already points to `wss://meta-display-view-caster.onrender.com` — if you name your Render service that, it works out of the box.

> **Note:** Render free tier sleeps after inactivity. The app wakes it automatically — wait ~30 seconds on first connect.

## How to use

1. **Glasses** — open `glasses.html`, wait for **"Ready — enter this code on desktop"**
2. **Desktop** — open the viewer, enter the code, click **Connect**
3. **Phone** — open `capture.html?code=XXXXXX` (same code), tap **Join session**
4. **Glasses** — tap **Live Stream**

## Meta Display camera note

[Glasses web apps cannot access the camera](https://wearables.developer.meta.com/docs/develop/webapps/build). Use `capture.html` on your phone for the video feed.

## License

MIT
