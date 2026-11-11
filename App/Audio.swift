import AVFoundation
import NootyCore
import PencilKit
import Speech
import UIKit

/// Enregistrement audio synchronisé avec l'écriture, transcription en direct et relecture.
///
/// Chaque trait porte son heure de création ; chaque enregistrement mémorise les portions
/// d'enregistrement (entre les pauses) avec leur heure réelle. Ces deux informations suffisent
/// à retrouver le passage audio d'un trait, et inversement à rejouer l'écriture au fil de l'audio.
final class AudioController: NSObject, AVAudioPlayerDelegate {
    private weak var editor: NotebookViewController?
    private let bar = AudioBarView()

    // Enregistrement
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var recording: AudioRecording?
    private var spanStartAudio: Double = 0
    private var spanStartWall: Double = 0
    private var paused = false
    private var timer: Timer?

    // Transcription
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var requestOffset: Double = 0
    private var requestStartedAt: Date = .distantPast
    private var committed: [TranscriptSegment] = []
    private var live: [TranscriptSegment] = []
    weak var transcriptView: LiveTranscriptViewController?

    // Lecture
    private(set) var player: AVAudioPlayer?
    private(set) var playing: AudioRecording?
    private var playTimer: Timer?
    weak var playerView: PlayerViewController?
    /// Vrai quand toucher une note fait sauter au passage audio correspondant.
    var isPlaybackMode: Bool { playing != nil }
    var replayEnabled = false

