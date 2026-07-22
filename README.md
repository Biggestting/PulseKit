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

Grab your key from your dashboard app, then call once at launch.

**Purchases only** — reports purchase events and nothing else, and creates no
identifier:

```swift
import PulseKit

PulseKit.configure(key: "YOUR_KEY")
```

**Purchases + app opens** — additionally sends one ping per day, so the dashboard
can show active installs and a buyer's journey (how long someone used the app
before paying). This mode **does** create an identifier — read
[Privacy](#privacy) before enabling it:

```swift
PulseKit.configure(key: "YOUR_KEY", trackAppOpens: true)
```

That's it.

- ✅ Reports new purchases, renewals, and refunds (Apple-signed, server-verified).
- ✅ Idempotent — replays do nothing.
- 🚫 Never calls `Transaction.finish()` — it only observes.

Requires iOS 15 / macOS 12 / tvOS 15 / watchOS 8 (StoreKit 2).

## Privacy

**What each mode collects — this is what your App Store privacy label must say.**

### Default (`trackAppOpens` omitted or `false`)

Purchase events only. No identifier is generated or sent, and nothing is stored
on device.

### With `trackAppOpens: true`

PulseKit generates a random `installID` (a `UUID`) on first use and persists it
in `UserDefaults`. It is:

- **not** the IDFA and **not** the IDFV
- tied to no account, email, or name
- scoped to this install — deleting the app destroys it
- readable and clearable via `PulseKit.installID`, if your own privacy flow needs it

That id is sent with each daily open ping **and attached to purchase reports** —
which is precisely what lets the dashboard join a purchase to that install's
history.

Also sent with each ping: your bundle id, your app's version, and the OS version
string.

**The ping fires at most once per calendar day (UTC) per install.** It is a
daily-active signal, not a behavioural log: no session duration, no screen
tracking, no event stream.

You must declare this in your App Store privacy label, typically:

| Data type | Linked to identity | Used for tracking | Purpose |
|---|---|---|---|
| Identifiers → Device ID | No | No | Analytics |
| Usage Data → Product Interaction | No | No | Analytics |

The default mode requires none of the above.

## Security model

The two paths have **different** guarantees — don't generalize one to the other.

- **Purchases are tamper-proof.** PulseKit forwards Apple's signed transaction
  (`jwsRepresentation`) and the server verifies that signature. Your key ships
  inside your app binary and can be extracted, but a leaked key still **cannot**
  fabricate a purchase: an attacker cannot forge Apple's signature.

- **Open pings are NOT signed.** No Apple-signed artifact exists for "the app was
  opened", so the ping is a plain `{key, installId, bundleId, …}` POST. Anyone
  who extracts your key can submit bogus open pings. The blast radius is inflated
  active-install counts on your own dashboard — it cannot create revenue,
  purchases, or subscribers. Weigh that before enabling opens.
