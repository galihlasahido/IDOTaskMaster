import Darwin
import Foundation
import Security

/// One process's code-signing status — PLAN.md §3's own
/// "SigningInfoProvider.swift # per-process code-signing status (SecCode
/// APIs)" and §4 M10's "code-signing status (signed/notarized/unsigned,
/// team ID) shown in process detail". Built by `SigningInfoProvider`, never
/// guessed: a field is only ever populated from a value the `SecCode`/
/// `SecStaticCode` APIs actually returned.
struct SigningInfo: Sendable, Equatable {
    let pid: pid_t

    /// The headline verdict PLAN.md's own "signed/notarized/unsigned"
    /// phrasing calls for. `isAdHoc`/`isNotarized`/`teamIdentifier` below
    /// only carry meaningful values when this is `.signed` or `.invalid` —
    /// a real signature was found to classify, even if (for `.invalid`) it
    /// failed verification.
    enum Status: Sendable, Equatable {
        /// A signature was found and verified successfully.
        case signed
        /// The Security framework explicitly reports this code as
        /// carrying no signature at all (`errSecCSUnsigned`) — a real,
        /// honest "Unsigned" answer, not a read failure.
        case unsigned
        /// A signature is present but failed verification — the code on
        /// disk was modified after signing, a sealed resource is missing,
        /// or the signing certificate has expired/been revoked.
        case invalid
        /// This process's signing status couldn't be determined at all:
        /// it exited before it could be inspected, its code object
        /// belongs to another user, or it's a kernel-owned pseudo-process
        /// with no on-disk code to look up. `unavailableReason` carries
        /// the specifics.
        case unavailable

        /// "Signed" / "Unsigned" / "Invalid Signature" / "Unavailable" —
        /// `SigningInfo.statusLabel` folds in ad-hoc-ness on top of this.
        var displayLabel: String {
            switch self {
            case .signed: return "Signed"
            case .unsigned: return "Unsigned"
            case .invalid: return "Invalid Signature"
            case .unavailable: return "Unavailable"
            }
        }
    }

    let status: Status

    /// Whether the signature found (`status == .signed`/`.invalid`) is
    /// ad-hoc — `kSecCodeSignatureAdhoc` in `kSecCodeInfoFlags`, meaning
    /// the code carries a signature only to satisfy the kernel's own
    /// signing requirement, with no certificate or signing identity behind
    /// it (the default for a plain `swiftc`/`clang`-built binary, or any
    /// app built and run without a Developer ID). `nil` when `status` is
    /// `.unsigned`/`.unavailable` — there's no signature to classify.
    let isAdHoc: Bool?

    /// Whether a notarization ticket is stapled into the code object — the
    /// same fact `codesign -dvvv` reports as "Notarization Ticket=stapled".
    /// There is no public API for Gatekeeper's own richer "was this
    /// notarized" verdict (the `spctl -a -vv`-style "source=Notarized
    /// Developer ID" line comes from the private `SecAssessment` API,
    /// unavailable to third-party code); a stapled ticket is the honest,
    /// documented, on-disk signal this app can read instead. `nil` when
    /// notarization isn't a meaningful question for this code: ad-hoc
    /// signatures can never carry a notarization ticket (notarization
    /// requires a Developer ID signing identity), and neither can
    /// `.unsigned`/`.unavailable` code — those read `nil`, not a guessed
    /// `false`.
    let isNotarized: Bool?

    /// The developer team identifier sealed into the signature
    /// (`kSecCodeInfoTeamIdentifier`). Legitimately absent — not a read
    /// failure — for ad-hoc signatures and for Apple's own platform
    /// binaries (Finder, launchd, ...), which carry no team ID at all.
    let teamIdentifier: String?

    /// The signing identifier sealed into the signature
    /// (`kSecCodeInfoIdentifier`) — usually the bundle identifier, e.g.
    /// "com.apple.finder" or "com.google.Chrome".
    let signingIdentifier: String?

    /// Set when `status` is `.invalid` (why verification failed) or
    /// `.unavailable` (why the code couldn't be looked up at all) — `nil`
    /// for `.signed`/`.unsigned`, which need no explanation.
    let unavailableReason: String?

    /// "Signed" / "Signed (Ad-hoc)" / "Unsigned" / "Invalid Signature" /
    /// "Unavailable" — the single string `ProcessesPage`'s detail pane
    /// shows for this reading's "Status" field.
    var statusLabel: String {
        guard status == .signed, isAdHoc == true else { return status.displayLabel }
        return "Signed (Ad-hoc)"
    }
}

