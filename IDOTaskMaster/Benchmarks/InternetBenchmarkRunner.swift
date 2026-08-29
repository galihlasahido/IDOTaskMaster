import Darwin
import Foundation
import Network
import SystemConfiguration

/// Real engine behind `.internetSpeed` — PLAN.md §3's `Benchmarks/`
/// "Internet (URLSession)" and §4 M7's second task's "Internet down/up".
/// Downloads, then uploads, a fixed-size payload against Cloudflare's
/// public speed-test endpoints (`speed.cloudflare.com/__down`/`__up` — no
/// account or API key, the same publicly documented HTTP endpoints
/// Cloudflare's own `speed.cloudflare.com` page and a number of open-source
/// speed-test CLIs use) and reports each direction's throughput in Mbps.
///
/// Unlike `CPUBenchmarkRunner`/`GPUBenchmarkRunner`/`DiskBenchmarkRunner`,
/// this runner's work is a plain `async` network request — nothing here
/// blocks a thread, so it runs as a genuine `Task` rather than being pushed
/// onto `DispatchQueue.global`, and cancellation is Swift Concurrency's own
/// `Task.cancel()` (tracked in a `BenchmarkTaskBox`) rather than a
/// `BenchmarkCancellationToken`. `URLSession`'s async APIs are
/// cancellation-aware: cancelling the wrapping `Task` cancels the in-flight
/// `URLSessionTask` too, so — unlike the other three runners, whose cancel
/// only takes effect between chunks/batches — this one can stop mid-request.
///
/// Progress is reported with `fraction: nil` (an indeterminate spinner) for
/// both phases: `BenchmarkProgress.fraction`'s own doc comment names this
/// exact case ("waiting for a server response" during an Internet test) as
/// the one honest use of "no fraction to report" — tracking live
/// bytes-transferred would need a delegate-based `URLSession` instead of
/// the plain `async` request/response calls used here, for a progress bar
/// that wouldn't add anything the final Mbps number doesn't already say.
///
/// ## Pinning to one interface
///
/// `URLSession`/`URLSessionConfiguration` have no public API to force a
/// request over one specific network interface (Wi-Fi vs. a USB-C Ethernet
/// dongle vs. a Thunderbolt Bridge, say) rather than whichever the routing
/// table would otherwise pick — `Network.framework`'s `NWParameters
/// .requiredInterface` is Apple's documented way to do that, but it only
/// applies to an `NWConnection`, not a `URLSession`. So when
/// `context.networkInterfaceName` is set, this runner bypasses `URLSession`
/// entirely for that run and speaks a small hand-rolled HTTP/1.1 exchange
/// itself over an `NWConnection` pinned to that interface (`pinnedRequest`
/// below) — still real HTTPS to the same Cloudflare endpoints, just without
/// `URLSession`'s help. The default, interface-agnostic path (`nil`, by far
/// the common case) is untouched and still goes through `URLSession.shared`
/// exactly as before.
final class InternetBenchmarkRunner: BenchmarkRunner {
    let kind: BenchmarkKind = .internetSpeed
    private let taskBox = BenchmarkTaskBox()

    /// Downloaded/uploaded payload sizes. Large enough that connection
    /// setup and TLS handshake overhead are a small fraction of the total
    /// transfer time (so the measured rate reflects sustained throughput,
    /// not just round-trip latency), small enough that the whole run stays
    /// well under a minute even on a slow connection.
    private static let downloadBytes = 25_000_000 // 25 MB
    private static let uploadBytes = 10_000_000 // 10 MB
    private static let speedTestHost = "speed.cloudflare.com"
    private static let downloadURL = URL(string: "https://\(speedTestHost)/__down?bytes=\(downloadBytes)")!
    private static let uploadURL = URL(string: "https://\(speedTestHost)/__up")!

    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent> {
        let interfaceName = context.networkInterfaceName
        return AsyncStream { continuation in
            let task = Task {
                await Self.performRun(interfaceName: interfaceName, continuation: continuation)
            }
            taskBox.set(task)
            continuation.onTermination = { [taskBox] _ in
                taskBox.current?.cancel()
            }
        }
    }

    /// Mirrors `DiskSpaceScanner.cancelActiveScan()`'s "takes effect
    /// immediately" guarantee: cancelling the underlying `Task` cancels
    /// whichever `URLSessionTask`/`NWConnection` is in flight right away,
    /// rather than waiting for the current chunk/batch to finish the way
    /// the other three runners' token-based cancellation does.
    func cancelActiveRun() {
        taskBox.current?.cancel()
    }

