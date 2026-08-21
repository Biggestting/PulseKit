# PulseKit — rollout procedure

Standing procedure for shipping a new PulseKit feature to the host apps. It is the
SAME shape every time, because everything lives behind `PulseKit.configure(key:)`
and every host app pins the package with an `from:` (up-to-next-major) rule.

## The mental model

- **Edge-function changes** (Supabase: `sdk-ingest`, `sdk-open`, `sdk-status`,
  `appstore-webhook`, `subscribers`, …) reach every app the moment they deploy.
  No app rebuild. Do these server-side whenever possible.
- **Client-code changes** (anything in `Sources/PulseKit/`) are compiled INTO each
  app's binary. They can only reach an app when THAT app rebuilds and ships. There
  is no way to push new client code into an already-shipped binary — this is true
  of every client SDK on every platform.

## Releasing a client change

1. Land + commit the change on `main`, `swift build` clean.
2. Cut a new tag and push it:
   ```bash
   git tag 1.3.0 && git push origin 1.3.0
   ```
   Bump the minor for a feature, the patch for a fix. Stay in the `1.x` line so the
   host apps' `from:` rules pick it up automatically (they cover `1.0.0 ..< 2.0.0`).
   Only a `2.0.0` would require editing every host app's `project.yml`.

## Getting it into a host app (per app, on its NEXT release)

Do this only when you're already shipping that app — don't force-release every app
for one SDK change.

**These apps gitignore `Package.resolved` (and usually the whole `.xcodeproj/`, which
xcodegen regenerates).** So the pin is NOT version-controlled: on a clean checkout +
`xcodegen generate` + archive, SwiftPM resolves the newest tag satisfying `from:`
automatically. For a same-line bump (1.2.0 → 1.3.0) the next clean archive picks it
up with **nothing to commit and no pin to edit**.

1. `cd <app> && xcodegen generate`
2. Archive + ship as normal. No call-site change; `configure(key:)` already does everything.

### The one thing that will bite you: a stale local SwiftPM cache

SwiftPM caches a bare clone of the package. If you tagged the new version AFTER that
cache was populated, a local `-resolvePackageDependencies` / archive can keep
resolving the OLD tag because the cache never fetched the new one. Force it to refetch:

```bash
rm -rf ~/Library/Caches/org.swift.swiftpm/repositories/PulseKit-*
rm -rf ~/Library/Developer/Xcode/DerivedData/<App>-*/SourcePackages
rm -f <App>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -resolvePackageDependencies -project <App>.xcodeproj -scheme <scheme>
```

Confirm the tail prints `PulseKit ... @ 1.3.0`. Clean CI / a fresh machine has no
stale cache and resolves 1.3.0 on the first try.

> If a particular app DOES commit its `Package.resolved` (not the pattern here, but
> possible), then also commit the refreshed file — for that app it IS the pin.

## What must NEVER change (or the Proceeds data source breaks)

The dashboard's data comes from PulseKit POSTing to the Supabase relay, keyed by the
app's account key and matched by bundle id. A host app keeps feeding data as long as:

- `PulseKit.configure(key: "<the app's key>")` still runs at launch — do not remove it.
- The **key string is unchanged** (it's the account key from the Proceeds SDK screen).
- The **bundle id is unchanged** (that's how purchases/opens/status attribute to the app).
- If the app had `trackAppOpens: true`, **keep it** — dropping it stops app-open + journey data.

Bumping the PulseKit version is purely additive: newer tags only ADD relays (e.g.
1.3.0 adds the daily subscription-status snapshot). None remove or rename an
endpoint, so a version bump can't break an existing data source.

## Which apps benefit from which change

- **Subscription-status snapshot (1.3.0):** only apps with auto-renewable
  subscriptions. IAP-only / paid apps find no subscription groups and no-op — no
  reason to cut a build just for this.
- **install_id backfill / journeys:** only apps that call `configure(trackAppOpens: true)`.
- **Purchase & refund relay:** every app with the SDK.

## Current state

- Latest tag: **`1.3.0`** — daily `Product.SubscriptionInfo.status(for:)` snapshot →
  `sdk-status` edge fn → `subscription_state` (client-side lifecycle, no ASC setup).
- All 17 host apps pin `from: 1.x.0`, so 1.3.0 is auto-eligible everywhere; each
  picks it up on its next release via the resolve step above.
