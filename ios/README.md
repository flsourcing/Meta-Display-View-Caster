# iOS — Bypass Market Checker fork

This folder is a **direct fork** of [Bypass Market Checker Main](https://github.com/flsourcing/Bypass-Market-Checker-Main) — the app that already works with Meta AI registration on your phone.

## Build

GitHub Actions builds `Bypass Market Checker.xcodeproj` and publishes an unsigned IPA on every push to `main` under `ios/`.

## Sideload

1. Download the latest **Bypass Market Checker iOS** release IPA.
2. In Sideloadly, leave **Custom Bundle ID** empty.
3. Sideload — bundle ID must stay `com.flsourcing.bypassmarketchecker`.

## View Caster Relay code

The previous View Caster relay attempt is archived at `_archive/ViewCasterRelay/` for when you re-add casting on top of this working base.