    // MARK: - Interface enumeration (Benchmarks page's picker)

    /// One real, currently-usable network interface — PLAN.md's own
    /// `NetworkSnapshot.interfaces` doc comment names this exact use
    /// ("a future per-interface selector UI"). `displayName` is the same
    /// human name (`"Wi-Fi"`, `"Thunderbolt Ethernet"`, ...) System
    /// Settings and `networksetup -listallhardwareports` show, not a raw
    /// BSD name a user would have no way to recognize.
    struct NetworkInterfaceOption: Sendable, Equatable, Identifiable {
        let id: String
        let displayName: String
    }

    /// Every interface with a real IPv4 address right now — i.e. actually
    /// joined to a network, not merely present in hardware (an unplugged
    /// Ethernet dongle or an idle Thunderbolt Bridge shows up in
    /// `SCNetworkInterfaceCopyAll()` too, but never gets an address, so
    /// picking it would only produce a confusing connection failure).
    /// IPv6-only networks are honestly out of scope here rather than
    /// guessed at: distinguishing a real routable IPv6 address from a
    /// link-local-only one that goes nowhere needs more address parsing
    /// than this picker's job — "which of my *connected* interfaces do you
    /// want" — is worth; an interface in that situation just won't appear,
    /// same as it wouldn't in an IPv4-only picker on any other benchmark
    /// tool.
    static func availableInterfaces() -> [NetworkInterfaceOption] {
        let usableBSDNames = bsdNamesWithIPv4Address()
        guard !usableBSDNames.isEmpty else { return [] }

        var seen = Set<String>()
        var options: [NetworkInterfaceOption] = []
        if let scInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in scInterfaces {
                guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                      usableBSDNames.contains(bsdName), !seen.contains(bsdName) else { continue }
                seen.insert(bsdName)
                let displayName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsdName
                options.append(NetworkInterfaceOption(id: bsdName, displayName: displayName))
            }
        }
        // A usable interface `SCNetworkInterfaceCopyAll()` didn't have an
        // entry for (rare — e.g. a VPN's `utunN`) still gets listed under
        // its raw BSD name rather than silently disappearing.
        for bsdName in usableBSDNames where !seen.contains(bsdName) {
            options.append(NetworkInterfaceOption(id: bsdName, displayName: bsdName))
        }
        return options.sorted { $0.displayName < $1.displayName }
    }

    private static func bsdNamesWithIPv4Address() -> Set<String> {
        var result = Set<String>()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return result }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = pointer {
            defer { pointer = addr.pointee.ifa_next }
            let flags = Int32(addr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            result.insert(String(cString: addr.pointee.ifa_name))
        }
        return result
    }

    // MARK: - Run

    private static func performRun(interfaceName: String?, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) async {
        var interface: NWInterface?
        var interfaceDisplayName: String?
        if let interfaceName {
            guard let resolved = await resolveNWInterface(named: interfaceName) else {
                continuation.yield(.failed("\u{201C}\(interfaceName)\u{201D} isn\u{2019}t connected right now."))
                continuation.finish()
                return
            }
            interface = resolved
            interfaceDisplayName = availableInterfaces().first { $0.id == interfaceName }?.displayName ?? interfaceName
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: nil, phase: "Measuring download speed\u{2026}")))
        let downloadMbps: Double
        switch await measureDownload(interface: interface) {
        case .success(let mbps): downloadMbps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        guard !Task.isCancelled else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: nil, phase: "Measuring upload speed\u{2026}")))
        let uploadMbps: Double
        switch await measureUpload(interface: interface) {
        case .success(let mbps): uploadMbps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        let result = BenchmarkResult(
            id: UUID(),
            kind: .internetSpeed,
            generatedAt: Date(),
            metrics: [
                BenchmarkMetric(label: "Download", value: downloadMbps, unit: "Mbps"),
                BenchmarkMetric(label: "Upload", value: uploadMbps, unit: "Mbps"),
            ],
            detail: interfaceDisplayName
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    /// One direction's measurement outcome — mirrors `DiskBenchmarkRunner
    /// .PhaseOutcome`'s "completed / cancelled / failed" shape, with the
    /// already-computed Mbps figure in the completed case instead of a raw
    /// elapsed time (there's no second value to combine it with here).
    private enum MeasurementOutcome {
        case success(mbps: Double)
        case cancelled
        case failed(String)
    }

    private static func measureDownload(interface: NWInterface?) async -> MeasurementOutcome {
        guard let interface else {
            return await measureDownloadViaURLSession()
        }
        let start = Date()
        do {
            let response = try await pinnedRequest(
                interface: interface,
                requestLine: "GET /__down?bytes=\(downloadBytes) HTTP/1.1",
                extraHeaders: [:],
                body: nil,
                drainResponseBody: true
            )
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0, response.bodyByteCount > 0 else {
                return .failed("The download speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: response.bodyByteCount, elapsed: elapsed))
        } catch {
            return outcome(forPinnedRequest: error)
        }
    }

    private static func measureDownloadViaURLSession() async -> MeasurementOutcome {
        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("The download speed test server didn\u{2019}t respond as expected.")
            }
            guard elapsed > 0, !data.isEmpty else {
                return .failed("The download speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: data.count, elapsed: elapsed))
        } catch {
            return outcome(for: error)
        }
    }

    private static func measureUpload(interface: NWInterface?) async -> MeasurementOutcome {
        var payload = Data(count: uploadBytes)
        let filled = payload.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            arc4random_buf(base, uploadBytes)
            return true
        }
        guard filled else {
            return .failed("Couldn\u{2019}t prepare the upload speed test payload.")
        }

        guard let interface else {
            return await measureUploadViaURLSession(payload: payload)
        }

        let start = Date()
        do {
            _ = try await pinnedRequest(
                interface: interface,
                requestLine: "POST /__up HTTP/1.1",
                extraHeaders: [
                    "Content-Length": "\(uploadBytes)",
                    "Content-Type": "application/octet-stream",
                ],
                body: payload,
                drainResponseBody: false
            )
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0 else {
                return .failed("The upload speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: uploadBytes, elapsed: elapsed))
        } catch {
            return outcome(forPinnedRequest: error)
        }
    }

    private static func measureUploadViaURLSession(payload: Data) async -> MeasurementOutcome {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("The upload speed test server didn\u{2019}t respond as expected.")
            }
            guard elapsed > 0 else {
                return .failed("The upload speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: uploadBytes, elapsed: elapsed))
        } catch {
            return outcome(for: error)
        }
    }

    private static func megabitsPerSecond(bytes: Int, elapsed: TimeInterval) -> Double {
        Double(bytes) * 8 / elapsed / 1_000_000
    }

    /// Distinguishes a deliberate cancel (`CancellationError`, or the
    /// `URLError.cancelled` a cancelled `URLSessionTask` throws) from every
    /// other network failure, which is reported as `.failed` with an
    /// honest reason — never a fabricated Mbps figure, PLAN.md's
    /// "Unavailable instead of a guess" rule.
    private static func outcome(for error: Error) -> MeasurementOutcome {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return .cancelled
            }
            return .failed("No internet connection was available for the speed test (\(urlError.localizedDescription)).")
        }
        return .failed(error.localizedDescription)
    }

    private static func outcome(forPinnedRequest error: Error) -> MeasurementOutcome {
        guard let pinnedError = error as? PinnedRequestError else {
            return .failed(error.localizedDescription)
        }
        switch pinnedError {
        case .cancelled:
            return .cancelled
        case .connectionFailed(let reason), .badResponse(let reason):
            return .failed(reason)
        }
    }

    // MARK: - Interface-pinned HTTP (Network.framework)

    /// Resolves a BSD interface name (e.g. `"en0"`) to the live `NWInterface`
    /// object `NWParameters.requiredInterface` needs — `Network.framework`
    /// has no "look up by name" initializer, only a live path's own
    /// `availableInterfaces` list, so a one-shot `NWPathMonitor` tick is
    /// the documented way to get one. Returns `nil` if that interface isn't
    /// in the current path at all (e.g. it was unplugged between opening
    /// the picker and pressing Run) — `performRun` reports that honestly
    /// rather than silently falling back to a different interface than the
    /// one the user chose.
    /// Single-resume guard for the handler below — a class rather than a
    /// captured `var` + `NSLock` pair so the closure only captures one
    /// `Sendable`-safe reference (a captured mutable local is a Swift 6
    /// concurrency error).
    private final class ResumeOnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        /// Returns `true` exactly once.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didResume { return false }
            didResume = true
            return true
        }
    }

    private static func resolveNWInterface(named name: String) async -> NWInterface? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let resumeFlag = ResumeOnceFlag()
            monitor.pathUpdateHandler = { path in
                guard resumeFlag.claim() else { return }
                let match = path.availableInterfaces.first { $0.name == name }
                monitor.cancel()
                continuation.resume(returning: match)
            }
            monitor.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    private struct PinnedResponse {
        let statusCode: Int
        let bodyByteCount: Int
    }

    private enum PinnedRequestError: Error {
        case connectionFailed(String)
        case badResponse(String)
        case cancelled
    }

    /// A minimal hand-rolled HTTP/1.1-over-TLS exchange against
    /// `speedTestHost`, run over an `NWConnection` pinned to `interface` —
    /// see this type's own doc comment for why `URLSession` can't do the
    /// pinning itself. Sends `requestLine` + `extraHeaders` (+ `body`, for
    /// the upload case), then either drains the full response body and
    /// counts its bytes (`drainResponseBody: true`, the download case) or
    /// just confirms a `2xx` status line arrived (`false`, the upload
    /// case — matching `URLSession.upload`'s own "discard the response
    /// body, only the status/elapsed time matter" behavior). Honors
    /// cancellation immediately via `withTaskCancellationHandler`, the
    /// same "cancel takes effect right away, not just between chunks"
    /// guarantee the `URLSession`-backed path gets from `URLSessionTask`
    /// cancellation.
    private static func pinnedRequest(
        interface: NWInterface,
        requestLine: String,
        extraHeaders: [String: String],
        body: Data?,
        drainResponseBody: Bool
    ) async throws -> PinnedResponse {
        let parameters = NWParameters(tls: .init())
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(speedTestHost), port: 443, using: parameters)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PinnedResponse, Error>) in
                let lock = NSLock()
                var didResume = false
                func resume(_ result: Result<PinnedResponse, Error>) {
                    lock.lock()
                    let alreadyResumed = didResume
                    didResume = true
                    lock.unlock()
                    guard !alreadyResumed else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }

                var headerBuffer = Data()
                var headersParsed = false
                var statusCode = 0
                var contentLength: Int?
                var bodyByteCount = 0

                func finishIfReady() {
                    guard headersParsed else {
                        resume(.failure(PinnedRequestError.badResponse("The server closed the connection before sending a response.")))
                        return
                    }
                    guard (200..<300).contains(statusCode) else {
                        resume(.failure(PinnedRequestError.badResponse("The speed test server responded with status \(statusCode).")))
                        return
                    }
                    resume(.success(PinnedResponse(statusCode: statusCode, bodyByteCount: bodyByteCount)))
                }

                func receiveLoop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let error {
                            resume(.failure(PinnedRequestError.connectionFailed(error.localizedDescription)))
                            return
                        }
                        if let data, !data.isEmpty {
                            if !headersParsed {
                                headerBuffer.append(data)
                                if let range = headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                                    headersParsed = true
                                    let headerText = String(decoding: headerBuffer[..<range.lowerBound], as: UTF8.self)
                                    let lines = headerText.components(separatedBy: "\r\n")
                                    let statusParts = lines.first?.split(separator: " ") ?? []
                                    statusCode = statusParts.count > 1 ? (Int(statusParts[1]) ?? 0) : 0
                                    for line in lines.dropFirst() {
                                        guard let colon = line.firstIndex(of: ":") else { continue }
                                        let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                                        guard key == "content-length" else { continue }
                                        contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                                    }
                                    bodyByteCount += headerBuffer[range.upperBound...].count
                                }
                            } else {
                                bodyByteCount += data.count
                            }
                        }

                        if isComplete {
                            finishIfReady()
                            return
                        }
                        if headersParsed {
                            if !drainResponseBody {
                                // The upload case only needs to know a
                                // valid response arrived, not to wait for
                                // the server to finish streaming its
                                // (small) acknowledgement body and close.
                                finishIfReady()
                                return
                            }
                            if let contentLength, bodyByteCount >= contentLength {
                                finishIfReady()
                                return
                            }
                        }
                        receiveLoop()
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        var headerText = "\(requestLine)\r\nHost: \(speedTestHost)\r\nConnection: close\r\nUser-Agent: IDOTaskMaster-Benchmark\r\nAccept: */*\r\n"
                        for (key, value) in extraHeaders {
                            headerText += "\(key): \(value)\r\n"
                        }
                        headerText += "\r\n"
                        var requestData = Data(headerText.utf8)
                        if let body {
                            requestData.append(body)
                        }
                        connection.send(content: requestData, completion: .contentProcessed { error in
                            if let error {
                                resume(.failure(PinnedRequestError.connectionFailed(error.localizedDescription)))
                                return
                            }
                            receiveLoop()
                        })
                    case .failed(let error):
                        resume(.failure(PinnedRequestError.connectionFailed(error.localizedDescription)))
                    case .cancelled:
                        resume(.failure(PinnedRequestError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