    init(editor: NotebookViewController) {
        self.editor = editor
        super.init()
        bar.onRecord = { [weak self] in self?.startRecording() }
        bar.onPause = { [weak self] in self?.togglePause() }
        bar.onStop = { [weak self] in self?.stopRecording() }
        bar.onList = { [weak self] in self?.presentRecordings() }
        bar.onTranscript = { [weak self] in self?.presentLiveTranscript() }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    var isRecording: Bool { recording != nil }

    func attach() {
        guard let editor, bar.superview == nil else { return }
        // Pastille d'enregistrement, à droite de la rangée des réglages d'outil.
        editor.audioSlot.addArrangedSubview(bar)
        bar.update(state: .idle, elapsed: 0, count: editor.manifest.recordings.count)
    }

    func noteChange() {}

    func stopAll() {
        if isRecording { stopRecording() }
        stopPlayback()
    }

    private func alert(_ message: String) {
        editor?.showAlert(L("audio.title"), message)
    }

    // MARK: - Enregistrement

    func startRecording() {
        guard !isRecording else { return }
        stopPlayback()
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.alert(L("audio.micDenied"))
                    return
                }
                if TranscriptionSettings.enabled {
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async { self.beginRecording(transcribe: status == .authorized) }
                    }
                } else {
                    self.beginRecording(transcribe: false)
                }
            }
        }
    }

    private func beginRecording(transcribe: Bool) {
        guard let editor else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
            let name = ResourceName.make("m4a")
            try FileManager.default.createDirectory(at: editor.store.resourcesDirectory, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64_000 * Int(format.channelCount),
            ]
            let file = try AVAudioFile(forWriting: editor.store.resourceURL(name), settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                try? file.write(from: buffer)
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.file = file
            let number = editor.manifest.recordings.count + 1
            recording = AudioRecording(title: L("audio.defaultTitle", number), resource: name)
            spanStartAudio = 0
            spanStartWall = nowMs()
            paused = false
            committed = []
            live = []
            if transcribe { startTranscription(offset: 0) }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            UIApplication.shared.isIdleTimerDisabled = true
            tick()
            editor.rebuildToolbar()
        } catch {
            cleanupEngine()
            alert(L("audio.startFailed", error.localizedDescription))
        }
    }

    private var elapsed: Double {
        guard let r = recording else { return 0 }
        let closed = r.spans.map(\.length).reduce(0, +)
        return paused ? closed : closed + (nowMs() - spanStartWall) / 1000
    }

    private func tick() {
        bar.update(state: paused ? .paused : .recording, elapsed: elapsed, count: editor?.manifest.recordings.count ?? 0)
        // Les requêtes de reconnaissance sont limitées en durée : on en ouvre une nouvelle régulièrement.
        if request != nil, Date().timeIntervalSince(requestStartedAt) > 50, !paused {
            rotateTranscription()
        }
    }

    private func closeSpan() {
        guard var r = recording, !paused else { return }
        let length = (nowMs() - spanStartWall) / 1000
        r.spans.append(RecordingSpan(wallStart: spanStartWall, offset: spanStartAudio, length: max(0, length)))
        spanStartAudio += max(0, length)
        recording = r
    }

    func togglePause() {
        guard let engine, recording != nil else { return }
        if paused {
            do {
                try engine.start()
                spanStartWall = nowMs()
                paused = false
                if TranscriptionSettings.enabled, recognizer != nil { startTranscription(offset: spanStartAudio) }
            } catch {
                alert(L("audio.startFailed", error.localizedDescription))
            }
        } else {
            closeSpan()
            paused = true
            engine.pause()
            finishTranscriptionRequest()
        }
        tick()
    }

    func stopRecording() {
        guard recording != nil else { return }
        closeSpan()
        paused = true
        finishTranscriptionRequest()
        cleanupEngine()
        guard var r = recording else { return }
        r.transcript = committed + live
        recording = nil
        if r.duration > 0.3 {
            editor?.updateManifest { $0.recordings.append(r) }
        } else if let editor {
            try? FileManager.default.removeItem(at: editor.store.resourceURL(r.resource))
        }
        bar.update(state: .idle, elapsed: 0, count: editor?.manifest.recordings.count ?? 0)
        editor?.rebuildToolbar()
        transcriptView?.dismiss(animated: true)
    }

    private func cleanupEngine() {
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        task?.cancel()
        task = nil
        request = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async {
            if self.isRecording, !self.paused { self.togglePause() }
            self.player?.pause()
            self.playerView?.refresh()
        }
    }

    // MARK: - Transcription

    private func startTranscription(offset: Double) {
        let locale = Locale(identifier: TranscriptionSettings.language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return }
        let onDevice = recognizer.supportsOnDeviceRecognition
        guard onDevice || TranscriptionSettings.allowServer else { return }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        self.request = request
        requestOffset = offset + (paused ? 0 : (nowMs() - spanStartWall) / 1000)
        requestStartedAt = Date()
        let base = requestOffset
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let segments = result.bestTranscription.segments.map {
                    TranscriptSegment(start: base + $0.timestamp, end: base + $0.timestamp + $0.duration, text: $0.substring)
                }
                DispatchQueue.main.async {
                    self.live = Self.sentences(segments)
                    if result.isFinal {
                        self.committed.append(contentsOf: self.live)
                        self.live = []
                    }
                    self.transcriptView?.update(committed: self.committed, live: self.live)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    self.committed.append(contentsOf: self.live)
                    self.live = []
                }
            }
        }
    }

    private func finishTranscriptionRequest() {
        request?.endAudio()
        request = nil
    }

    private func rotateTranscription() {
        finishTranscriptionRequest()
        let offset = spanStartAudio + (nowMs() - spanStartWall) / 1000
        committed.append(contentsOf: live)
        live = []
        task = nil
        _ = offset
        startTranscription(offset: spanStartAudio)
    }

    /// Regroupe les mots en phrases, chaque phrase gardant le début et la fin de ses mots.
    static func sentences(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TranscriptSegment] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 1.2 { flush() }
            current.append(w)
            if let c = w.text.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }

    func presentLiveTranscript() {
        guard let editor else { return }
        let vc = LiveTranscriptViewController(controller: self)
        transcriptView = vc
        let nav = UINavigationController(rootViewController: vc)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        editor.present(nav, animated: true)
        vc.update(committed: committed, live: live)
    }

    /// Répond à une question entendue en cours, avec les notes du bloc-notes comme contexte.
    func answer(question: String, from vc: UIViewController, completion: @escaping (String) -> Void) {
        guard let editor else { return }
        let context = AIContext.build(editor: editor, scope: .notebook)
        let transcript = (committed + live).suffix(80).map(\.text).joined(separator: " ")
        let document = context.text + "\n\n[Transcription en cours]\n" + transcript
        AIConsent.confirm(from: vc, scope: context.scopeDescription + " " + L("ai.scopeLive")) {
            AIService.shared.generate(prompt: L("ai.livePrompt", question), document: document) { result in
                DispatchQueue.main.async {
                    switch result {
                    case let .success(text): completion(text)
                    case let .failure(error): completion(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Lecture

    func presentRecordings() {
        guard let editor else { return }
        let list = RecordingsViewController(controller: self)
        let nav = UINavigationController(rootViewController: list)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        editor.present(nav, animated: true)
    }

    var recordings: [AudioRecording] { editor?.manifest.recordings ?? [] }

    func url(for r: AudioRecording) -> URL? { editor?.store.resourceURL(r.resource) }

    func openRecording(_ id: UUID, query: String?) {
        guard let editor, editor.manifest.recordings.contains(where: { $0.id == id }) else { return }
        presentRecordings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startPlayback(id) }
    }

    func startPlayback(_ id: UUID) {
        guard let r = recordings.first(where: { $0.id == id }), let url = url(for: r) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.enableRate = true
            p.rate = PlaybackSettings.rate
            p.delegate = self
            p.prepareToPlay()
            player = p
            playing = r
            p.play()
            playTimer?.invalidate()
            playTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.playTick() }
            if replayEnabled { editor?.beginReplay() }
            playTick()
        } catch {
            alert(L("audio.playFailed", error.localizedDescription))
        }
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
        playerView?.refresh()
    }

    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, t))
        playTick()
    }

    func skip(_ delta: Double) {
        guard let p = player else { return }
        seek(to: p.currentTime + delta)
    }

    func setRate(_ rate: Float) {
        PlaybackSettings.rate = rate
        player?.rate = rate
        playerView?.refresh()
    }

    func setReplay(_ on: Bool) {
        replayEnabled = on
        if on, playing != nil { editor?.beginReplay() } else { editor?.endReplay() }
        playTick()
    }

    private func playTick() {
        guard let p = player, let r = playing else { return }
        if replayEnabled, let wall = r.wallTime(atAudio: p.currentTime) ?? (p.currentTime >= r.duration ? .infinity : nil) {
            editor?.updateReplay(wall: wall)
        }
        playerView?.refresh()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
        playTimer?.invalidate()
        playTimer = nil
        editor?.endReplay()
        playerView?.refresh()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playerView?.refresh()
    }

    /// Toucher un trait pendant la lecture : saut au moment où il a été écrit.
    func seek(toStrokeAt point: CGPoint, in drawing: PKDrawing) -> Bool {
        guard let r = playing else { return false }
        let candidates = drawing.strokes.filter { $0.renderBounds.insetBy(dx: -6, dy: -6).contains(point) }
        let times = candidates.compactMap { r.audioTime(atWall: ($0.path.creationDate.timeIntervalSince1970 * 1000).rounded()) }
        guard let t = times.min() else { return false }
        seek(to: max(0, t - 2))
        if player?.isPlaying == false { player?.play() }
        playerView?.refresh()
        return true
    }

    // MARK: - Gestion des enregistrements

    func rename(_ id: UUID, to title: String) {
        guard let clean = LibraryIndex.normalizedTitle(title) else { return }
        editor?.updateManifest { m in if let i = m.recordings.firstIndex(where: { $0.id == id }) { m.recordings[i].title = clean } }
    }

    func delete(_ id: UUID) {
        if playing?.id == id { stopPlayback() }
        editor?.updateManifest { $0.recordings.removeAll { $0.id == id } }
    }

    func setSummary(_ id: UUID, _ text: String) {
        editor?.updateManifest { m in if let i = m.recordings.firstIndex(where: { $0.id == id }) { m.recordings[i].summary = text } }
    }

    func exportFile(_ r: AudioRecording, mp3: Bool, from vc: UIViewController, done: @escaping (Result<URL, Error>) -> Void) {
        guard let source = url(for: r) else { return }
        let name = LibraryStore.safeFileName(r.title)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(name + (mp3 ? ".mp3" : ".m4a"))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<URL, Error> {
                try? FileManager.default.removeItem(at: target)
                if mp3 {
                    try Mp3Encoder.convert(source, to: target)
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                }
                return target
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    func summarize(_ r: AudioRecording, from vc: UIViewController, done: @escaping (String) -> Void) {
        guard let editor else { return }
        let context = AIContext.build(editor: editor, scope: .recording(r.id))
        guard !r.transcript.isEmpty else {
            done(L("audio.noTranscript"))
            return
        }
        AIConsent.confirm(from: vc, scope: context.scopeDescription) {
            AIService.shared.generate(prompt: L("ai.summaryPrompt"), document: context.text) { result in
                DispatchQueue.main.async {
                    switch result {
                    case let .success(text):
                        self.setSummary(r.id, text)
                        done(text)
                    case let .failure(error):
                        done(error.localizedDescription)
                    }
                }
            }
        }
    }
}

enum AudioError: LocalizedError {
    case noInput

    var errorDescription: String? { L("audio.noInput") }
}

enum TranscriptionSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "nooty.transcription.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.transcription.enabled") }
    }

    /// Autoriser la reconnaissance par les serveurs d'Apple si l'iPad ne sait pas la faire seul.
    static var allowServer: Bool {
        get { UserDefaults.standard.bool(forKey: "nooty.transcription.server") }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.transcription.server") }
    }

    static var language: String {
        get { UserDefaults.standard.string(forKey: "nooty.transcription.language") ?? "fr-FR" }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.transcription.language") }
    }
}

