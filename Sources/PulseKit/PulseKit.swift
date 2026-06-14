import Foundation
import StoreKit

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
public enum PulseKit {
    private static let ingestURL = URL(string: "https://yxywnwyjkxdmjlvsfqav.supabase.co/functions/v1/sdk-ingest")!
    // Publishable backend key — safe to ship in a client.
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl4eXdud3lqa3hkbWpsdnNmcWF2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU1MDUxODMsImV4cCI6MjA5MTA4MTE4M30.ZBjc2wBkNGrzKajNsQovCCkScYhwv5WuDbAhc0KF-68"

    private static let lock = NSLock()
    private static var key: String?
    private static var started = false

    /// Configure with your key and begin reporting purchases. Safe to call once
    /// at app launch.
    public static func configure(key: String) {
        lock.lock()
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldStart = !started
        started = true
        lock.unlock()
        guard shouldStart else { return }
        listenForTransactions()
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

    private static func report(_ signedTransaction: String) async {
        guard let key = currentKey(), !key.isEmpty else { return }
        var req = URLRequest(url: ingestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": key, "signedTransaction": signedTransaction,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}
