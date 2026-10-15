import AppKit
import Combine
import Foundation
import Translation
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppState: ObservableObject {
    private static let liveStates = NSHashTable<AppState>.weakObjects()
    @Published var input = "" {
        didSet { preprocessingOriginal = nil }
    }
    @Published var results: [ResultCard] = []
    @Published var preferences: AppPreferences
    @Published var history: [HistoryItem]
    @Published var shortcuts: [String: ShortcutConfig]
    @Published var notice: String?
    @Published var working = false
    @Published private(set) var recognizing = false
    @Published private(set) var recognizingService: ServiceConfig?
    @Published var pinned = false
    let windowRole: String
    @Published var mode = "translate"
    @Published var ocrDocument: OCRDocument?
    @Published private(set) var ocrImages = OCRImageCollection()
    private(set) var lastOCRBatchOutcome: OCRImageBatchOutcome?
    @Published var showsOCRImages = true
    @Published var imageURL: URL?
    @Published var showBoxes = true
    @Published var historySearch = ""
    @Published var favoritesOnly = false
    @Published var systemConfiguration: TranslationSession.Configuration?
    @Published var imageTranslations: [Int: String] = [:]
    @Published var imageOverlay = false
    @Published var shortcutErrors: [String] = []
    @Published var settingsSection = "translate"
    @Published var settingsServiceCategory = "translate"
    @Published var queryRevision = 0
    @Published var continuousOCR = false
    @Published var canUndoReplacement = false
    @Published private(set) var canInsertResult = false
    @Published private(set) var currentHistoryID: UUID?
    var systemRequest: TranslationRequest?
    var systemJobID = UUID()
    private(set) var systemTicket = UUID()
    var systemImageBatch = false
    var onShowWindow: (() -> Void)?
    var isWindowVisible: (() -> Bool)?
    private let transientHUD = PopTransientHUD()
    private let imageFilePanel = NativeImageFilePanel()
    var onPinChange: ((Bool) -> Void)?
    var onCloseWindow: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onContentHeight: ((Double) -> Void)?
    var windowPositionOverride: String?
    var inputDisplayOverride: String?
    private var generation = UUID()
    private var remoteTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var acquisitionTask: Task<Void, Never>?
    private let http = HTTPTranslationService()
    private var historySavedFor: UUID?
    private var resultCopyPolicy = FirstResultCopyPolicy()
    private var recordingRequest: TranslationRequest?
    private var preprocessingOriginal: (displayed: String, original: String)?
    private var originalInput: String {
        guard let saved = preprocessingOriginal, saved.displayed == input else { return input }
        return saved.original
    }
    private var audioPlayer: AVAudioPlayer?
    private var audioTask: Task<Void, Never>?
    private var audioTicket = UUID()
    private static weak var audioOwner: AppState?
    private var historySubscription: AnyCancellable?
    private var configurationSubscriptions = Set<AnyCancellable>()
    private var temporaryImages: Set<URL> = []
    private var selectionDestination: SelectionDestination?
    private var lastSystemConfiguration: TranslationSession.Configuration?
    private var extraTasks: [Task<Void, Never>] = []
    private var lastReplacement: SelectionDestination?
    private struct ImageOverlayContext {
        let id = UUID()
        let capture: CapturedRegion
    }
    private var imageOverlayContext: ImageOverlayContext?
    init(windowRole: String = "translation") {
        self.windowRole = windowRole
        preferences = ConfigurationRepository.shared.preferences
        history = HistoryRepository.shared.items
        shortcuts = ConfigurationRepository.shared.shortcuts
        pinned = windowRole == "ocr" ? preferences.ocrPinned : preferences.translationPinned
        historySubscription = HistoryRepository.shared.$items.sink { [weak self] in self?.history = $0 }
        ConfigurationRepository.shared.$preferences.sink { [weak self] value in
            guard let self, self.preferences != value else { return }
            self.preferences = value
            let pin = self.windowRole == "ocr" ? value.ocrPinned : value.translationPinned
            if self.pinned != pin { self.pinned = pin; self.onPinChange?(pin) }
        }.store(in: &configurationSubscriptions)
        ConfigurationRepository.shared.$shortcuts.sink { [weak self] value in
            guard let self, self.shortcuts != value else { return }
            self.shortcuts = value
        }.store(in: &configurationSubscriptions)
        Self.liveStates.add(self)
    }

    func savePreferences() {
        do {
            try ConfigurationRepository.shared.save(preferences: preferences, shortcuts: shortcuts)
        } catch { notice = error.localizedDescription }
        applyAppearance()
    }

    private func applyAppearance() {
        if preferences.appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        else if preferences.appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        else { NSApp.appearance = nil }
    }

    func translate() {
        if let delegate = AppDelegate.shared, self === delegate.ocrState {
            delegate.translateOCRText(input)
            return
        }
        performTranslation(only: nil)
    }
    func translateService(_ id: UUID) {
        guard let original = preferences.services.first(where: { $0.id == id && $0.enabled && $0.capability == "translate" }) else {
            notice = "该翻译服务已停用，请先在设置中启用。"; return
        }
        guard let request = recordingRequest,
              request.text == TextUtilities.processedInput(input, preferences: preferences),
              request.originalText == originalInput,
              request.source == preferences.sourceLanguage,
              request.target == TextUtilities.targetLanguage(for: input, preferences: preferences) else {
            performTranslation(only: id); return
        }
        if results.contains(where: { $0.serviceID == id && $0.loading }) { return }
        if let index = results.firstIndex(where: { $0.serviceID == id }) {
            results[index] = ResultCard(serviceID: id, name: original.name)
        } else {
            let order = preferences.services.map(\.id)
            let position = order.firstIndex(of: id) ?? order.endIndex
            let insertion = results.firstIndex { (order.firstIndex(of: $0.serviceID) ?? order.endIndex) > position } ?? results.endIndex
            results.insert(ResultCard(serviceID: id, name: original.name), at: insertion)
        }
        preferences.collapsedServiceIDs.removeAll { $0 == id }
        working = true
        let job = generation
        if original.kind == .apple {
            let detected = request.source == "auto" ? TextUtilities.detectLanguage(request.text) : request.source
            if sameLanguage(detected, request.target) {
                finish(id, output: TranslationOutput(text: request.text, detectedSource: detected), error: nil, job: job)
                return
            }
            systemImageBatch = false; systemRequest = request; systemJobID = job
            activateSystemTranslation(request)
        } else {
            let service = effectiveConfig(original)
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let update: @Sendable (TranslationOutput) -> Void = { value in Task { @MainActor in self.preview(id, output: value, job: job) } }
                    let output = try await translateNonSystem(request, service: service, onStream: update)
                    finish(id, output: output, error: nil, job: job)
                } catch { finish(id, output: nil, error: error.localizedDescription, job: job) }
            }
            extraTasks.append(task)
        }
    }

    private func performTranslation(only serviceID: UUID?) {
        let originalText = originalInput
        let text = TextUtilities.processedInput(input, preferences: preferences)
        guard !text.isEmpty else { notice = "请输入或选取要翻译的文字。"; return }
        input = text
        preprocessingOriginal = (text, originalText)
        cancelTranslation()
        historySavedFor = nil
        currentHistoryID = nil
        imageTranslations = [:]
        systemImageBatch = false
        queryRevision += 1
        if preferences.resultDisplay == "expanded" { preferences.collapsedServiceIDs = [] }
        if preferences.resultDisplay == "collapsed" { preferences.collapsedServiceIDs = preferences.services.map(\.id) }
        let request = TranslationRequest(text: text, source: preferences.sourceLanguage, target: TextUtilities.targetLanguage(for: text, preferences: preferences), originalText: originalText)
        recordingRequest = request
        let enabled = preferences.services.filter {
            $0.enabled && $0.capability == "translate" && (serviceID == nil
                ? $0.triggerStrategy(legacyPinned: preferences.pinnedServiceIDs.contains($0.id)) != .pinned
                : $0.id == serviceID)
        }
        guard !enabled.isEmpty else {
            results = []
            notice = preferences.services.contains(where: { $0.enabled && $0.capability == "translate" })
                ? "点击语言栏旁的服务图标，按需翻译。" : "请在设置中启用至少一项翻译服务。"
            return
        }
        results = enabled.map { service in
            if serviceID != nil {
                preferences.collapsedServiceIDs.removeAll { $0 == service.id }
                return ResultCard(serviceID: service.id, name: service.name)
            }
            let strategy = service.triggerStrategy(legacyPinned: preferences.pinnedServiceIDs.contains(service.id))
            if strategy == .alwaysCollapsed, !preferences.collapsedServiceIDs.contains(service.id) {
                preferences.collapsedServiceIDs.append(service.id)
            }
            let deferred = strategy.defersQuery(isCollapsed: preferences.collapsedServiceIDs.contains(service.id))
            return ResultCard(serviceID: service.id, name: service.name, loading: !deferred, deferred: deferred)
        }
        let requestedIDs = Set(results.filter(\.loading).map(\.serviceID))
        let requested = enabled.filter { requestedIDs.contains($0.id) }
        working = !requested.isEmpty
        notice = nil
        let job = generation
        if preferences.autoSpeakSource { speak(text) }
        let apple = requested.filter { $0.kind == .apple }
        if !apple.isEmpty {
            let detected = request.source == "auto" ? TextUtilities.detectLanguage(request.text) : request.source
            if sameLanguage(detected, request.target) {
                systemRequest = nil
                systemConfiguration = nil
                for service in apple { finish(service.id, output: TranslationOutput(text: text, detectedSource: detected), error: nil, job: job) }
            } else {
                systemRequest = request
                systemJobID = job
                activateSystemTranslation(request)
            }
        } else {
            systemRequest = nil
            systemConfiguration = nil
        }
        let remoteServices = requested.filter { $0.kind != .apple }
        remoteTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (UUID, TranslationOutput?, String?).self) { group in
                for original in remoteServices {
                    let service = self.effectiveConfig(original)
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let output = try await self.translateNonSystem(request, service: service, onStream: { output in
                                Task { @MainActor in self.preview(service.id, output: output, job: job) }
                            })
                            return (service.id, output, nil)
                        } catch { return (service.id, nil, error.localizedDescription) }
                    }
                }
                for await (id, output, error) in group {
                    self.finish(id, output: output, error: error, job: job)
                }
            }
            if self.generation == job { self.refreshWorking() }
        }
        refreshWorking()
    }

    private func activateSystemTranslation(_ request: TranslationRequest) {
        systemTicket = UUID()
        let detected = request.source == "auto" ? TextUtilities.detectLanguage(request.text) : request.source
        let source = detected == "auto" || detected == "und" ? nil : Locale.Language(identifier: detected)
        let target = Locale.Language(identifier: request.target)
        let configuration = TranslationSession.Configuration(source: source, target: target)
        var next: TranslationSession.Configuration
        if let previous = lastSystemConfiguration, previous.source == configuration.source, previous.target == configuration.target {
            next = previous
        } else { next = configuration }
        // Cancellation may publish nil and a new configuration in one UI update.
        // Give every request a new revision, including repeated language pairs.
        next.invalidate()
        lastSystemConfiguration = next
        systemConfiguration = next
    }

    func awaitSystemCooldown(job: UUID, ticket: UUID? = nil, service: ServiceConfig? = nil) async throws {
        try Task.checkCancellation()
        guard systemJobIsCurrent(job: job, ticket: ticket) else { throw CancellationError() }
        let candidates: [ServiceConfig]
        if let service { candidates = [service] }
        else {
            let pending = Set(results.filter(\.loading).map(\.serviceID))
            candidates = preferences.services.filter {
                $0.enabled && $0.kind == .apple && $0.capability == "translate" && (systemImageBatch || pending.contains($0.id))
            }
        }
        var seconds = 0.0
        for candidate in candidates {
            guard let value = Double(candidate.options["cooldownSeconds"] ?? "0"), value.isFinite, (0...3600).contains(value) else {
                throw PopError.message("系统翻译冷却时间须在 0–3600 秒之间。")
            }
            seconds = max(seconds, value)
        }
        try await SystemTranslationCooldown.shared.wait(seconds: seconds) { [weak self] in
            guard let self else { return false }
            return await self.systemJobIsCurrent(job: job, ticket: ticket)
        }
        try Task.checkCancellation()
        guard systemJobIsCurrent(job: job, ticket: ticket) else { throw CancellationError() }
    }

    private func systemJobIsCurrent(job: UUID, ticket: UUID?) -> Bool {
        generation == job && (ticket == nil || systemTicket == ticket)
    }

    func systemCompleted(_ output: TranslationOutput?, error: String?, job: UUID, ticket: UUID) {
        guard job == generation, ticket == systemTicket else { return }
        for service in preferences.services where service.kind == .apple && results.contains(where: { $0.serviceID == service.id && $0.loading }) {
            finish(service.id, output: output, error: error, job: job)
        }
    }

    func finish(_ serviceID: UUID, output: TranslationOutput?, error: String?, job: UUID) {
        guard generation == job, let index = results.firstIndex(where: { $0.serviceID == serviceID }) else { return }
        LocalDiagnostics.record(error == nil ? "translation_completed" : "translation_failed")
        results[index].loading = false
        results[index].error = error
        results[index].text = output?.text ?? ""
        results[index].pronunciation = output?.pronunciation
        results[index].details = output?.details ?? []
        results[index].reasoning = output?.reasoning
        results[index].format = output?.format
        results[index].dictionary = output?.dictionary
        autoCopyFirstResult(job: job)
        refreshWorking()
    }

    private func autoCopyFirstResult(job: UUID) {
        if let text = resultCopyPolicy.nextText(in: results, queryID: job, enabled: preferences.autoCopyFirstResult) {
            copy(text)
        }
    }

    private func preview(_ serviceID: UUID, output: TranslationOutput, job: UUID) {
        guard generation == job, let index = results.firstIndex(where: { $0.serviceID == serviceID }), results[index].loading else { return }
        results[index].text = output.text
        results[index].details = output.details
        results[index].reasoning = output.reasoning
        results[index].format = output.format
        results[index].dictionary = output.dictionary
    }

    private func refreshWorking() {
        working = results.contains { $0.loading }
        guard !working, preferences.saveHistory,
              let request = recordingRequest else { return }
        let successful = results.filter { !$0.text.isEmpty }
        guard !successful.isEmpty else { return }
        var values: [String: String] = [:]
        for result in successful {
            var name = result.name
            var number = 2
            while values[name] != nil { name = "\(result.name) (\(number))"; number += 1 }
            values[name] = result.text
        }
        if historySavedFor == generation, let id = currentHistoryID, let index = history.firstIndex(where: { $0.id == id }) {
            history[index].results = values; saveHistory(); return
        }
        let item = HistoryItem(source: request.text, sourceLanguage: request.source, targetLanguage: request.target, results: values)
        history.insert(item, at: 0)
        currentHistoryID = item.id
        history = Array(history.prefix(preferences.historyLimit))
        historySavedFor = generation
        saveHistory()
    }

    func cancelTranslation(closeOverlay: Bool = true) {
        transientHUD.dismiss()
        if closeOverlay { closeOwnedImageOverlay() }
        stopAudioPlayback()
        remoteTask?.cancel()
        ocrTask?.cancel()
        ocrImages.interrupt()
        acquisitionTask?.cancel()
        acquisitionTask = nil
        for task in extraTasks { task.cancel() }
        extraTasks = []
        generation = UUID()
        systemTicket = UUID()
        systemConfiguration = nil
        systemRequest = nil
        systemImageBatch = false
        recordingRequest = nil
        for index in results.indices where results[index].loading {
            results[index].loading = false
            results[index].error = "已取消"
        }
        working = false
        recognizing = false
        recognizingService = nil
    }

    func retry() { translate() }

    func swapLanguages() {
        let oldSource = preferences.sourceLanguage == "auto" ? TextUtilities.detectLanguage(input) : preferences.sourceLanguage
        let oldTarget = TextUtilities.targetLanguage(for: input, preferences: preferences)
        preferences.sourceLanguage = oldTarget
        preferences.targetLanguage = oldSource == "auto" ? "en" : oldSource
        preferences.autoTargetLanguage = false
        if let text = results.first(where: { !$0.text.isEmpty })?.text { input = text }
        savePreferences()
        if !input.isEmpty { translate() }
    }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .input:
            clearInput(); mode = "translate"
            applyEntryPresentation(position: preferences.inputWindowPosition, inputDisplay: "expanded")
            queryRevision += 1
            onShowWindow?()
        case .selection:
            cancelTranslation()
            let ticket = generation
            acquisitionTask = Task {
                do {
                    let destination = SelectionDestination.capture()
                    let selected = try await NativeSelection.selectedText(mode: preferences.selectionMode)
                    guard !Task.isCancelled, generation == ticket else { return }
                    acquisitionTask = nil
                    selectionDestination = destination
                    input = selected
                    canInsertResult = selectionDestination != nil
                    mode = "translate"
                    applyEntryPresentation(position: preferences.selectionWindowPosition, inputDisplay: preferences.selectionInputDisplay)
                    onShowWindow?()
                    translate()
                } catch is CancellationError { }
                catch {
                    if generation == ticket {
                        selectionDestination = nil; canInsertResult = false
                        if !preferences.hideSelectionError { notice = error.localizedDescription; onShowWindow?() }
                    }
                }
            }
        case .screenshotTranslation: capture(translate: true, silent: false)
        case .screenshotOCR: capture(translate: false, silent: false)
        case .silentOCR: capture(translate: false, silent: true)
        case .silentSelection: silentTranslate(entireInput: false)
        case .silentInput: silentTranslate(entireInput: true)
        case .continuousOCR:
            capture(translate: false, silent: false, append: true)
        case .imageTranslation: captureImageTranslation()
        case .clipboardTranslation: translateClipboard()
        case .showTranslationWindow:
            mode = "translate"
            applyEntryPresentation(position: preferences.selectionWindowPosition)
            onShowWindow?()
        case .fileOCR: AppDelegate.shared?.recognizeFinderSelection()
        case .pasteboardOCR: recognizeClipboard()
        case .showOCRWindow:
            mode = "ocr"
            applyEntryPresentation(position: preferences.ocrWindowPosition)
            onShowWindow?()
        case .showPreferences: AppDelegate.shared?.showSettings()
        }
    }

    private func applyEntryPresentation(position: String, inputDisplay: String? = nil) {
        // Explicit automation parameters take precedence over entry defaults.
        if windowPositionOverride == nil { windowPositionOverride = position }
        if inputDisplayOverride == nil { inputDisplayOverride = inputDisplay }
    }

    func capture(translate: Bool, silent: Bool, append: Bool? = nil) {
        if !translate, let delegate = AppDelegate.shared, self !== delegate.ocrState {
            delegate.ocrState.capture(translate: false, silent: silent, append: append)
            return
        }
        if !translate, append == true { continuousOCR = true }
        let shouldAppend = !translate && (append ?? continuousOCR)
        cancelTranslation()
        let ticket = generation
        NativeImageOverlay.shared.close()
        onCloseWindow?()
        acquisitionTask = Task {
            do {
                let url = try await NativeScreenshot.captureRegion()
                guard !Task.isCancelled, generation == ticket else { try? FileManager.default.removeItem(at: url); return }
                acquisitionTask = nil
                temporaryImages.insert(url)
                recognize(urls: [url], translateAfter: translate, silent: silent, append: shouldAppend)
            } catch is CancellationError { }
            catch { if generation == ticket { notice = error.localizedDescription; onShowWindow?() } }
        }
    }

    func chooseImages() {
        if let delegate = AppDelegate.shared, self !== delegate.ocrState {
            delegate.ocrState.chooseImages()
            return
        }
        // Opening or cancelling the picker must not clear an existing OCR job.
        // Bob submits the accepted URLs asynchronously and honors continuous mode.
        imageFilePanel.present { [weak self] urls in
            guard let self else { return }
            self.recognize(urls: urls, translateAfter: false, silent: false, append: self.continuousOCR)
        }
    }

    func selectOCRImage(_ id: UUID) {
        ocrImages.select(id)
        refreshOCRImagePresentation()
    }

    func mergeOCRImageText() {
        ocrImages.merge()
        refreshOCRImagePresentation()
    }

    func updateOCRText(_ value: String) {
        ocrImages.editText(value)
        input = value
    }

    var canResumeOCRImages: Bool { !recognizing && ocrImages.tasks.contains { $0.status == .waiting } }

    func resumeOCRImages() {
        guard canResumeOCRImages else { return }
        cancelTranslation()
        startOCRImageQueue(silent: false)
    }

    func retryOCRImages(_ id: UUID? = nil) {
        guard !ocrImages.tasks.isEmpty else { return }
        cancelTranslation()
        ocrImages.retry(id)
        startOCRImageQueue(silent: false)
    }

    private func recognizeOCRImages(urls: [URL], silent: Bool, append: Bool) {
        guard !urls.isEmpty else { return }
        let oldText = input
        cancelTranslation()
        ocrImages.add(urls, append: append, existingText: oldText)
        results = []
        selectionDestination = nil
        canInsertResult = false
        currentHistoryID = nil
        imageTranslations = [:]
        imageOverlay = false
        startOCRImageQueue(silent: silent)
    }

    private func refreshOCRImagePresentation() {
        input = ocrImages.text
        imageURL = ocrImages.selected?.url
        ocrDocument = ocrImages.selected?.document
        imageTranslations = [:]
        imageOverlay = false
        if ocrImages.mergesAllText {
            notice = ocrImages.outcome(for: Set(ocrImages.tasks.map(\.id))).failureNotice ?? lastOCRBatchOutcome?.notice
        } else { notice = ocrImages.selected?.error ?? lastOCRBatchOutcome?.notice }
    }

    private func startOCRImageQueue(silent: Bool) {
        let ticket = generation
        let prefs = preferences
        let service = prefs.selectedOCRService(forTranslation: false)
        let pending = ocrImages.tasks.filter { $0.status == .waiting }.map { ($0.id, $0.url) }
        lastOCRBatchOutcome = nil
        let showHUD = silent && !prefs.hideSilentOCRLoading && !(isWindowVisible?() ?? false)
        let hudPosition = NSEvent.mouseLocation
        let openOCR: () -> Void = { [weak self] in self?.mode = "ocr"; self?.onShowWindow?() }
        refreshOCRImagePresentation()
        recognizing = !pending.isEmpty
        recognizingService = service
        working = !pending.isEmpty
        if !silent {
            mode = "ocr"
            applyEntryPresentation(position: prefs.ocrWindowPosition)
            queryRevision += 1
            onShowWindow?()
        }
        ocrTask = Task { [self] in
            guard generation == ticket, !Task.isCancelled else { return }
            if showHUD { transientHUD.loading(at: hudPosition, onClick: openOCR) }
            for (id, url) in pending {
                guard generation == ticket, !Task.isCancelled else { return }
                ocrImages.markRecognizing(id)
                do {
                    guard let service else { throw PopError.message("请至少开启 1 个文本识别服务。") }
                    let document: OCRDocument
                    if service.kind != .apple {
                        let data = try Data(contentsOf: url)
                        if service.kind == .plugin { document = try await PluginService.shared.recognize(imageData: data, service: effectiveConfig(service)) }
                        else { document = try await CloudMediaService().recognize(imageData: data, service: service, apiKey: SecretStore.read(SecretStore.serviceKey(service.credentialID))) }
                    } else {
                        let options = service.options
                        let languages = options["languages"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        document = try await VisionOCR.recognize(url: url,
                            accurate: options["accurate"].flatMap(Bool.init) ?? prefs.ocrAccurate,
                            languages: languages?.isEmpty == false ? languages! : prefs.ocrLanguages,
                            languageCorrection: options["languageCorrection"].flatMap(Bool.init) ?? prefs.ocrLanguageCorrection,
                            recognizeQRCodes: prefs.recognizeQRCode)
                    }
                    guard generation == ticket, !Task.isCancelled else { return }
                    let retained = OCRDocument(text: document.text, lines: document.lines,
                                               qrCodes: prefs.recognizeQRCode ? document.qrCodes : [])
                    let paragraphMode = service.options["paragraphMode"] ?? (prefs.smartOCRParagraphs ? "smart" : "provider")
                    let text = document.lines.isEmpty || paragraphMode == "provider" ? document.text : OCRTextLayout.text(from: document.lines, smartParagraphs: true)
                    ocrImages.complete(id, document: retained, text: text)
                    LocalDiagnostics.record("ocr_completed")
                } catch {
                    guard generation == ticket, !Task.isCancelled else { return }
                    LocalDiagnostics.record("ocr_failed", error: error)
                    ocrImages.fail(id, message: error.localizedDescription)
                }
                refreshOCRImagePresentation()
            }
            guard generation == ticket, !Task.isCancelled else { return }
            recognizing = false
            recognizingService = nil
            working = false
            let outcome = ocrImages.outcome(for: Set(pending.map { $0.0 }))
            lastOCRBatchOutcome = outcome
            refreshOCRImagePresentation()
            let copyText = ([ocrImages.text] + ocrImages.qrCodes).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if outcome.shouldCopy(autoCopy: prefs.autoCopyOCR, silent: silent, text: copyText) { copy(copyText) }
            if showHUD {
                if outcome.succeeded { transientHUD.success(at: hudPosition, onClick: openOCR) }
                else { transientHUD.failure(at: hudPosition, onClick: openOCR) }
            }
            cleanTemporaryImages(except: imageURL)
        }
    }

    func recognize(urls: [URL], translateAfter: Bool, silent: Bool, overlay capture: CapturedRegion? = nil, append: Bool = false) {
        if !translateAfter, let delegate = AppDelegate.shared, self !== delegate.ocrState {
            delegate.ocrState.recognize(urls: urls, translateAfter: false, silent: silent, overlay: capture, append: append)
            return
        }
        if !translateAfter {
            recognizeOCRImages(urls: urls, silent: silent, append: append || continuousOCR)
            return
        }
        let appendedText = append && !translateAfter ? input : ""
        cancelTranslation()
        // Screen coordinates belong only to an explicitly captured region. External
        // files, clipboard data and dropped images always take the normal path.
        let overlayContext = capture.flatMap { captured in
            urls.count == 1 && urls[0] == captured.url ? ImageOverlayContext(capture: captured) : nil
        }
        results = []
        selectionDestination = nil
        canInsertResult = false
        currentHistoryID = nil
        let job = generation
        let prefs = preferences
        let ocrService = prefs.selectedOCRService(forTranslation: translateAfter)
        let inputPresentation = inputDisplayOverride ?? prefs.screenshotInputDisplay
        let showSilentHUD = silent && !translateAfter && !prefs.hideSilentOCRLoading && !(isWindowVisible?() ?? false)
        let hudPosition = NSEvent.mouseLocation
        let openOCR: () -> Void = { [weak self] in self?.mode = "ocr"; self?.onShowWindow?() }
        let previousImage = imageURL
        let managedCandidates = Set(urls + (previousImage.map { [$0] } ?? []))
        // REA 0x10028eb30 starts TranslateOCRView.titleView.loadingView before
        // the provider callback; 0x1000a6000 suppresses showing for silent OCR.
        // Present a fresh query now, not the previous result while OCR is pending.
        input = appendedText
        ocrDocument = nil
        imageURL = urls.count == 1 ? urls.first : nil
        imageTranslations = [:]
        imageOverlay = false
        recognizing = true
        recognizingService = ocrService
        working = true
        notice = nil
        if !silent {
            mode = translateAfter ? "translate" : "ocr"
            applyEntryPresentation(position: translateAfter ? prefs.selectionWindowPosition : prefs.ocrWindowPosition,
                                   inputDisplay: translateAfter ? inputPresentation : nil)
            queryRevision += 1
            onShowWindow?()
        }
        ocrTask = Task { [self] in
            defer { cleanTemporaryImages(candidates: managedCandidates, except: imageURL) }
            guard !Task.isCancelled, generation == job else { return }
            working = true
            notice = nil
            if showSilentHUD { transientHUD.loading(at: hudPosition, onClick: openOCR) }
            var documents: [OCRDocument] = []
            var successfulURLs: [URL] = []
            var failures: [String] = []
            for url in urls {
                if Task.isCancelled { break }
                do {
                    guard let service = ocrService else { throw PopError.message("请至少开启 1 个文本识别服务。") }
                    let document: OCRDocument
                    if service.kind != .apple {
                        let data = try Data(contentsOf: url)
                        if service.kind == .plugin { document = try await PluginService.shared.recognize(imageData: data, service: effectiveConfig(service)) }
                        else { document = try await CloudMediaService().recognize(imageData: data, service: service, apiKey: SecretStore.read(SecretStore.serviceKey(service.credentialID))) }
                    } else {
                        let options = ocrService?.options ?? [:]
                        let languages = options["languages"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        document = try await VisionOCR.recognize(url: url, accurate: options["accurate"].flatMap(Bool.init) ?? prefs.ocrAccurate,
                                                                 languages: languages?.isEmpty == false ? languages! : prefs.ocrLanguages,
                                                                 languageCorrection: options["languageCorrection"].flatMap(Bool.init) ?? prefs.ocrLanguageCorrection,
                                                                 recognizeQRCodes: prefs.recognizeQRCode)
                    }
                    documents.append(OCRDocument(text: document.text, lines: document.lines,
                                                 qrCodes: prefs.recognizeQRCode ? document.qrCodes : []))
                    successfulURLs.append(url)
                } catch { LocalDiagnostics.record("ocr_failed", error: error); failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            guard !Task.isCancelled, generation == job else { return }
            recognizing = false
            recognizingService = nil
            if let last = documents.last {
                LocalDiagnostics.record("ocr_completed")
                imageURL = successfulURLs.count == 1 ? successfulURLs.first : nil
                ocrDocument = last
                let paragraphMode = ocrService?.options["paragraphMode"] ?? (prefs.smartOCRParagraphs ? "smart" : "provider")
                let text = documents.map { $0.lines.isEmpty || paragraphMode == "provider" ? $0.text : OCRTextLayout.text(from: $0.lines, smartParagraphs: true) }.joined(separator: "\n\n")
                let recognizedText = text.isEmpty ? documents.flatMap(\.qrCodes).joined(separator: "\n") : text
                input = appendedText.isEmpty ? recognizedText : (recognizedText.isEmpty ? appendedText : appendedText + "\n\n" + recognizedText)
                imageTranslations = [:]
                imageOverlay = false
                let automaticallyCopy = translateAfter ? prefs.autoCopyTranslationOCR : prefs.autoCopyOCR
                if !recognizedText.isEmpty && (automaticallyCopy || (silent && !translateAfter)) { copy(input) }
                if let context = overlayContext, successfulURLs.count == 1 {
                    do {
                        try NativeImageOverlay.shared.show(capture: context.capture, document: last, translations: [:])
                        imageOverlayContext = context
                        NativeImageOverlay.shared.onClose = { [weak self] in
                            guard let self, self.imageOverlayContext?.id == context.id else { return }
                            self.imageOverlayContext = nil
                            NativeImageOverlay.shared.onClose = nil
                            self.cancelTranslation()
                        }
                        translateImage()
                    }
                    catch { presentImageTranslationError(error.localizedDescription, showWindow: true) }
                } else {
                    // The ordinary window is already visible. Do not refocus or
                    // reposition it when a slower OCR provider finishes.
                    if translateAfter && !silent { inputDisplayOverride = inputPresentation }
                    if translateAfter && !input.isEmpty { translate() }
                }
                if recognizedText.isEmpty { notice = "没有识别到文字或二维码。" }
            }
            if documents.isEmpty { imageURL = nil }
            if !failures.isEmpty {
                let message = failures.joined(separator: "\n")
                if overlayContext != nil { presentImageTranslationError(message, showWindow: true) }
                else {
                    notice = message
                }
            }
            if generation == job {
                working = results.contains { $0.loading }
                if showSilentHUD {
                    if failures.isEmpty && documents.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.qrCodes.isEmpty }) { transientHUD.success(at: hudPosition, onClick: openOCR) }
                    else { transientHUD.failure(at: hudPosition, onClick: openOCR) }
                }
            }
        }
    }

    func translateImage() {
        guard let document = ocrDocument, !document.lines.isEmpty else { presentImageTranslationError("请先识别一张包含文字的图片。"); return }
        guard let service = preferences.services.first(where: { $0.enabled && $0.capability == "translate" }) else {
            presentImageTranslationError("请先在设置中启用至少一项翻译服务。"); return
        }
        imageOverlay = true
        imageTranslations = [:]
        cancelTranslation(closeOverlay: false)
        working = true
        let job = generation
        if preferences.autoSpeakSource { speak(document.text) }
        let overlayID = imageOverlayContext?.id
        let request = TranslationRequest(text: document.text, source: preferences.sourceLanguage, target: TextUtilities.targetLanguage(for: document.text, preferences: preferences))
        if service.kind == .apple && overlayID == nil {
            systemImageBatch = true
            systemRequest = request
            systemJobID = job
            activateSystemTranslation(request)
        } else {
            remoteTask?.cancel()
            let effective = effectiveConfig(service)
            remoteTask = Task {
                guard generation == job, !Task.isCancelled else { return }
                working = true
                for (index, line) in document.lines.enumerated() {
                    guard generation == job, !Task.isCancelled else { break }
                    do {
                        let lineRequest = TranslationRequest(text: line.text, source: request.source, target: request.target)
                        let output = try await translateDirect(lineRequest, service: effective)
                        guard generation == job, !Task.isCancelled else { break }
                        imageTranslations[index] = output.text
                        if let overlayID, imageOverlayContext?.id == overlayID { NativeImageOverlay.shared.update(translations: imageTranslations) }
                    } catch is CancellationError { break }
                    catch { if generation == job { presentImageTranslationError(error.localizedDescription) }; break }
                }
                if generation == job { working = false }
            }
        }
    }

    func imageTranslationCompleted(_ values: [Int: String], error: String?, job: UUID, ticket: UUID) {
        guard generation == job, ticket == systemTicket else { return }
        imageTranslations = values
        if imageOverlayContext != nil { NativeImageOverlay.shared.update(translations: values) }
        notice = error
        working = false
    }

    private func closeOwnedImageOverlay() {
        guard imageOverlayContext != nil else { return }
        imageOverlayContext = nil
        NativeImageOverlay.shared.onClose = nil
        NativeImageOverlay.shared.close()
    }

    private func presentImageTranslationError(_ message: String, showWindow: Bool = false) {
        let wasLocated = imageOverlayContext != nil
        closeOwnedImageOverlay()
        notice = message
        working = false
        if wasLocated || showWindow { mode = "ocr"; onShowWindow?() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func copyResult(_ text: String) { copy(text); if preferences.closeAfterCopy { onCloseWindow?() } }
    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stopAudioPlayback(); return }
        let ticket = beginAudioPlayback()
        guard let service = preferences.selectedTTSService else { notice = "请至少开启 1 个语音合成服务。"; return }
        if service.kind != .apple {
            let config = effectiveConfig(service)
            let key = SecretStore.read(SecretStore.serviceKey(service.credentialID))
            audioTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    let data: Data
                    if config.kind == .plugin { data = try await PluginService.shared.synthesize(text: text, language: TextUtilities.detectLanguage(text), service: config) }
                    else { data = try await CloudMediaService().synthesize(text: text, language: TextUtilities.detectLanguage(text), service: config, apiKey: key) }
                    try Task.checkCancellation()
                    guard audioTicket == ticket else { return }
                    try playAudioData(data)
                } catch is CancellationError { }
                catch { if audioTicket == ticket { notice = error.localizedDescription } }
                if audioTicket == ticket { audioTask = nil }
            }
        } else {
            let language = TextUtilities.readingLanguageCode(TextUtilities.detectLanguage(text))
            let voices = service.options["voices"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            let base = String(language.split(separator: "-").first ?? Substring(language))
            let voiceID = voices[language] ?? voices[base]
            SpeechPlayer.shared.speak(text: text, language: language,
                                      rate: service.options["rate"].flatMap(Float.init), voiceID: voiceID)
        }
    }

    func playDictionaryAudio(audio: DictionaryResult.Audio?, word: String) {
        guard let audio else { speak(word); return }
        let ticket = beginAudioPlayback()
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await dictionaryAudioData(audio)
                try Task.checkCancellation()
                guard audioTicket == ticket else { return }
                try playAudioData(data)
            } catch is CancellationError { }
            catch { if audioTicket == ticket { notice = error.localizedDescription } }
            if audioTicket == ticket { audioTask = nil }
        }
    }

    private func beginAudioPlayback() -> UUID {
        if let previous = Self.audioOwner, previous !== self { previous.stopAudioPlayback() }
        stopAudioPlayback()
        Self.audioOwner = self
        return audioTicket
    }

    private func stopAudioPlayback() {
        audioTicket = UUID()
        audioTask?.cancel(); audioTask = nil
        audioPlayer?.stop(); audioPlayer = nil
        if Self.audioOwner === self { SpeechPlayer.shared.stop(); Self.audioOwner = nil }
    }

    private func playAudioData(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw PopError.message("语音数据为空或超过 16 MB。") }
        let player = try AVAudioPlayer(data: data)
        guard player.prepareToPlay(), player.play() else { throw PopError.message("无法播放返回的语音数据。") }
        audioPlayer = player
    }

    private func dictionaryAudioData(_ audio: DictionaryResult.Audio) async throws -> Data {
        try Task.checkCancellation()
        let maximum = 8 * 1024 * 1024
        switch audio.type.lowercased() {
        case "base64":
            var value = audio.value
            guard value.utf8.count <= 12 * 1024 * 1024 else { throw PopError.message("词典语音超过 8 MB。") }
            if value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") {
                guard value[..<comma].lowercased().contains(";base64") else { throw PopError.message("词典语音的 data URL 不是 base64 格式。") }
                value = String(value[value.index(after: comma)...])
            }
            guard let data = Data(base64Encoded: value), !data.isEmpty, data.count <= maximum else {
                throw PopError.message("词典 base64 语音无效或超过 8 MB。")
            }
            return data
        case "url":
            guard let parts = URLComponents(string: audio.value),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.user == nil, parts.password == nil,
                  let host = parts.host, !host.isEmpty, let url = parts.url else {
                throw PopError.message("词典语音仅支持有效的 HTTP 或 HTTPS 地址。")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = NetworkProxy.makeSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.timeoutInterval = 20
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  ["http", "https"].contains(response.url?.scheme?.lowercased() ?? ""),
                  (200...299).contains(response.statusCode) else { throw PopError.message("获取词典语音失败，请检查语音地址或稍后重试。") }
            guard response.expectedContentLength <= maximum else { throw PopError.message("词典语音超过 8 MB。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximum else { throw PopError.message("词典语音超过 8 MB。") }
                data.append(byte)
            }
            guard !data.isEmpty else { throw PopError.message("词典语音返回空数据。") }
            return data
        default: throw PopError.message("不支持的词典语音类型：\(audio.type)。")
        }
    }
    func setPinned(_ value: Bool) {
        pinned = value
        if windowRole == "ocr" { preferences.ocrPinned = value } else { preferences.translationPinned = value }
        savePreferences(); onPinChange?(value)
    }
    func toggleServicePinned(_ id: UUID) {
        guard let service = preferences.services.first(where: { $0.id == id && $0.capability == "translate" }) else { return }
        let current = service.triggerStrategy(legacyPinned: preferences.pinnedServiceIDs.contains(id))
        setServiceTriggerStrategy(id, strategy: current == .pinned ? .normal : .pinned)
    }
    func setServiceTriggerStrategy(_ id: UUID, strategy: ServiceTriggerStrategy, persist: Bool = true) {
        guard let index = preferences.services.firstIndex(where: { $0.id == id && $0.capability == "translate" }) else { return }
        preferences.services[index].options["triggerStrategy"] = strategy.rawValue
        preferences.pinnedServiceIDs.removeAll { $0 == id }
        if strategy == .pinned { preferences.pinnedServiceIDs.append(id) }
        if strategy == .normal { preferences.collapsedServiceIDs.removeAll { $0 == id } }
        if strategy == .alwaysCollapsed, !preferences.collapsedServiceIDs.contains(id) { preferences.collapsedServiceIDs.append(id) }
        if persist { savePreferences() }
    }
    func toggleServiceCollapsed(_ id: UUID, persist: Bool = true) {
        let opening = preferences.collapsedServiceIDs.contains(id)
        if opening { preferences.collapsedServiceIDs.removeAll { $0 == id } }
        else { preferences.collapsedServiceIDs.append(id) }
        if persist { savePreferences() }
        if opening, results.contains(where: { $0.serviceID == id && $0.deferred }) {
            translateService(id)
        }
    }
    @discardableResult func moveService(_ source: UUID, before target: UUID) -> Bool {
        guard source != target,
              let from = preferences.services.firstIndex(where: { $0.id == source }),
              let to = preferences.services.firstIndex(where: { $0.id == target }),
              preferences.services[from].capability == preferences.services[to].capability else { return false }
        let value = preferences.services.remove(at: from)
        guard let insertion = preferences.services.firstIndex(where: { $0.id == target }) else { return false }
        preferences.services.insert(value, at: insertion)
        savePreferences(); return true
    }

    func saveHistory() { do { try HistoryRepository.shared.replace(history, limit: preferences.historyLimit) } catch { notice = error.localizedDescription } }
    func loadHistory(_ item: HistoryItem) {
        cancelTranslation()
        currentHistoryID = item.id
        input = item.source
        preferences.sourceLanguage = item.sourceLanguage
        preferences.targetLanguage = item.targetLanguage
        results = item.results.map { ResultCard(serviceID: UUID(), name: $0.key, text: $0.value, loading: false) }
        mode = "translate"
        onShowWindow?()
    }

    func clearInput() {
        cancelTranslation()
        input = ""
        selectionDestination = nil
        canInsertResult = false
        currentHistoryID = nil
        results = []
        ocrDocument = nil
        ocrImages = OCRImageCollection()
        lastOCRBatchOutcome = nil
        imageURL = nil
        imageTranslations = [:]
        closeOwnedImageOverlay()
        cleanTemporaryImages(except: nil)
    }

    func cleanup() {
        cancelTranslation()
        stopAudioPlayback()
        closeOwnedImageOverlay()
        ocrImages = OCRImageCollection()
        lastOCRBatchOutcome = nil
        cleanTemporaryImages(except: nil)
    }

    func dismissWindow() {
        cancelTranslation()
        onCloseWindow?()
    }

    private func cleanTemporaryImages(candidates: Set<URL>? = nil, except retained: URL?) {
        let retainedOCRImages = Set(ocrImages.tasks.map(\.url))
        for url in temporaryImages.filter({ $0 != retained && !retainedOCRImages.contains($0) && (candidates == nil || candidates!.contains($0)) }) {
            try? FileManager.default.removeItem(at: url)
            temporaryImages.remove(url)
        }
    }
    func toggleFavorite(_ id: UUID) { if let i = history.firstIndex(where: { $0.id == id }) { history[i].favorite.toggle(); saveHistory() } }
    var currentTranslationFavorite: Bool { history.first(where: { $0.id == currentHistoryID })?.favorite ?? false }
    func favoriteCurrentTranslation() {
        if let id = currentHistoryID { toggleFavorite(id); return }
        guard !input.isEmpty else { notice = "当前没有可收藏的内容。"; return }
        let values = results.reduce(into: [String: String]()) { if !$1.text.isEmpty { $0[$1.name] = $1.text } }
        var item = HistoryItem(source: input, sourceLanguage: preferences.sourceLanguage, targetLanguage: preferences.targetLanguage, results: values)
        item.favorite = true; history.insert(item, at: 0); currentHistoryID = item.id; saveHistory()
    }
    func insertResult(_ text: String) {
        guard let destination = selectionDestination else { notice = "没有可回填的原文位置。"; return }
        do { try destination.replace(with: text); lastReplacement = destination; canUndoReplacement = true; onCloseWindow?() }
        catch { notice = error.localizedDescription }
    }

    func undoReplacement() {
        guard let destination = lastReplacement else { return }
        do { try destination.undo(); lastReplacement = nil; canUndoReplacement = false; notice = "已恢复替换前的文字。" }
        catch { notice = error.localizedDescription }
    }

    func silentTranslate(entireInput: Bool) {
        cancelTranslation()
        let job = generation
        do {
            let destination: SelectionDestination
            do { destination = try SelectionDestination.capture(scope: entireInput ? .entireInput : .selection) }
            catch {
                if !entireInput, preferences.hideSelectionError { return }
                throw error
            }
            let text = TextUtilities.processedInput(destination.originalText, preferences: preferences)
            guard !text.isEmpty else { throw PopError.message("没有可翻译的文字。") }
            let chosen = preferences.services.first { $0.id == preferences.silentServiceID && $0.enabled && $0.capability == "translate" }
                ?? preferences.services.first { $0.enabled && $0.capability == "translate" && $0.triggerStrategy(legacyPinned: preferences.pinnedServiceIDs.contains($0.id)) != .pinned }
            guard let chosen else { throw PopError.message("请先启用翻译服务。") }
            let request = TranslationRequest(text: text, source: preferences.sourceLanguage, target: TextUtilities.targetLanguage(for: text, preferences: preferences), originalText: destination.originalText)
            let service = effectiveConfig(chosen)
            working = true
            onCloseWindow?()
            if preferences.autoSpeakSource { speak(text) }
            remoteTask = Task {
                do {
                    let output = try await translateDirect(request, service: service)
                    try Task.checkCancellation()
                    guard job == generation else { return }
                    try destination.replace(with: output.text, requireOriginalAppInFront: true)
                    lastReplacement = destination; canUndoReplacement = true
                    if preferences.saveHistory {
                        history.insert(HistoryItem(source: destination.originalText, sourceLanguage: request.source, targetLanguage: request.target, results: [service.name: output.text]), at: 0)
                        history = Array(history.prefix(preferences.historyLimit)); saveHistory()
                    }
                    notice = "翻译已回填，可从菜单撤销上次回填。"
                } catch is CancellationError { }
                catch { if job == generation { notice = error.localizedDescription; onShowWindow?() } }
                if job == generation { working = false }
            }
        } catch { notice = error.localizedDescription; onShowWindow?() }
    }

    func translateDirect(_ request: TranslationRequest, service: ServiceConfig) async throws -> TranslationOutput {
        try Task.checkCancellation()
        let job = generation
        guard service.enabled else { throw PopError.message("该翻译服务已停用，请先在设置中启用。") }
        if service.kind != .apple { return try await translateNonSystem(request, service: effectiveConfig(service)) }
        let detected = request.source == "auto" ? TextUtilities.detectLanguage(request.text) : request.source
        if sameLanguage(detected, request.target) { return TranslationOutput(text: request.text, detectedSource: detected) }
        guard #available(macOS 26.0, *), detected != "auto", detected != "und" else {
            throw PopError.message("当前系统的静默系统翻译需要 macOS 26 或更新版本；可选择云端服务，或使用普通翻译窗口。")
        }
        let source = Locale.Language(identifier: detected), target = Locale.Language(identifier: request.target)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw PopError.message("请先在普通翻译窗口下载这组系统语言模型，再使用静默翻译。")
        }
        try await awaitSystemCooldown(job: job, service: service)
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(request.text)
        return TranslationOutput(text: response.targetText, detectedSource: detected)
    }

    /// Used by normal queries, individual-card retries, silent replacement and
    /// image translation. Local services never read credentials or enter HTTP.
    private func translateNonSystem(_ request: TranslationRequest, service: ServiceConfig,
                                    onStream: (@Sendable (TranslationOutput) -> Void)? = nil) async throws -> TranslationOutput {
        try Task.checkCancellation()
        guard service.enabled, service.capability == "translate" else {
            throw PopError.message("该翻译服务已停用，或不支持文本翻译。")
        }
        if service.kind == .dictionary {
            guard NativeDictionary.bundledEntryCount > 0 else {
                throw PopError.message("简明英汉词典资源缺失或损坏，请重新安装 Pop。")
            }
            let result = await NativeDictionary.lookupBundledResult(request.text)
            try Task.checkCancellation()
            guard let result else {
                throw PopError.message("未找到对应词条。此词典用于中英文单词和词组查询；如需翻译句子，请使用其他翻译服务。")
            }
            return TranslationOutput(text: result.plainText, dictionary: result)
        }
        if service.kind == .plugin { return try await PluginService.shared.translate(request, service: service, onStream: onStream) }
        return try await http.translate(request, service: service,
                                        apiKey: SecretStore.read(SecretStore.serviceKey(service.credentialID)), onStream: onStream)
    }

    func captureImageTranslation() {
        NativeImageOverlay.shared.close()
        cancelTranslation()
        let ticket = generation
        continuousOCR = false
        onCloseWindow?()
        acquisitionTask = Task {
            do {
                let capture = try await NativeScreenshot.captureLocatedRegion()
                guard !Task.isCancelled, generation == ticket else { try? FileManager.default.removeItem(at: capture.url); return }
                acquisitionTask = nil
                temporaryImages.insert(capture.url)
                recognize(urls: [capture.url], translateAfter: true, silent: true, overlay: capture)
            } catch is CancellationError { }
            catch { if generation == ticket { notice = error.localizedDescription; onShowWindow?() } }
        }
    }

    func recognizeImageData(_ data: Data, translate: Bool, silent: Bool) throws {
        if !translate, let delegate = AppDelegate.shared, self !== delegate.ocrState {
            try delegate.ocrState.recognizeImageData(data, translate: false, silent: silent)
            return
        }
        guard data.count <= 32 * 1024 * 1024, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
            throw PopError.message("图片无效或超过 32 MB。")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-script-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        temporaryImages.insert(url)
        recognize(urls: [url], translateAfter: translate, silent: silent)
    }

    func recognizeClipboard(silent: Bool = false) {
        if let delegate = AppDelegate.shared, self !== delegate.ocrState {
            delegate.ocrState.recognizeClipboard(silent: silent)
            return
        }
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) else {
            notice = "剪贴板里没有图片。"; if !silent { onShowWindow?() }; return
        }
        do { try recognizeImageData(data, translate: false, silent: silent) }
        catch { notice = error.localizedDescription; onShowWindow?() }
    }
    func translateClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            selectionDestination = nil; canInsertResult = false
            input = text; mode = "translate"; onShowWindow?(); translate()
        } else if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff),
                  let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-clipboard-\(UUID().uuidString).png")
                try png.write(to: url); temporaryImages.insert(url)
                recognize(urls: [url], translateAfter: true, silent: false)
            } catch { notice = error.localizedDescription }
        } else { notice = "剪贴板中没有可翻译的文字或图片。" }
    }
    var filteredHistory: [HistoryItem] {
        history.filter { (!favoritesOnly || $0.favorite) && (historySearch.isEmpty || $0.source.localizedCaseInsensitiveContains(historySearch) || $0.results.values.contains { $0.localizedCaseInsensitiveContains(historySearch) }) }
    }

    func effectiveConfig(_ config: ServiceConfig) -> ServiceConfig {
        var copy = config
        if config.kind == .plugin,
           let plugin = PluginService.shared.listPlugins().first(where: { $0.id == config.pluginID }) {
            for option in plugin.options where option.isSecure {
                copy.options[option.identifier] = SecretStore.read(SecretStore.pluginKey(config.credentialID, option: option.identifier))
            }
        }
        return copy
    }

    func exportConfiguration() {
        let alert = NSAlert()
        alert.messageText = "重要提示"
        alert.informativeText = "导出的设置包含所有偏好设置及插件，不包含翻译历史和收藏夹。系统钥匙串中的 API 密钥及代理密码不会导出。"
        alert.addButton(withTitle: "继续导出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pop配置.popconfig"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let export = ConfigurationExport(preferences: preferences, shortcuts: shortcuts,
                                             plugins: try PortableBackup.collectPlugins(at: PluginService.shared.rootURL))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: url, options: .atomic)
            notice = "设置及插件已导出；钥匙串中的密钥未导出。"
        } catch { notice = error.localizedDescription }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Pop完整备份.popbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try makeBackup()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(backup).write(to: url, options: .atomic)
            notice = "已备份设置、快捷键、历史、收藏及插件；钥匙串凭据不包含在内。"
        } catch { notice = error.localizedDescription }
    }
    private func makeBackup() throws -> PortableBackup {
        PortableBackup(configuration: ConfigurationExport(preferences: preferences, shortcuts: shortcuts), history: history,
                       plugins: try PortableBackup.collectPlugins(at: AppStorage.directory.appendingPathComponent("Plugins")))
    }
    @discardableResult private func saveRestorePoint() throws -> URL {
        let directory = AppStorage.directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let url = directory.appendingPathComponent("before-import-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).popbackup")
        try encoder.encode(makeBackup()).write(to: url, options: .atomic)
        return url
    }
    func importBackup(url: URL? = nil) {
        let selected: URL
        if let url { selected = url } else {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }; selected = url
        }
        do {
            let size = try selected.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1024 * 1024 else { throw PopError.message("备份文件超过 256 MB。") }
            let backup = try JSONDecoder().decode(PortableBackup.self, from: Data(contentsOf: selected))
            try PortableBackup.validate(backup)
            try withDataImport {
                let restorePoint = try saveRestorePoint()
                let transaction = try ImportFileTransaction(rootURL: AppStorage.directory, portableRecoveryURL: restorePoint)
                let importedHistory = Array(backup.history.prefix(max(100, min(100000, backup.configuration.preferences.historyLimit))))
                try transaction.perform {
                    try backup.restorePlugins(at: PluginService.shared.rootURL)
                    try AppStorage.save(backup.configuration.preferences, file: "preferences.json")
                    try AppStorage.save(backup.configuration.shortcuts, file: "shortcuts.json")
                    try AppStorage.save(importedHistory, file: "history.json")
                }
                ConfigurationRepository.shared.publishPersisted(preferences: backup.configuration.preferences, shortcuts: backup.configuration.shortcuts)
                HistoryRepository.shared.publishPersisted(importedHistory)
            }
            applyAppearance(); onShortcutsChanged?()
            notice = "完整备份已恢复；导入前的副本保存在数据目录 Backups 中。服务凭据请在设置中补充。"
        } catch { notice = error.localizedDescription }
    }
    func importHistory() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw PopError.message("历史文件过大。") }
            let items = try JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: url))
            try saveRestorePoint()
            var known = Set(history.map(\.id))
            history += items.filter { known.insert($0.id).inserted }
            history.sort { $0.date > $1.date }
            history = Array(history.prefix(preferences.historyLimit))
            try HistoryRepository.shared.replace(history, limit: preferences.historyLimit)
            notice = "已合并导入历史和收藏。"
        } catch { notice = error.localizedDescription }
    }
    func importConfiguration(url: URL? = nil) {
        var selected = url
        if selected == nil {
            let alert = NSAlert(); alert.messageText = "重要提示"
            alert.informativeText = "导入将替换偏好设置，以及文件中包含的插件。翻译历史和收藏夹不变。导入前会保留可恢复的副本。"
            alert.addButton(withTitle: "选择设置文件"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return }; selected = panel.url
        }
        guard let selected else { return }
        do {
            guard (try selected.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1024 * 1024 else { throw PopError.message("设置文件超过 256 MB。") }
            let item = try JSONDecoder().decode(ConfigurationExport.self, from: Data(contentsOf: selected))
            guard ["PopConfiguration", "YibanConfiguration"].contains(item.format), item.version == 1 else { throw PopError.message("不支持的配置格式。") }
            let pluginBackup = item.plugins.map { PortableBackup(configuration: item, history: [], plugins: $0) }
            if let pluginBackup { try PortableBackup.validate(pluginBackup) }
            try withDataImport {
                let restorePoint = try saveRestorePoint()
                let transaction = try ImportFileTransaction(rootURL: AppStorage.directory, portableRecoveryURL: restorePoint)
                try transaction.perform {
                    if let pluginBackup { try pluginBackup.restorePlugins(at: PluginService.shared.rootURL) }
                    try AppStorage.save(item.preferences, file: "preferences.json")
                    try AppStorage.save(item.shortcuts, file: "shortcuts.json")
                }
                ConfigurationRepository.shared.publishPersisted(preferences: item.preferences, shortcuts: item.shortcuts)
            }
            applyAppearance(); onShortcutsChanged?(); notice = "设置及文件中的插件已导入。服务密钥请在设置中补充。"
        } catch { notice = error.localizedDescription }
    }

    private func withDataImport(_ operation: () throws -> Void) throws {
        try DataImportCoordinator.withExclusiveAccess {
            // Invalidate every window before cancellation can pump the main run
            // loop, preventing an old completion from saving history mid-import.
            for state in Self.liveStates.allObjects { state.cancelTranslation() }
            PluginService.shared.cancelAllExecutions()
            try operation()
        }
    }

    func removeConfiguredPlugin(_ plugin: PluginDescriptor) throws {
        let references = preferences.services.filter { $0.kind == .plugin && $0.pluginID == plugin.id }
        guard !references.contains(where: \.enabled) else { throw PopError.message("插件仍有已开启的服务，请先停用相关服务。") }
        guard PluginService.shared.listPlugins().contains(where: { $0.id == plugin.id && $0.path == plugin.path }) else {
            throw PopError.message("插件已更改，请刷新插件列表。")
        }
        let previousPreferences = preferences
        let previousShortcuts = shortcuts
        let restorePoint = try saveRestorePoint()
        let manager = FileManager.default
        let archived = AppStorage.directory.appendingPathComponent("Backups/RemovedPlugins/" + UUID().uuidString)
        try manager.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        PluginService.shared.cancelExecutions(pluginID: plugin.id)
        try manager.moveItem(at: plugin.path, to: archived)
        do {
            var next = preferences
            let removedIDs = Set(references.map(\.id))
            next.services.removeAll { removedIDs.contains($0.id) }
            next.pinnedServiceIDs.removeAll { removedIDs.contains($0) }
            next.collapsedServiceIDs.removeAll { removedIDs.contains($0) }
            try ConfigurationRepository.shared.save(preferences: next, shortcuts: shortcuts)
        } catch {
            var recoveryFailures: [String] = []
            do { try manager.moveItem(at: archived, to: plugin.path) }
            catch { recoveryFailures.append("插件文件：" + error.localizedDescription) }
            // Repository.save writes preferences before shortcuts; failure of the
            // second write must also restore the already-written preferences.
            do { try ConfigurationRepository.shared.save(preferences: previousPreferences, shortcuts: previousShortcuts) }
            catch { recoveryFailures.append("服务设置：" + error.localizedDescription) }
            if !recoveryFailures.isEmpty {
                throw PopError.message(error.localizedDescription + "\n自动恢复未完成：" + recoveryFailures.joined(separator: "；") + "\n删除前的完整备份：" + restorePoint.path)
            }
            throw error
        }
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != "auto", lhs != "und", !lhs.isEmpty else { return false }
        let left = Locale.Language(identifier: lhs)
        let right = Locale.Language(identifier: rhs)
        guard left.languageCode == right.languageCode else { return false }
        if let script = left.script, let other = right.script, script != other { return false }
        return true
    }
}
