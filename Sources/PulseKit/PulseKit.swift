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
    // Publishable backend key — safe to ship in a client.
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl4eXdud3lqa3hkbWpsdnNmcWF2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU1MDUxODMsImV4cCI6MjA5MTA4MTE4M30.ZBjc2wBkNGrzKajNsQovCCkScYhwv5WuDbAhc0KF-68"

    private static let installIDKey = "com.proceeds.pulsekit.installID"
    private static let lastOpenDayKey = "com.proceeds.pulsekit.lastOpenDay"

    private static let lock = NSLock()
    private static var key: String?
    private static var started = false
    private static var trackOpens = false
    private static var openObserver: NSObjectProtocol?

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
        if trackAppOpens { startOpenTracking() }
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

    private static func report(_ signedTransaction: String) async {
        guard let key = currentKey(), !key.isEmpty else { return }
        var payload: [String: Any] = ["key": key, "signedTransaction": signedTransaction]
        // Only correlate a purchase to its install when the host app opted into
        // open tracking — otherwise no install id exists to send.
        if opensEnabled() { payload["installId"] = installID }
        var req = URLRequest(url: ingestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: req)
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
