import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// PulseKit — a tiny StoreKit 2 transaction relay. Configure it once with the
/// key from your analytics dashboard and it forwards each purchase's
/// Apple-signed transaction to your dashboard's backend (which verifies the
/// signature) for a real-time notification.
///
///     import PulseKit
///     PulseKit.configure(key: "YOUR_KEY")   // from your dashboard app
///
/// It only observes transactions — it never finishes them and collects no user
/// data. Purchase events only.
///
/// ## Subscription status (on by default, no identifier)
///
/// `Transaction.updates` carries money events (purchase / renewal / refund) but
/// is blind to lifecycle state — a user turning auto-renew off, entering a
/// billing-retry or grace period, or a plan expiring. So once a day PulseKit also
/// snapshots `Product.SubscriptionInfo.status(for:)` and forwards the resulting
/// **Apple-signed** transaction + renewalInfo to your dashboard, which verifies
/// the signatures and derives the state. This carries no device or user
/// identifier — it is your own subscription data — so it runs by default and
/// needs no extra privacy declaration.
///
/// ## Optional: app-open tracking
///
/// Apple exposes no real-time app-launch signal (App Analytics' session data is
/// a privacy-thresholded daily report), so daily-active counts can only come
/// from the app itself. That's **off by default** — turn it on explicitly:
///
///     PulseKit.configure(key: "YOUR_KEY", trackAppOpens: true)
///
/// When enabled, PulseKit sends **one ping per install per day** carrying a
/// random `installId` it generates and stores locally (see `installID`), plus
/// the app/OS version. It is NOT the IDFA or IDFV, is not tied to any Apple or
/// app account, and resets if the user deletes the app. There is no behavioural
/// event stream — just "this install opened today".
///
/// > Important: enabling this means your app collects usage data. Declare it in
/// > your App Store privacy label (typically *Usage Data → Product Interaction*,
/// > not linked to identity, not used for tracking) and your privacy policy.
/// > PulseKit deliberately can't turn this on for you.
public enum PulseKit {
    private static let ingestURL = URL(string: "https://yxywnwyjkxdmjlvsfqav.supabase.co/functions/v1/sdk-ingest")!
    private static let openURL = URL(string: "https://yxywnwyjkxdmjlvsfqav.supabase.co/functions/v1/sdk-open")!
    private static let statusURL = URL(string: "https://yxywnwyjkxdmjlvsfqav.supabase.co/functions/v1/sdk-status")!
    // Publishable backend key — safe to ship in a client.
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl4eXdud3lqa3hkbWpsdnNmcWF2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU1MDUxODMsImV4cCI6MjA5MTA4MTE4M30.ZBjc2wBkNGrzKajNsQovCCkScYhwv5WuDbAhc0KF-68"

    private static let installIDKey = "com.proceeds.pulsekit.installID"
    /// Set once the entitlement backfill has completed a full pass for this install.
    private static let backfillDoneKey = "com.proceeds.pulsekit.entitlementBackfillDone"
    private static let lastOpenDayKey = "com.proceeds.pulsekit.lastOpenDay"
    /// UTC day of the last subscription-status snapshot — throttles it to once a day.
    private static let lastStatusDayKey = "com.proceeds.pulsekit.lastStatusDay"

    private static let lock = NSLock()
    private static var key: String?
    private static var started = false
    private static var trackOpens = false
    private static var openObserver: NSObjectProtocol?
    private static var statusObserver: NSObjectProtocol?

    /// Configure with your key and begin reporting purchases. Safe to call once
    /// at app launch.
    ///
    /// - Parameters:
    ///   - key: your key from the dashboard app.
    ///   - trackAppOpens: opt in to one-ping-per-day app-open reporting. Off by
    ///     default; see the type documentation for what it sends and the privacy
    ///     label you must declare before enabling it.
    public static func configure(key: String, trackAppOpens: Bool = false) {
        lock.lock()
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trackOpens = trackAppOpens
        let shouldStart = !started
        started = true
        lock.unlock()
        guard shouldStart else { return }
        listenForTransactions()
        startStatusTracking()
        if trackAppOpens {
            startOpenTracking()
            backfillExistingEntitlementsOnce()
        }
    }

