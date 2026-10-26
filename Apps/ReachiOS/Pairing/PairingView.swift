import SwiftUI
import ReachCore

/// Pairing: scan the Mac's QR code (or paste it), then pair, then offer to connect straight away.
struct PairingView: View {
    let request: AppModel.PairingRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case scanning
        case pasting
        case pairing(hostName: String)
        case success(PairedHost?, name: String)
        case failure(String)
    }

    @State private var phase: Phase = .scanning

    var body: some View {
        ZStack {
            switch phase {
            case .scanning:
                ScannerScreen(onCode: handle(scanned:), onPaste: { go(.pasting) }, onClose: close)
                    .transition(.opacity)
            case .pasting:
                PasteCodeScreen(onCode: { pair($0) }, onScan: { go(.scanning) }, onClose: close)
                    .transition(.opacity)
            case .pairing(let name):
                PairingProgressScreen(hostName: name)
                    .transition(.opacity)
            case .success(let host, let name):
                PairingSuccessScreen(hostName: name, model: host?.info?.model,
                                     onConnect: { finish(connect: host) }, onDone: { finish(connect: nil) })
                    .transition(.opacity)
            case .failure(let message):
                PairingFailureScreen(message: message, onRetry: { go(.scanning) }, onClose: close)
                    .transition(.opacity)
            }
        }
        .animation(.reach(reduceMotion), value: phase)
        .preferredColorScheme(.dark)
        .onAppear(perform: setInitialPhase)
    }

    private func setInitialPhase() {
        switch request.mode {
        case .scan: phase = .scanning
        case .paste: phase = .pasting
        case .code(let code): pair(code)
        }
        // Screenshot/demo states (`-pairing success|failure|progress`).
        switch LaunchOptions.pairing {
        case "success": phase = .success(nil, name: "Alex’s MacBook Pro")
        case "failure": phase = .failure(ReachError.pairingExpired.errorDescription ?? "")
        case "progress": phase = .pairing(hostName: "Alex’s MacBook Pro")
        default: break
        }
    }

    private func go(_ p: Phase) { phase = p }

    private func handle(scanned string: String) -> Bool {
        guard let code = try? PairingCode(string: string) else { return false }
        Haptics.shared.play(.scanned)
        // Let the viewfinder visibly lock onto the code before moving on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pair(code) }
        return true
    }

    private func pair(_ code: PairingCode) {
        phase = .pairing(hostName: code.hostName)
        let started = Date()
        model.pair(code) { result in
            // Keep the progress state on screen long enough to read, even when pairing is instant.
            let wait = max(0, 0.8 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                switch result {
                case .success(let host):
                    Haptics.shared.play(.connected)
                    phase = .success(host, name: host.name)
                case .failure(let error):
                    Haptics.shared.play(.failure)
                    phase = .failure(Self.message(for: error))
                }
            }
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? ReachError {
            switch e {
            case .timeout: return "Your Mac didn’t answer. Make sure Reach Host is running and the code is still on screen, then try again."
            case .relayUnavailable: return "Couldn’t reach the internet. Check your connection, or join the same Wi‑Fi as your Mac."
            default: return e.errorDescription ?? "Pairing failed."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func finish(connect host: PairedHost?) {
        dismiss()
        guard let host else { return }
        Task { @MainActor in
            // The session is presented from Home; wait for this cover to finish dismissing.
            try? await Task.sleep(for: .milliseconds(550))
            if let entry = model.entry(for: host) { model.connect(entry) }
        }
    }

    private func close() { dismiss() }
}

// MARK: - Scanner

private struct ScannerScreen: View {
    /// Returns whether the code was accepted (otherwise scanning continues with a hint).
    var onCode: (String) -> Bool
    var onPaste: () -> Void
    var onClose: () -> Void

    @State private var status: QRScanner.Status = .starting
    @State private var lockRect: CGRect?
    @State private var rejected = false
    @State private var rejectTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(status: $status, onCode: { string, rect in
                guard lockRect == nil else { return }
                if onCode(string) {
                    lockRect = rect
                } else {
                    showRejected()
                }
            })
            .ignoresSafeArea()
            .opacity(status == .running ? 1 : 0)
            .animation(.easeOut(duration: 0.35), value: status)

            if status != .running {
                LinearGradient(colors: [Theme.accentDeep.opacity(0.5), .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            Viewfinder(lockRect: lockRect)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassSurface(in: Circle(), interactive: true)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VStack(spacing: 6) {
                    Text("Scan the Code on Your Mac")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .shadow(color: .black.opacity(0.5), radius: 8)

                Spacer()

                VStack(spacing: 12) {
                    if status == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Allow Camera Access", systemImage: "camera")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .prominentGlassButton()
                    }
                    Button(action: onPaste) {
                        Label("Paste Code Instead", systemImage: "doc.on.clipboard")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: rejected)
    }

    private var subtitle: String {
        if rejected { return "That’s not a Reach pairing code." }
        switch status {
        case .starting: return "Starting the camera…"
        case .running: return "Open Reach Host in the menu bar and choose Pair iPhone."
        case .denied: return "Reach needs the camera to scan the pairing code. You can paste the code instead."
        case .unavailable: return "No camera is available here. Copy the code on your Mac and paste it instead."
        }
    }

    private func showRejected() {
        guard !rejected else { return }
        rejected = true
        Haptics.shared.play(.failure)
        rejectTask?.cancel()
        rejectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            rejected = false
        }
    }
}

/// Rounded-corner viewfinder that snaps onto the detected code.
private struct Viewfinder: View {
    var lockRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.62
            let idle = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2 - 20, width: side, height: side)
            let rect = lockRect.map { $0.insetBy(dx: -14, dy: -14) } ?? idle
            ZStack {
                // Dim everything outside the viewfinder.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: idle, cornerSize: CGSize(width: 36, height: 36), style: .continuous)
                }
                .fill(.black.opacity(lockRect == nil ? 0.42 : 0.2), style: FillStyle(eoFill: true))

                CornerBrackets()
                    .stroke(lockRect == nil ? Color.white : Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: (lockRect == nil ? Color.black : Theme.accent).opacity(0.5), radius: 10)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: lockRect)
        }
        .accessibilityHidden(true)
    }
}

/// Four rounded corner strokes.
private struct CornerBrackets: Shape {
    func path(in r: CGRect) -> Path {
        let len = min(r.width, r.height) * 0.2
        let radius: CGFloat = min(28, len * 0.8)
        var p = Path()
        func corner(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) {
            p.move(to: a)
            p.addArc(tangent1End: c, tangent2End: b, radius: radius)
            p.addLine(to: b)
        }
        corner(CGPoint(x: r.minX, y: r.minY + len), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + len, y: r.minY))
        corner(CGPoint(x: r.maxX - len, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + len))
        corner(CGPoint(x: r.maxX, y: r.maxY - len), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - len, y: r.maxY))
        corner(CGPoint(x: r.minX + len, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - len))
        return p
    }
}

