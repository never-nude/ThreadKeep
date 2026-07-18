import Foundation
import Network

/// Streams the entire library to the ThreadKeep iOS app over local Wi-Fi.
///
/// Advertises a Bonjour service ("_threadkeep._tcp") that the phone browses
/// for, pairs with a per-connection 4-digit code the user reads off the Mac's
/// screen, then sends every archive as length-prefixed frames (see
/// `WiFiSyncFraming` for the wire format, protocol v1).
///
/// The observable server lives on the main actor and only publishes friendly
/// state; all networking runs inside `ThreadKeepWiFiSyncEngine` on a dedicated
/// dispatch queue. Archive contents come from an injected async provider so
/// this type stays UI- and database-agnostic.
@MainActor
final class ThreadKeepWiFiSyncServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case waitingForPhone
        case pairing(deviceName: String, code: String)
        case preparing(done: Int, total: Int)
        case sending(sent: Int, total: Int, currentTitle: String)
        case finished(count: Int)
        case failed(message: String)
    }

    typealias ArchivesProvider = @Sendable (_ progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [(name: String, data: Data)]

    @Published private(set) var state: State = .stopped

    private let archivesProvider: ArchivesProvider
    private var engine: ThreadKeepWiFiSyncEngine?

    init(archivesProvider: @escaping ArchivesProvider) {
        self.archivesProvider = archivesProvider
    }

    func start() {
        guard engine == nil else { return }

        state = .waitingForPhone
        let engine = ThreadKeepWiFiSyncEngine(
            serviceName: Host.current().localizedName ?? "Mac",
            archivesProvider: archivesProvider,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
        )
        self.engine = engine
        engine.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
        state = .stopped
    }

    /// Tears down any current session and starts listening again.
    func restart() {
        stop()
        start()
    }

    private func handle(_ event: ThreadKeepWiFiSyncEngine.Event) {
        // Ignore events from an engine we've already discarded.
        guard engine != nil else { return }

        switch event {
        case .waitingForPhone:
            state = .waitingForPhone
        case let .pairing(deviceName, code):
            state = .pairing(deviceName: deviceName, code: code)
        case let .preparing(done, total):
            state = .preparing(done: done, total: total)
        case let .sending(sent, total, currentTitle):
            state = .sending(sent: sent, total: total, currentTitle: currentTitle)
        case let .finished(count):
            state = .finished(count: count)
        case let .failed(message):
            state = .failed(message: message)
        }
    }
}

/// The queue-confined networking core of the Wi-Fi sync server.
///
/// All mutable state is touched only on `queue` (the listener and connection
/// are started on that same queue, so their callbacks land there too), which
/// is what makes the `@unchecked Sendable` sound.
final class ThreadKeepWiFiSyncEngine: @unchecked Sendable {
    enum Event: Sendable {
        case waitingForPhone
        case pairing(deviceName: String, code: String)
        case preparing(done: Int, total: Int)
        case sending(sent: Int, total: Int, currentTitle: String)
        case finished(count: Int)
        case failed(message: String)
    }

    private enum Phase {
        case awaitingHello
        case awaitingCode
        case preparingArchives
        case sendingArchives
        case awaitingBye
        case closed
    }

    private let queue = DispatchQueue(label: "com.threadkeep.app.wifi-sync")
    private let serviceName: String
    private let archivesProvider: ThreadKeepWiFiSyncServer.ArchivesProvider
    private let onEvent: @Sendable (Event) -> Void

    // Queue-confined state.
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = WiFiSyncFrameDecoder()
    private var phase: Phase = .awaitingHello
    private var pairedDeviceName = ""
    private var expectedCode = ""
    private var wrongCodeAttempts = 0
    private var archiveCount = 0
    private var isStopped = false

    init(
        serviceName: String,
        archivesProvider: @escaping ThreadKeepWiFiSyncServer.ArchivesProvider,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.serviceName = serviceName
        self.archivesProvider = archivesProvider
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [weak self] in
            self?.startListenerLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.phase = .closed
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Listener

    private func startListenerLocked() {
        guard !isStopped else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            emit(.failed(message: "Couldn't start Wi-Fi sharing: \(error.localizedDescription)"))
            return
        }

        listener.service = NWListener.Service(name: serviceName, type: "_threadkeep._tcp")

        listener.stateUpdateHandler = { [weak self] newState in
            guard let self, !self.isStopped else { return }
            if case let .failed(error) = newState {
                self.emit(.failed(message: "Wi-Fi sharing stopped unexpectedly: \(error.localizedDescription)"))
                self.listener?.cancel()
                self.listener = nil
            }
        }

        listener.newConnectionHandler = { [weak self] newConnection in
            guard let self else {
                newConnection.cancel()
                return
            }
            self.accept(newConnection)
        }

        self.listener = listener
        listener.start(queue: queue)
        emit(.waitingForPhone)
    }

