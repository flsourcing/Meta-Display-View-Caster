# Meta Display View Caster

Cast the live view from your Meta Display glasses to a desktop browser. Everything runs from **GitHub Pages** — no backend server to deploy.

## Live site

| Page | URL | Device |
|------|-----|--------|
| Desktop viewer | https://flsourcing.github.io/Meta-Display-View-Caster/ | Computer |
| Glasses app | https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html | Meta Display glasses |

## How it works

1. **Glasses** — Open `glasses.html` on your Meta Display. A 6-digit code appears and refreshes every 60 seconds.
2. **Desktop** — Open the site above, enter the code, click **Connect**.
3. **Both devices** show **Connected**.
4. **Desktop** — Click **Live Stream** to receive the camera feed via WebRTC.

Pairing and streaming use [PeerJS](https://peerjs.com) in the browser — all client-side, hosted entirely on GitHub Pages.

## Add to Meta Display glasses

1. Enable **Developer Mode** in the Meta AI app (tap the app version in Settings).
2. Go to **Display Glasses → App connections → Web apps → Add a web app**.
3. Enter: `https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

## Meta Display camera note

Meta Ray-Ban Display [Web Apps do not yet support camera access](https://wearables.developer.meta.com/docs/develop/webapps/build). The pairing UI runs on the glasses today; live camera streaming requires the [Device Access Toolkit](https://wearables.developer.meta.com/docs/develop/dat/build-overview/) in a companion mobile app.

For end-to-end testing now, open `glasses.html` on a phone browser — pairing and streaming work immediately.

## Development

Push to `main` and GitHub Actions deploys the `docs/` folder automatically.

```bash
# Optional: serve locally
npx serve docs
```

## Project structure

```
docs/                 GitHub Pages site (desktop + glasses UI)
.github/workflows/    GitHub Pages deployment
```

## License

MIT
