# iOS — Meta Display View Caster

Fork of Bypass Market Checker with Meta glasses connection + live view casting to desktop.

## Build

GitHub Actions builds `Bypass Market Checker.xcodeproj` and publishes an unsigned IPA on push to `main` under `ios/`.

## Sideload

1. Download the latest **Meta Display View Caster iOS** release IPA.
2. In Sideloadly, leave **Custom Bundle ID** empty.
3. Bundle ID must stay `com.flsourcing.bypassmarketchecker` for Meta registration.

## Flow

1. Complete Meta setup (Register + Allow Camera)
2. Pairing code appears on phone — enter on [desktop viewer](https://flsourcing.github.io/Meta-Display-View-Caster/) and [glasses page](https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html)
3. Tap **Live Stream** on glasses → POV casts to desktop