/// Reads one process's code-signing status directly from the `SecCode`/
/// `SecStaticCode` APIs in Security.framework — PLAN.md §3's own
/// "SigningInfoProvider.swift # per-process code-signing status (SecCode
/// APIs)". The same framework/syscall-first approach every other provider
/// in this app takes: no shelling out to `codesign`(1)/`spctl`(1) (whose
/// richer Gatekeeper "notarized" verdict isn't reachable this way anyway —
/// see `SigningInfo.isNotarized`'s own doc comment for why this provider
/// reads a stapled-ticket signal off the code object instead).
///
/// Not a `Provider` conformer — like `OpenFilesProvider`/`DiskSpaceScanner`
/// (see those types' own doc comments), this domain's whole shape is "give
/// me one pid's signing status," not `Provider.sample()`'s no-argument
/// shape, and it isn't sampled from inside `Sampler`'s 2×/sec tick:
/// `SecStaticCodeCheckValidityWithErrors` below hashes and verifies every
/// sealed resource in the code's bundle, which for a large app can take
/// real wall-clock time — far too heavy to repeat every tick for every
/// process, whether its detail pane is open or not (PLAN.md §2's "lowest
/// idle overhead"). `ProcessesPage` fetches this once per selected pid
/// (via its own `SigningInfoViewModel`), not on a poll loop — a running
/// process's code identity doesn't change out from under it the way its
/// CPU/memory/open-files readings do.
///
/// An `actor` for the same reason `OpenFilesProvider`/`ConnectionsProvider`
/// are ones: none of the `SecCode*` calls below are async, and this type's
/// own executor shouldn't block the caller while they run.
actor SigningInfoProvider {
    /// Not read anywhere yet — kept for the same forward-looking reason
    /// `OpenFilesProvider.providerID` is (see that type's own doc comment).
    static let providerID = "signingInfo"

    /// One snapshot of `pid`'s code-signing status. Never throws: a
    /// failure to identify or verify the code becomes `SigningInfo.status
    /// == .unavailable`/`.invalid` with `unavailableReason` set — the same
    /// "always return a value, degrade the value" shape `ProcessReading`'s
    /// own optional fields already use — so a caller (`SigningInfoViewModel`)
    /// never needs a per-pid `catch`.
    func signingInfo(forPID pid: pid_t) async -> SigningInfo {
        await Self.read(pid: pid)
    }

    // MARK: - Read

    /// Hops to a background queue for the same reason `OpenFilesProvider
    /// .scan()`/`ConnectionsProvider.scan()`'s doc comments give: none of
    /// the `SecCode*` calls below have an async variant, and
    /// `SecStaticCodeCheckValidityWithErrors` in particular can block for
    /// real time verifying a large bundle.
    private static func read(pid: pid_t) async -> SigningInfo {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readSynchronously(pid: pid))
            }
        }
    }

    /// Must only ever run on the background queue `read(pid:)` dispatches
    /// onto.
    private static func readSynchronously(pid: pid_t) -> SigningInfo {
        guard let staticCode = copyStaticCode(pid: pid) else {
            return SigningInfo(
                pid: pid,
                status: .unavailable,
                isAdHoc: nil,
                isNotarized: nil,
                teamIdentifier: nil,
                signingIdentifier: nil,
                unavailableReason: "This process's code-signing status couldn\u{2019}t be read \u{2014} it may have exited, belong to another user, or have no on-disk code object."
            )
        }

        // `nil` errors pointer: this reading only needs the pass/fail
        // status code, not a `CFError`'s full diagnostic chain.
        let validityStatus = SecStaticCodeCheckValidityWithErrors(staticCode, SecCSFlags(rawValue: 0), nil, nil)

        guard validityStatus != errSecCSUnsigned else {
            // A real, honest "Unsigned" — not a read failure — so none of
            // the signature-detail fields below apply.
            return SigningInfo(pid: pid, status: .unsigned, isAdHoc: nil, isNotarized: nil, teamIdentifier: nil, signingIdentifier: nil, unavailableReason: nil)
        }

        // `kSecCSSigningInformation` for the certificate/team/identifier
        // fields, `kSecCSContentInformation` for the stapled notarization
        // ticket check below — both are read-only metadata pulls, safe
        // regardless of whether `validityStatus` above indicated a valid
        // or broken signature (a tampered binary is still worth reporting
        // *whose* signature it carries).
        var infoRef: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSContentInformation)
        let infoStatus = SecCodeCopySigningInformation(staticCode, infoFlags, &infoRef)
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            return SigningInfo(
                pid: pid,
                status: .invalid,
                isAdHoc: nil,
                isNotarized: nil,
                teamIdentifier: nil,
                signingIdentifier: nil,
                unavailableReason: errorMessage(for: infoStatus)
            )
        }

        let signatureFlags = SecCodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        let isAdHoc = signatureFlags.contains(.adhoc)
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String

        // See `SigningInfo.isNotarized`'s own doc comment for why "a
        // stapled ticket is present" is this provider's notarization
        // signal, and why ad-hoc code reads `nil` rather than a guessed
        // `false` here.
        let isNotarized: Bool? = isAdHoc ? nil : (info[kSecCodeInfoStapledNotarizationTicket as String] != nil)

        let status: SigningInfo.Status = validityStatus == errSecSuccess ? .signed : .invalid
        let reason = validityStatus == errSecSuccess ? nil : errorMessage(for: validityStatus)

        return SigningInfo(
            pid: pid,
            status: status,
            isAdHoc: isAdHoc,
            isNotarized: isNotarized,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            unavailableReason: reason
        )
    }

    // MARK: - SecCode lookup

    /// `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid], ...)`
    /// — the SecCode API's own way to identify a *running* process's code
    /// object (as opposed to `SecStaticCodeCreateWithPath`'s on-disk-only
    /// lookup by file path), so this checks the code actually executing
    /// under `pid` right now rather than merely whatever currently sits at
    /// its executable's path. `nil` when `pid` has already exited, belongs
    /// to another user, or the kernel has no guest for it (a kernel-owned
    /// pseudo-process with no code object at all).
    private static func copyStaticCode(pid: pid_t) -> SecStaticCode? {
        var codeRef: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let codeStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &codeRef)
        guard codeStatus == errSecSuccess, let codeRef else { return nil }

        var staticCodeRef: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(codeRef, SecCSFlags(rawValue: 0), &staticCodeRef)
        guard staticStatus == errSecSuccess else { return nil }
        return staticCodeRef
    }

    /// The Security framework's own human-readable text for an `OSStatus`
    /// code-signing error (e.g. "a sealed resource is missing or invalid"
    /// for `errSecCSBadResource`) — preferred over hand-mapping every
    /// `errSecCS*` constant from `CSCommon.h` by hand, falling back to the
    /// raw status code on the rare system that doesn't have a string for
    /// it.
    private static func errorMessage(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Code signature could not be read (status \(status))."
    }
}