    private func accept(_ newConnection: NWConnection) {
        guard !isStopped else {
            newConnection.cancel()
            return
        }

        // Only one phone at a time: politely turn away extra connections.
        guard connection == nil else {
            reject(newConnection, message: "Another iPhone is already connected.")
            return
        }

        connection = newConnection
        decoder = WiFiSyncFrameDecoder()
        phase = .awaitingHello
        pairedDeviceName = ""
        wrongCodeAttempts = 0

        newConnection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .failed, .cancelled:
                self.handleConnectionDrop(of: newConnection)
            default:
                break
            }
        }

        newConnection.start(queue: queue)
        receiveNext(on: newConnection)
    }

    /// Sends a single error frame on a connection we're not adopting, then
    /// closes it. Deliberately does not touch engine state.
    private func reject(_ extraConnection: NWConnection, message: String) {
        extraConnection.start(queue: queue)
        let frame = WiFiSyncFraming.encodeFrame(Self.controlFrame(["t": "error", "message": message]))
        extraConnection.send(content: frame, completion: .contentProcessed { _ in
            extraConnection.cancel()
        })
    }

    // MARK: - Receiving

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection, !self.isStopped else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                self.drainFrames()
            }

            if error != nil || isComplete {
                self.handleConnectionDrop(of: connection)
                return
            }

            guard self.connection === connection, self.phase != .closed else { return }
            self.receiveNext(on: connection)
        }
    }

    private func drainFrames() {
        do {
            while let payload = try decoder.nextFrame() {
                handle(payload: payload)
                if phase == .closed || connection == nil {
                    return
                }
            }
        } catch {
            failSession(message: "The iPhone sent data ThreadKeep couldn't understand.")
        }
    }

    private func handle(payload: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let type = object["t"] as? String
        else {
            failSession(message: "The iPhone sent data ThreadKeep couldn't understand.")
            return
        }

        switch (phase, type) {
        case (.awaitingHello, "hello"):
            handleHello(object)
        case (.awaitingCode, "code"):
            handleCode(object)
        case (.awaitingBye, "bye"):
            handleBye()
        case (_, "bye"):
            // The phone bailed out mid-session; treat it as a clean abort.
            resetForNextConnection(notifyWaiting: true)
        default:
            // Ignore unexpected-but-harmless frames rather than tearing down.
            break
        }
    }

    // MARK: - Protocol steps

    private func handleHello(_ object: [String: Any]) {
        let deviceName = (object["device"] as? String).flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? "iPhone"

        pairedDeviceName = deviceName
        expectedCode = String(format: "%04d", Int.random(in: 0...9999))
        phase = .awaitingCode

        sendControl(["t": "code_required"]) { [weak self] in
            guard let self else { return }
            self.emit(.pairing(deviceName: deviceName, code: self.expectedCode))
        }
    }

    private func handleCode(_ object: [String: Any]) {
        let submitted = object["code"] as? String ?? ""

        guard submitted == expectedCode else {
            wrongCodeAttempts += 1
            if wrongCodeAttempts >= 3 {
                sendControl(["t": "error", "message": "Too many wrong codes."]) { [weak self] in
                    self?.failSession(message: "The code was typed wrong too many times. Close this window and try again.", alreadyNotifiedPhone: true)
                }
            } else {
                sendControl(["t": "denied", "reason": "wrong_code"])
            }
            return
        }

        phase = .preparingArchives
        // Let the phone and the Mac sheet know the code was right before the
        // (potentially long) export pass starts.
        sendControl(["t": "accepted"])
        emit(.preparing(done: 0, total: 0))

        let provider = archivesProvider
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            self?.queue.async {
                guard let self, self.phase == .preparingArchives else { return }
                self.emit(.preparing(done: done, total: total))
            }
        }
        Task { [weak self] in
            do {
                let archives = try await provider(progress)
                self?.queue.async {
                    self?.beginSending(archives: archives)
                }
            } catch {
                self?.queue.async {
                    self?.failSession(message: "Couldn't prepare your conversations: \(error.localizedDescription)")
                }
            }
        }
    }

    private func beginSending(archives: [(name: String, data: Data)]) {
        guard !isStopped, connection != nil, phase == .preparingArchives else { return }

        phase = .sendingArchives
        archiveCount = archives.count
        sendControl(["t": "begin", "count": archives.count]) { [weak self] in
            self?.sendArchive(at: 0, archives: archives)
        }
    }

    private func sendArchive(at index: Int, archives: [(name: String, data: Data)]) {
        guard !isStopped, connection != nil, phase == .sendingArchives else { return }

        guard index < archives.count else {
            phase = .awaitingBye
            sendControl(["t": "done"])
            return
        }

        let item = archives[index]
        emit(.sending(
            sent: index + 1,
            total: archives.count,
            currentTitle: Self.displayTitle(forSuggestedFilename: item.name)
        ))

        sendControl(["t": "archive", "name": item.name]) { [weak self] in
            self?.sendFrame(item.data) { [weak self] in
                self?.sendArchive(at: index + 1, archives: archives)
            }
        }
    }

    private func handleBye() {
        phase = .closed
        emit(.finished(count: archiveCount))
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Sending primitives

    /// Sends one complete frame (header + payload batched into a single Data)
    /// with a single send call; runs `completion` once the bytes are handed
    /// off, on the engine queue.
    private func sendFrame(_ payload: Data, completion: (@Sendable () -> Void)? = nil) {
        guard let connection, !isStopped else { return }

        let frame = WiFiSyncFraming.encodeFrame(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isStopped else { return }
            if error != nil {
                self.handleConnectionDrop(of: connection)
                return
            }
            completion?()
        })
    }

    private func sendControl(_ object: [String: Any], completion: (@Sendable () -> Void)? = nil) {
        sendFrame(Self.controlFrame(object), completion: completion)
    }

    private static func controlFrame(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: - Failure & teardown

    /// Fatal problem with the current session: tell the phone (unless we
    /// already did), surface a friendly message, and close the connection.
    /// The listener stays up so the user can retry without reopening the sheet.
    private func failSession(message: String, alreadyNotifiedPhone: Bool = false) {
        guard phase != .closed else { return }

        emit(.failed(message: message))

        guard let connection else {
            phase = .awaitingHello
            return
        }

        phase = .closed
        if alreadyNotifiedPhone {
            connection.cancel()
        } else {
            let frame = WiFiSyncFraming.encodeFrame(Self.controlFrame(["t": "error", "message": message]))
            connection.send(content: frame, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        self.connection = nil

        // Ready for a fresh attempt from the phone.
        phase = .awaitingHello
        decoder = WiFiSyncFrameDecoder()
        wrongCodeAttempts = 0
    }

    private func handleConnectionDrop(of droppedConnection: NWConnection) {
        guard connection === droppedConnection, !isStopped else { return }
        guard phase != .closed else {
            connection = nil
            return
        }

        let hadMeaningfulProgress = phase != .awaitingHello
        resetForNextConnection(notifyWaiting: !hadMeaningfulProgress)
        if hadMeaningfulProgress {
            emit(.failed(message: "The connection to your iPhone was interrupted before the transfer finished."))
        }
    }

    private func resetForNextConnection(notifyWaiting: Bool) {
        connection?.cancel()
        connection = nil
        decoder = WiFiSyncFrameDecoder()
        phase = .awaitingHello
        pairedDeviceName = ""
        wrongCodeAttempts = 0
        if notifyWaiting {
            emit(.waitingForPhone)
        }
    }

    private func emit(_ event: Event) {
        guard !isStopped else { return }
        onEvent(event)
    }

    // MARK: - Display helpers

    /// Turns a suggested archive filename ("ThreadKeep-nancy-glimcher.threadkeeparchive")
    /// back into something friendly enough for the progress line ("Nancy Glimcher").
    static func displayTitle(forSuggestedFilename filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        if name.hasPrefix("ThreadKeep-") {
            name = String(name.dropFirst("ThreadKeep-".count))
        }
        let words = name
            .split(separator: "-")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
        let title = words.joined(separator: " ")
        return title.isEmpty ? "Conversation" : title
    }
}
