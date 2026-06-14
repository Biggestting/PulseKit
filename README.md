# PulseKit

A tiny StoreKit 2 transaction relay. Add it to your app, configure it once with
the key from your dashboard app, and each purchase's **Apple-signed** transaction
is forwarded to your dashboard's backend (which verifies the signature) for a
real-time notification.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and add:

```
https://github.com/Biggestting/PulseKit.git
```

## Use

Grab your key from your dashboard app, then call once at launch:

```swift
import PulseKit

PulseKit.configure(key: "YOUR_KEY")
```

That's it.

- ✅ Reports new purchases, renewals, and refunds (Apple-signed, server-verified).
- ✅ Idempotent — replays do nothing.
- 🚫 Never calls `Transaction.finish()` — it only observes.
- 🚫 No user data, no analytics, no identifiers. Purchase events only.

Requires iOS 15 / macOS 12 / tvOS 15 / watchOS 8 (StoreKit 2).