/// UIKit bridge for the camera preview. The scanner starts on appear and stops on disappear.
private struct CameraPreview: UIViewRepresentable {
    @Binding var status: QRScanner.Status
    var onCode: (String, CGRect?) -> Void

    func makeCoordinator() -> QRScanner { QRScanner() }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        let scanner = context.coordinator
        scanner.onStatus = { [weak view, weak scanner] s in
            status = s
            if s == .running, let device = scanner?.device { view?.trackRotation(of: device) }
        }
        scanner.onCode = { [weak view] code in
            guard let string = code.stringValue else { return }
            onCode(string, view?.rect(for: code))
        }
        scanner.start()
        return view
    }

    func updateUIView(_ view: ScannerPreviewView, context: Context) {}

    static func dismantleUIView(_ view: ScannerPreviewView, coordinator: QRScanner) {
        coordinator.onCode = nil
        coordinator.onStatus = nil
        coordinator.stop()
    }
}

// MARK: - Paste

private struct PasteCodeScreen: View {
    var onCode: (PairingCode) -> Void
    var onScan: () -> Void
    var onClose: () -> Void

    @State private var text = ""
    /// The rejected text and why; the message hides as soon as the text is edited.
    @State private var rejection: (text: String, message: String)?
    @FocusState private var fieldFocused: Bool

