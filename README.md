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

### 2. Install on iPhone (pick one)

**Profile (no PC):** On your iPhone, open  
[flsourcing.github.io/Meta-Display-View-Caster/install.html](https://flsourcing.github.io/Meta-Display-View-Caster/install.html)  
→ tap **Install View Caster Profile** → Settings → Install → open home screen icon.

**Native app (best camera):** [GitHub Releases](https://github.com/flsourcing/Meta-Display-View-Caster/releases) → download IPA → sideload with [Sideloadly](https://sideloadly.io).

### 3. Desktop

Open [GitHub Pages viewer](https://flsourcing.github.io/Meta-Display-View-Caster/), enter the code, **Connect**.

### 4. Glasses

In Meta AI → Web apps, add:

`https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

Enter the same code, tap **Go**, then **Live Stream**.

## URLs

| Device | URL / app |
|--------|-----------|
| Phone | [install.html](https://flsourcing.github.io/Meta-Display-View-Caster/install.html) (profile) or native IPA |
| Desktop | [index.html](https://flsourcing.github.io/Meta-Display-View-Caster/) |
| Glasses | [glasses.html](https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html) |

Legacy Safari relay (`relay.html` + PeerJS) still exists but is not recommended.

## Build IPA locally (Mac + Xcode)

The `ios/` folder is a direct fork of Bypass Market Checker Main — the app that already works with Meta AI on your phone.

```bash
cd ios
open "Bypass Market Checker.xcodeproj"
```

Archive and export, or use the GitHub Action for an unsigned IPA on each push to `main`.

## License

MIT
