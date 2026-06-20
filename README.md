# Meta Display View Caster

Cast from Meta Display glasses to your desktop. **Glasses** stay a web app; **phone** runs a native relay app; **desktop** is the browser viewer.

## Why a native phone app?

Safari `relay.html` on iPhone is unreliable for WebRTC (backgrounding, NAT, PeerJS cloud). A sideloaded iOS app keeps the relay alive, uses the camera properly, and connects through a real WebSocket signaling server.

```
Glasses (web) ──► Phone app (relay + camera) ──► Signaling server ──► Desktop (web)
```

## Quick start

### 1. Deploy the signaling server (one time)

Deploy the `server/` folder to [Render](https://render.com) (free tier):

- Connect this GitHub repo
- Render reads `render.yaml` automatically, or create a **Web Service** with root `server`, build `npm install`, start `npm start`
- Copy your WebSocket URL, e.g. `wss://meta-display-view-caster.onrender.com`

Update `docs/config.js`:

```javascript
SIGNALING_URL: 'wss://YOUR-SERVICE.onrender.com',
```

Push to `main` so GitHub Pages picks up the change.

### 2. Install the phone app (Sideloadly)

1. Go to **Actions** → **Build iOS IPA** → run workflow (or wait for push to `ios/`)
2. Download the **ViewCasterRelay-ipa** artifact
3. Open [Sideloadly](https://sideloadly.io), drag the `.ipa`, sign with your Apple ID, install on iPhone
4. On first launch: allow **Camera** when prompted (needed for Live Stream)
5. Set the signaling server URL in the app if it differs from default
6. Tap **Start relay** — note the 6-digit code

### 3. Desktop

Open [GitHub Pages viewer](https://flsourcing.github.io/Meta-Display-View-Caster/), enter the code, **Connect**.

### 4. Glasses

In Meta AI → Web apps, add:

`https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

Enter the same code, tap **Go**, then **Live Stream**.

## URLs

| Device | URL / app |
|--------|-----------|
| Phone | **View Caster Relay** (sideloaded IPA) |
| Desktop | [index.html](https://flsourcing.github.io/Meta-Display-View-Caster/) |
| Glasses | [glasses.html](https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html) |

Legacy Safari relay (`relay.html` + PeerJS) still exists but is not recommended.

## Build IPA locally (Mac + Xcode)

```bash
cd ios
brew install xcodegen
xcodegen generate
open ViewCasterRelay.xcodeproj
```

Archive and export, or use the GitHub Action above for an unsigned IPA.

## License

MIT