    private var error: String? { rejection?.text == text ? rejection?.message : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Theme.glow(radius: 120).frame(width: 260, height: 260)
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.white)
                    }
                    .frame(height: 130)
                    .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Paste the Pairing Code")
                            .font(.title2.weight(.bold))
                        Text("On your Mac, choose Copy Code under Pair iPhone. With Universal Clipboard it’s ready to paste here.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        Task { @MainActor in
                            text = s
                            submit()
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Theme.accent)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or enter it manually")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("reach://pair?…", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($fieldFocused)
                            .onSubmit(submit)
                            .padding(14)
                            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(error == nil ? .white.opacity(0.08) : Theme.danger.opacity(0.7), lineWidth: 1)
                            }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.danger)
                        }
                    }

                    Button(action: submit) {
                        Text("Pair").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.backdrop)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onScan) { Label("Scan", systemImage: "qrcode.viewfinder") }
                }
            }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            onCode(try PairingCode(string: trimmed))
        } catch {
            rejection = (text, (error as? LocalizedError)?.errorDescription ?? "That isn’t a valid Reach pairing code.")
            Haptics.shared.play(.failure)
        }
    }
}

// MARK: - Progress, success, failure

private struct PairingProgressScreen: View {
    let hostName: String

    var body: some View {
        ZStack {
            Theme.backdrop
            VStack(spacing: 22) {
                ZStack {
                    Theme.glow(radius: 150).frame(width: 320, height: 320)
                    HStack(spacing: 18) {
                        Image(systemName: "iphone").font(.system(size: 44, weight: .light))
                        ProgressView().controlSize(.regular).tint(.white)
                        Image(systemName: "macbook").font(.system(size: 56, weight: .light))
                    }
                }
                .frame(height: 110)   // the glow overflows; it shouldn't push the text away
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Pairing with")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(hostName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                Text("Exchanging keys securely…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PairingSuccessScreen: View {
    let hostName: String
    let model: String?
    var onConnect: () -> Void
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            Theme.backdrop
            Theme.glow(Theme.online, radius: 220).offset(y: -120).opacity(shown ? 1 : 0)
            VStack(spacing: 24) {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: MacGlyph.symbol(forModel: model))
                        .font(.system(size: 92, weight: .ultraLight))
                        .foregroundStyle(.white)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.online)
                        .background(Circle().fill(Theme.background).padding(3))
                        .offset(x: 14, y: 8)
                        .scaleEffect(shown || reduceMotion ? 1 : 0.2)
                        .opacity(shown ? 1 : 0)
                }
                .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Paired")
                        .font(.largeTitle.weight(.bold))
                    Text("\(hostName) is ready. You can connect from anywhere — at home or away.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: onConnect) {
                        Text("Connect Now").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()
                    Button(action: onDone) {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) { shown = true }
            UIAccessibility.post(notification: .screenChanged, argument: "Paired with \(hostName)")
        }
    }
}

private struct PairingFailureScreen: View {
    let message: String
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Theme.backdrop
            Theme.glow(Theme.danger, radius: 200).offset(y: -120)
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Couldn’t Pair")
                        .font(.title.weight(.bold))
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        Text("Scan Again").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()
                    Button(action: onClose) {
                        Text("Close").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: "Couldn’t pair. \(message)") }
    }
}