enum PlaybackSettings {
    static var rate: Float {
        get { (UserDefaults.standard.object(forKey: "nooty.playback.rate") as? Float).map { min(2, max(0.5, $0)) } ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.playback.rate") }
    }
}

func formatDuration(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Interface

/// Commandes d'enregistrement flottantes, en bas à droite de l'éditeur.
final class AudioBarView: ChromePill {
    enum State { case idle, recording, paused }

    var onRecord: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onList: (() -> Void)?
    var onTranscript: (() -> Void)?

    private let time = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        time.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        time.textColor = Theme.danger
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private func button(_ symbol: String, _ label: String, tint: UIColor = Theme.chromeText, filled: Bool = false, action: (() -> Void)?) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        config.baseForegroundColor = filled ? .white : tint
        config.baseBackgroundColor = Theme.danger
        config.cornerStyle = .large
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action?() })
        b.accessibilityLabel = label
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    /// Au repos, la pastille ne montre que l'accès aux enregistrements, s'il y en a.
    func update(state: State, elapsed: Double, count: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .idle:
            isHidden = count == 0
            let list = button("waveform", L("audio.recordings"), action: onList)
            list.configuration?.title = "\(count)"
            list.configuration?.imagePadding = 6
            stack.addArrangedSubview(list)
        case .recording, .paused:
            isHidden = false
            time.text = formatDuration(elapsed)
            time.alpha = state == .recording ? 1 : 0.5
            time.accessibilityLabel = L("audio.elapsed", formatDuration(elapsed))
            stack.addArrangedSubview(button("text.bubble", L("audio.liveTranscript"), action: onTranscript))
            stack.addArrangedSubview(button(state == .recording ? "pause.fill" : "record.circle", state == .recording ? L("audio.pause") : L("audio.resume"), action: onPause))
            stack.addArrangedSubview(button("stop.fill", L("audio.stop"), filled: true, action: onStop))
            stack.addArrangedSubview(time)
            stack.setCustomSpacing(10, after: stack.arrangedSubviews[2])
        }
    }
}