    /// The random, locally-generated id for this install — created on first use
    /// and persisted in `UserDefaults`. Not the IDFA/IDFV, tied to no account,
    /// and gone when the app is deleted. Exposed so you can show or clear it if
    /// your privacy flow needs to.
    public static var installID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installIDKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: installIDKey)
        return fresh
    }

    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private static func listenForTransactions() {
        Task.detached(priority: .background) {
            // New purchases, renewals, and refunds arrive here. We only READ the
            // signed representation off the VerificationResult (the server
            // verifies it) — we never call finish(); that stays the host app's
            // responsibility.
            for await update in Transaction.updates {
                await report(update.jwsRepresentation)
            }
        }
    }

    private static func currentKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }
    private static func opensEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trackOpens
    }

    /// Attach this install to purchases the buyer made BEFORE the host app shipped
    /// PulseKit.
    ///
    /// `Transaction.updates` only ever fires for transactions that change after the
    /// listener attaches — it does not replay a purchase that was already finished.
    /// Without this, every pre-existing customer stayed permanently unjoinable: the
    /// purchase row had no install_id, so the buyer's usage history could never be
    /// shown. Replaying `currentEntitlements` once fills that gap.
    ///
    /// Sent with `backfillOnly`, which the server honours as an UPDATE that can only
    /// ever attach an install id to a row that already exists — it cannot insert a
    /// purchase and cannot fire a push. Both matter: these transactions are usually
    /// already in the ledger via Apple's webhook, so inserting would double-count
    /// revenue, and pushing would cha-ching a months-old sale on every fresh install.
    ///
    /// Runs once per install. Guarded by a `UserDefaults` flag rather than repeating
    /// each launch, since after the first successful pass every row it can reach is
    /// already stamped and further passes are pure wasted requests.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private static func backfillExistingEntitlementsOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: backfillDoneKey) else { return }
        Task.detached(priority: .background) {
            var allDelivered = true
            for await entitlement in Transaction.currentEntitlements {
                let ok = await report(entitlement.jwsRepresentation, backfillOnly: true)
                if !ok { allDelivered = false }
            }
            // Only mark done when every entitlement actually reached the server. A
            // launch with no network would otherwise burn the single attempt and
            // leave that buyer unjoinable forever; an app killed mid-walk likewise
            // retries next launch.
            if allDelivered { defaults.set(true, forKey: backfillDoneKey) }
        }
    }

    /// Returns whether the server accepted the report. The live path ignores this —
    /// a dropped purchase is re-delivered by `Transaction.updates` — but the
    /// entitlement backfill needs it, since that pass runs exactly once and must not
    /// mark itself done after a failed round trip.
    @discardableResult
    private static func report(_ signedTransaction: String, backfillOnly: Bool = false) async -> Bool {
        guard let key = currentKey(), !key.isEmpty else { return false }
        var payload: [String: Any] = ["key": key, "signedTransaction": signedTransaction]
        if backfillOnly { payload["backfillOnly"] = true }
        // Only correlate a purchase to its install when the host app opted into
        // open tracking — otherwise no install id exists to send.
        if opensEnabled() { payload["installId"] = installID }
        var req = URLRequest(url: ingestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        // 401 (bad signature) and 400 are permanent for this transaction — treat them
        // as handled so a single unverifiable entitlement can't wedge the backfill
        // into retrying forever. Only transport failures and 5xx count as "try again".
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    // MARK: - Subscription status (on by default, no identifier)

    /// Snapshot the buyer's live subscription LIFECYCLE and forward the SIGNED
    /// state to the dashboard. `Transaction.updates` only carries money events
    /// (purchase / renewal / refund) — it is blind to a user turning auto-renew
    /// OFF, entering a billing-retry / grace period, or a plan expiring, because
    /// none of those are transactions. `Product.SubscriptionInfo.status(for:)`
    /// IS that state, so a once-a-day snapshot lets the dashboard show
    /// active / cancelled / grace / billing-retry / expired without the developer
    /// wiring up App Store Server Notifications.
    ///
    /// Carries NO identifier: only Apple-signed subscription artifacts (the
    /// server verifies the signatures and derives the state from them). There is
    /// nothing device- or user-identifying to declare — it is the developer's own
    /// subscription data, so this runs by default alongside the purchase relay.
    private static func startStatusTracking() {
        reportSubscriptionStatusesIfNeeded()   // this launch
        #if canImport(UIKit) && !os(watchOS)
        // Re-snapshot on a return from background: a cancellation or expiry can
        // happen while the app is suspended, and the daily throttle makes this cheap.
        statusObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in reportSubscriptionStatusesIfNeeded() }
        #endif
    }

    /// Fires at most ONCE per calendar day (UTC) per install — a lifecycle state
    /// is slow-moving, so a daily snapshot is plenty and keeps requests minimal.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private static func reportSubscriptionStatusesIfNeeded() {
        guard let key = currentKey(), !key.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = cal.startOfDay(for: Date()).timeIntervalSince1970
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: lastStatusDayKey) != today else { return }
        defaults.set(today, forKey: lastStatusDayKey)

        Task.detached(priority: .background) {
            // Gather the subscription groups the buyer currently owns something in,
            // then read each group's live status. currentEntitlements is the only
            // way to discover the group ids without hard-coding product ids.
            var groupIDs = Set<String>()
            for await entitlement in Transaction.currentEntitlements {
                guard case .verified(let t) = entitlement else { continue }
                if let gid = t.subscriptionGroupID { groupIDs.insert(gid) }
            }
            guard !groupIDs.isEmpty else { return }

            var allDelivered = true
            for gid in groupIDs {
                guard let statuses = try? await Product.SubscriptionInfo.status(for: gid) else {
                    allDelivered = false; continue
                }
                for st in statuses {
                    // Send the signed reps verbatim (verified or not — the server
                    // verifies). renewalInfo carries auto-renew / grace / retry;
                    // the transaction carries expiry + revocation.
                    let ok = await postStatus(
                        key: key,
                        signedTransaction: st.transaction.jwsRepresentation,
                        signedRenewalInfo: st.renewalInfo.jwsRepresentation)
                    if !ok { allDelivered = false }
                }
            }
            // A failed round trip rolls the marker back so the next foreground retries,
            // rather than burning the day's single snapshot on a network blip.
            if !allDelivered { UserDefaults.standard.removeObject(forKey: lastStatusDayKey) }
        }
    }

    private static func postStatus(key: String, signedTransaction: String, signedRenewalInfo: String) async -> Bool {
        let payload: [String: Any] = [
            "key": key,
            "signedTransaction": signedTransaction,
            "signedRenewalInfo": signedRenewalInfo,
        ]
        var req = URLRequest(url: statusURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        guard let http = response as? HTTPURLResponse else { return false }
        // 5xx = try again; 4xx (bad/absent sub) is permanent for this snapshot.
        return http.statusCode < 500
    }

    // MARK: - App opens (opt-in)

    private static func startOpenTracking() {
        reportOpenIfNeeded()   // this launch
        #if canImport(UIKit) && !os(watchOS)
        // Also count a return from background — a day can start while the app is
        // suspended, and that user IS active today.
        openObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in reportOpenIfNeeded() }
        #endif
    }

    /// Fires at most ONCE per calendar day (UTC) per install — the client-side
    /// half of the dedupe; the server enforces the same uniqueness. Keeps this a
    /// daily-active signal rather than a behavioural log, and means backgrounding
    /// in and out all day costs one request.
    private static func reportOpenIfNeeded() {
        guard opensEnabled(), let key = currentKey(), !key.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = cal.startOfDay(for: Date()).timeIntervalSince1970
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: lastOpenDayKey) != today else { return }
        defaults.set(today, forKey: lastOpenDayKey)

        var payload: [String: Any] = ["key": key, "installId": installID]
        if let bundleID = Bundle.main.bundleIdentifier { payload["bundleId"] = bundleID }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { payload["appVersion"] = v }
        payload["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString

        Task.detached(priority: .background) {
            var req = URLRequest(url: openURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            // Best-effort: a failed ping just means today's open goes uncounted.
            // Roll the marker back so the next foreground retries it.
            if (try? await URLSession.shared.data(for: req)) == nil {
                UserDefaults.standard.removeObject(forKey: lastOpenDayKey)
            }
        }
    }
}
