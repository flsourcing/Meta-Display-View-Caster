# Meta Display View Caster

Cast the live view from your Meta Display glasses to a desktop browser. Everything runs from **GitHub Pages** — no backend server to deploy.

## Live site

| Page | URL | Device |
|------|-----|--------|
| Desktop viewer | https://flsourcing.github.io/Meta-Display-View-Caster/ | Computer |
| Glasses app | https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html | Meta Display glasses |
| Phone camera | https://flsourcing.github.io/Meta-Display-View-Caster/capture.html | iPhone / Android |

## How it works

1. **Glasses** — Open `glasses.html`. A 6-digit code appears and refreshes every 60 seconds.
2. **Desktop** — Open the viewer, enter the code, click **Connect**. Both show **Connected**.
3. **Phone** — Open `capture.html` on your phone and enter the **same code**. Keep the page open.
4. **Glasses** — Tap **Live Stream** at the bottom. The phone camera streams to the desktop viewer.

Pairing and streaming use [PeerJS](https://peerjs.com) in the browser — all client-side on GitHub Pages.

## Why a phone is needed for camera

Meta Ray-Ban Display [Web Apps do not support camera access](https://wearables.developer.meta.com/docs/develop/webapps/build). The glasses app handles pairing and the Live Stream button; your phone provides the camera via `capture.html`.

For true glasses-camera streaming (no phone), you would need the [Device Access Toolkit](https://wearables.developer.meta.com/docs/develop/dat/build-overview/) in a native mobile app.

## Add to Meta Display glasses

1. Enable **Developer Mode** in the Meta AI app (tap the app version in Settings).
2. Go to **Display Glasses → App connections → Web apps → Add a web app**.
3. Enter: `https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

## Development

Push to `main` and GitHub Actions deploys the `docs/` folder automatically.

## License

MIT