/// Transcription en direct, avec les questions détectées et leur réponse par l'IA.
final class LiveTranscriptViewController: UIViewController {
    private weak var controller: AudioController?
    private let text = UITextView()
    private let questions = UIStackView()
    private var answered: Set<String> = []

    init(controller: AudioController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("audio.liveTranscript")
        view.backgroundColor = Theme.panel
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .clear
        questions.axis = .vertical
        questions.spacing = 6
        let qScroll = UIScrollView()
        questions.translatesAutoresizingMaskIntoConstraints = false
        qScroll.addSubview(questions)
        let header = UILabel()
        header.text = L("audio.questions")
        header.font = .preferredFont(forTextStyle: .headline)
        let stack = UIStackView(arrangedSubviews: [text, header, qScroll])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            text.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 0.5),
            questions.topAnchor.constraint(equalTo: qScroll.contentLayoutGuide.topAnchor),
            questions.bottomAnchor.constraint(equalTo: qScroll.contentLayoutGuide.bottomAnchor),
            questions.leadingAnchor.constraint(equalTo: qScroll.contentLayoutGuide.leadingAnchor),
            questions.trailingAnchor.constraint(equalTo: qScroll.contentLayoutGuide.trailingAnchor),
            questions.widthAnchor.constraint(equalTo: qScroll.frameLayoutGuide.widthAnchor),
        ])
    }

    func update(committed: [TranscriptSegment], live: [TranscriptSegment]) {
        guard isViewLoaded else { return }
        let all = committed + live
        text.text = all.isEmpty ? L("audio.listening") : all.map { "[\(formatDuration($0.start))] \($0.text)" }.joined(separator: "\n")
        text.scrollRangeToVisible(NSRange(location: max(0, text.text.utf16.count - 1), length: 1))
        let asked = all.map(\.text).filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }
        let shown = Set(questions.arrangedSubviews.compactMap { ($0 as? QuestionRow)?.question })
        for q in asked.suffix(10) where !shown.contains(q) {
            let row = QuestionRow(question: q) { [weak self] row in
                guard let self else { return }
                row.setAnswer(L("ai.working"))
                self.controller?.answer(question: q, from: self) { row.setAnswer($0) }
            }
            questions.addArrangedSubview(row)
        }
    }
}

