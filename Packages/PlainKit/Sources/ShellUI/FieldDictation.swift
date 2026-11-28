#if canImport(UIKit)
import AVFoundation
import BrowserCore
import os
import PerfSignposts
import Speech
import UIKit

/// Dictation into the search field from its microphone (Arc Search's field has one). Speech is
/// recognised on the phone only (`requiresOnDeviceRecognition`): nothing spoken leaves it. Where
/// the phone can't do that in the user's language, there is no microphone in the field, and the
/// keyboard's own dictation key remains.
///
/// The system asks for the microphone and for speech recognition the first time, on the tap.
@MainActor
final class FieldDictation {
    /// The phone can recognise speech on the device. Checked once, off the main thread.
    private(set) var isAvailable = false
    private(set) var isListening = false
    /// `isAvailable` or `isListening` changed.
    var onChange: () -> Void = {}
    /// What was heard so far, replacing what was heard before.
    var onText: (String) -> Void = { _ in }

    /// The one audio pipeline: its serial queue orders every start after the stop before it.
    private let audio = Audio()
    private var generation = 0
    private var quiet: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: Signposts.subsystem, category: "dictation")

    /// Finds out whether dictation can run here, away from the main thread and from any tap.
    func prepare() {
        #if DEBUG
        // UI tests and captures: a microphone that "hears" a fixed phrase, with no audio.
        if ProcessInfo.processInfo.arguments.contains("-PlainTestDictation") {
            isAvailable = true
            return
        }
        #endif
        Task.detached(priority: .utility) { [weak self] in
            let supported = SFSpeechRecognizer()?.supportsOnDeviceRecognition == true
            await MainActor.run {
                guard let self, supported != self.isAvailable else { return }
                self.isAvailable = supported
                self.onChange()
            }
        }
    }

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard isAvailable, !isListening else { return }
        generation += 1
        let run = generation
        isListening = true
        onChange()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PlainTestDictation") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.generation == run, self.isListening else { return }
                self.onText("plain browser")
                self.stop()
            }
            return
        }
        #endif
        Task { [weak self] in
            guard await Self.askPermission() else {
                self?.finish(run)
                return
            }
            guard let self, self.generation == run, self.isListening else { return }
            // Submitted from the main actor, in order with any stop: the queue runs them as asked.
            self.audio.start(onResult: { [weak self] text, isFinal in
                Task { @MainActor in
                    guard let self, self.generation == run, self.isListening else { return }
                    if let text { self.heard(text, run: run) }
                    if isFinal { self.finish(run) }
                }
            }, completion: { [weak self] started in
                Task { @MainActor in
                    guard let self, self.generation == run, self.isListening else { return }
                    guard started else { return self.finish(run) }
                    // Silence from the start ends it too.
                    self.armQuietEnd(run)
                }
            })
        }
    }

    /// Stops listening; what was heard stays in the field.
    func stop() {
        guard isListening else { return }
        finish(generation)
    }

    private func heard(_ text: String, run: Int) {
        onText(text)
        armQuietEnd(run)
    }

    /// A pause ends it, as the keyboard's dictation does.
    private func armQuietEnd(_ run: Int) {
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: FixedChoices.dictationQuietEnd)
            guard !Task.isCancelled else { return }
            self?.finish(run)
        }
    }

    private func finish(_ run: Int) {
        guard run == generation, isListening else { return }
        generation += 1
        quiet?.cancel()
        quiet = nil
        isListening = false
        audio.stop()
        onChange()
    }

    nonisolated private static func askPermission() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// The audio engine and the recogniser, kept off the main thread: starting the audio session
    /// and the engine can take tens of milliseconds.
    nonisolated private final class Audio: @unchecked Sendable {
        private let queue = DispatchQueue(label: "plain.dictation")
        /// Made on the queue, at the first start: building the engine touches the audio hardware.
        private var engine: AVAudioEngine?
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?

        func start(
            onResult: @escaping @Sendable (String?, Bool) -> Void, completion: @escaping @Sendable (Bool) -> Void
        ) {
            do {
                queue.async { [self] in
                    // A run that was not torn down (a start right after a start) goes first.
                    tearDown()
                    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                        return completion(false)
                    }
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                        try session.setActive(true, options: .notifyOthersOnDeactivation)
                        let request = SFSpeechAudioBufferRecognitionRequest()
                        request.requiresOnDeviceRecognition = true
                        request.shouldReportPartialResults = true
                        request.taskHint = .search
                        let engine = AVAudioEngine()
                        self.engine = engine
                        let input = engine.inputNode
                        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                            request.append(buffer)
                        }
                        engine.prepare()
                        try engine.start()
                        self.request = request
                        task = recognizer.recognitionTask(with: request) { result, error in
                            let text = result?.bestTranscription.formattedString
                            onResult(text, error != nil || result?.isFinal == true)
                        }
                        completion(true)
                    } catch {
                        FieldDictation.logger.error("dictation did not start: \(error.localizedDescription, privacy: .public)")
                        tearDown()
                        completion(false)
                    }
                }
            }
        }

        func stop() {
            queue.async { [self] in tearDown() }
        }

        private func tearDown() {
            guard let engine else { return }
            self.engine = nil
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
#endif
