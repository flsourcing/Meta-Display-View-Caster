# Meta Display View Caster

Everything runs on **GitHub Pages** — no Render, no external server.

## URLs

| Step | Page | Device |
|------|------|--------|
| 1 | [relay.html](https://flsourcing.github.io/Meta-Display-View-Caster/relay.html) | **Phone** — start here, get code |
| 2 | [index.html](https://flsourcing.github.io/Meta-Display-View-Caster/) | **Desktop** — enter code, connect |
| 3 | [glasses.html](https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html) | **Meta glasses** — enter same code, tap Live Stream |
| 4 | [capture.html](https://flsourcing.github.io/Meta-Display-View-Caster/capture.html) | **Phone** — camera (auto-opens from relay) |

## How to use

1. **Phone** — open `relay.html`, wait for **Ready — enter this code on desktop**
2. **Desktop** — open the viewer, type the code, click **Connect**
3. **Glasses** — open `glasses.html`, enter the same code with the digit pad, tap **Go**
4. **Phone** — open the `capture.html` link shown on relay, allow camera
5. **Glasses** — tap **Live Stream**

Pairing uses [PeerJS](https://peerjs.com) in the browser (free public cloud). Your phone hosts the session because Meta Display can't reliably register on its own.

## Add to Meta Display

Meta AI app → Display Glasses → Web apps → Add:
`https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html`

## License

MIT