final class QuestionRow: UIStackView {
    let question: String
    private let answer = UILabel()

    init(question: String, onAnswer: @escaping (QuestionRow) -> Void) {
        self.question = question
        super.init(frame: .zero)
        axis = .vertical
        spacing = 4
        let label = UILabel()
        label.text = question
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout).withWeight(.semibold)
        answer.numberOfLines = 0
        answer.font = .preferredFont(forTextStyle: .callout)
        answer.textColor = Theme.secondaryText
        answer.isHidden = true
        var config = UIButton.Configuration.tinted()
        config.title = L("audio.answer")
        config.image = UIImage(systemName: "sparkles")
        config.imagePadding = 6
        config.baseForegroundColor = Theme.accent
        config.baseBackgroundColor = Theme.accent
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in if let self { onAnswer(self) } }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [label, button])
        row.spacing = 8
        row.alignment = .center
        addArrangedSubview(row)
        addArrangedSubview(answer)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func setAnswer(_ text: String) {
        answer.text = text
        answer.isHidden = false
    }
}

/// Liste des enregistrements du bloc-notes.
final class RecordingsViewController: UITableViewController {
    private weak var controller: AudioController?
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(controller: AudioController) {
        self.controller = controller
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("audio.recordings")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "rec")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private var items: [AudioRecording] { controller?.recordings ?? [] }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, items.count) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "rec", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if items.isEmpty {
            content.text = L("audio.none")
            content.textProperties.color = Theme.secondaryText
            cell.accessoryType = .none
        } else {
            let r = items[indexPath.row]
            content.text = r.title
            let date = r.startedAt.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
            content.secondaryText = "\(formatDuration(r.duration)) · \(date)"
            content.image = UIImage(systemName: "waveform.circle.fill")
            content.imageProperties.tintColor = Theme.accent
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !items.isEmpty, let controller else { return }
        let r = items[indexPath.row]
        let player = PlayerViewController(controller: controller, recordingID: r.id)
        navigationController?.pushViewController(player, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !items.isEmpty else { return nil }
        let r = items[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L("common.delete")) { [weak self] _, _, done in
            let alert = UIAlertController(title: L("audio.deleteTitle"), message: L("audio.deleteMessage", r.title), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel) { _ in done(false) })
            alert.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { _ in
                self?.controller?.delete(r.id)
                self?.tableView.reloadData()
                done(true)
            })
            self?.present(alert, animated: true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// Lecture d'un enregistrement : transport, vitesse, relecture des notes, transcription, résumé, export.
final class PlayerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private weak var controller: AudioController?
    private let recordingID: UUID
    private let play = UIButton(type: .system)
    private let slider = UISlider()
    private let position = UILabel()
    private let rate = UIButton(type: .system)
    private let replay = UISwitch()
    private let tabs = UISegmentedControl(items: [L("audio.transcript"), L("audio.summary")])
    private let table = UITableView(frame: .zero, style: .plain)
    private let summary = UITextView()
    private var scrubbing = false

    init(controller: AudioController, recordingID: UUID) {
        self.controller = controller
        self.recordingID = recordingID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private var recording: AudioRecording? { controller?.recordings.first { $0.id == recordingID } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.panel
        title = recording?.title
        controller?.playerView = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("action.more"), image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: L("item.rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename() },
            UIAction(title: L("audio.exportM4A"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.export(mp3: false) },
            UIAction(title: L("audio.exportMP3"), image: UIImage(systemName: "square.and.arrow.up.on.square")) { [weak self] _ in self?.export(mp3: true) },
        ]))

        play.addAction(UIAction { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            if controller.playing?.id == self.recordingID { controller.togglePlay() } else { controller.startPlayback(self.recordingID) }
            self.refresh()
        }, for: .touchUpInside)
        play.accessibilityLabel = L("audio.play")
        let back = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.controller?.skip(-15) })
        back.setImage(UIImage(systemName: "gobackward.15"), for: .normal)
        back.accessibilityLabel = L("audio.back15")
        let fwd = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.controller?.skip(15) })
        fwd.setImage(UIImage(systemName: "goforward.15"), for: .normal)
        fwd.accessibilityLabel = L("audio.forward15")
        rate.showsMenuAsPrimaryAction = true
        rate.menu = UIMenu(title: L("audio.rate"), children: ([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float]).map { r in
            UIAction(title: "\(r)×") { [weak self] _ in self?.controller?.setRate(r) }
        })
        rate.accessibilityLabel = L("audio.rate")
        slider.addAction(UIAction { [weak self] _ in self?.scrubbing = true }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.scrubbing = false
            self.controller?.seek(to: Double(self.slider.value))
        }, for: [.touchUpInside, .touchUpOutside])
        slider.accessibilityLabel = L("audio.position")
        position.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        position.textColor = Theme.secondaryText
        replay.isOn = controller?.replayEnabled ?? false
        replay.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.controller?.playing?.id != self.recordingID { self.controller?.startPlayback(self.recordingID) }
            self.controller?.setReplay(self.replay.isOn)
        }, for: .valueChanged)
        let replayLabel = UILabel()
        replayLabel.text = L("audio.replay")
        replayLabel.font = .preferredFont(forTextStyle: .callout)
        replay.accessibilityLabel = L("audio.replay")
        let hint = UILabel()
        hint.text = L("audio.tapHint")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = Theme.secondaryText
        hint.numberOfLines = 0

        let transport = UIStackView(arrangedSubviews: [back, play, fwd, UIView(), rate])
        transport.spacing = 18
        transport.alignment = .center
        let replayRow = UIStackView(arrangedSubviews: [replayLabel, UIView(), replay])
        tabs.selectedSegmentIndex = 0
        tabs.addAction(UIAction { [weak self] _ in self?.showTab() }, for: .valueChanged)
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "seg")
        table.backgroundColor = .clear
        summary.isEditable = false
        summary.font = .preferredFont(forTextStyle: .body)
        summary.backgroundColor = .clear

        let content = UIView()
        for v in [table, summary] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        let stack = UIStackView(arrangedSubviews: [transport, slider, position, replayRow, hint, tabs, content])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            play.widthAnchor.constraint(equalToConstant: 56),
            play.heightAnchor.constraint(equalToConstant: 56),
        ])
        showTab()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { controller?.stopPlayback() }
    }

    private func showTab() {
        table.isHidden = tabs.selectedSegmentIndex != 0
        summary.isHidden = tabs.selectedSegmentIndex != 1
        if tabs.selectedSegmentIndex == 1 {
            if let s = recording?.summary {
                summary.text = s
            } else {
                summary.text = L("ai.working")
                if let r = recording, let controller {
                    controller.summarize(r, from: self) { [weak self] text in self?.summary.text = text }
                }
            }
        }
    }

    func refresh() {
        guard isViewLoaded, let r = recording else { return }
        let active = controller?.playing?.id == recordingID
        let p = active ? controller?.player : nil
        let isPlaying = p?.isPlaying ?? false
        play.setImage(UIImage(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)), for: .normal)
        play.accessibilityLabel = isPlaying ? L("audio.pause") : L("audio.play")
        slider.maximumValue = Float(max(0.1, p?.duration ?? r.duration))
        if !scrubbing { slider.value = Float(p?.currentTime ?? 0) }
        position.text = "\(formatDuration(p?.currentTime ?? 0)) / \(formatDuration(p?.duration ?? r.duration))"
        rate.setTitle("\(PlaybackSettings.rate)×", for: .normal)
        if let t = p?.currentTime, let i = r.transcript.lastIndex(where: { $0.start <= t }), table.window != nil {
            table.selectRow(at: IndexPath(row: i, section: 0), animated: false, scrollPosition: .none)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, recording?.transcript.count ?? 0) }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "seg", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if let seg = recording?.transcript[safe: indexPath.row] {
            content.text = seg.text
            content.secondaryText = formatDuration(seg.start)
            content.textProperties.numberOfLines = 0
        } else {
            content.text = L("audio.noTranscript")
            content.textProperties.color = Theme.secondaryText
        }
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let seg = recording?.transcript[safe: indexPath.row], let controller else { return }
        if controller.playing?.id != recordingID { controller.startPlayback(recordingID) }
        controller.seek(to: seg.start)
    }

    private func rename() {
        let alert = UIAlertController(title: L("item.rename"), message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] in $0.text = self?.recording?.title }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.controller?.rename(self.recordingID, to: alert?.textFields?.first?.text ?? "")
            self.title = self.recording?.title
        })
        present(alert, animated: true)
    }

    private func export(mp3: Bool) {
        guard let r = recording, let controller else { return }
        navigationItem.prompt = mp3 ? L("mp3.converting") : nil
        controller.exportFile(r, mp3: mp3, from: self) { [weak self] result in
            guard let self else { return }
            self.navigationItem.prompt = nil
            switch result {
            case let .success(url):
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItem
                self.present(share, animated: true)
            case let .failure(error):
                let alert = UIAlertController(title: L("common.error"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
