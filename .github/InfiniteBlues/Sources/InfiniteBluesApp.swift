import SwiftUI
import AVFoundation
import MediaPlayer
import Accelerate

@main
struct InfiniteBluesApp: App {
    @StateObject private var audio = AudioController()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .onAppear { audio.configureRemoteCommands() }
        }
    }
}

enum SubGenre: String, CaseIterable, Identifiable {
    case srv = "SRV – Little Wing"
    case kingfish = "Kingfish – Empty Promises"
    case marcus = "Marcus King – Confessions"
    case taj = "Taj Farrant – Ain’t No Sunshine"
    var id: String { rawValue }
}

struct SessionState {
    var isPlaying = false
    var tempoBPM: Double = 84
    var swing: Double = 0.60
    var keyIndex: Int = 0 // 0..11 (C..B)
    var subGenre: SubGenre = .srv
    var chorusIndex: Int = 1
}

final class AudioController: ObservableObject {
    @Published var state = SessionState()

    private let engine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()
    private var sourceNode: AVAudioSourceNode!

    private var synth = SoloSynth()
    private var sampleRate: Double = 44100
    private var barTimer: DispatchSourceTimer?

    init() {
        setupEngine()
        setupNotifications()
    }

    private func setupEngine() {
        let hw = engine.outputNode
        let format = hw.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let buf = abl.first, let ptr = buf.mData?.assumingMemoryBound(to: Float.self) {
                self.synth.render(frames: Int(frameCount), to: ptr, channels: Int(buf.mNumberChannels))
                for b in abl.dropFirst() {
                    if let dst = b.mData?.assumingMemoryBound(to: Float.self) {
                        dst.assign(from: ptr, count: Int(frameCount))
                    }
                }
            }
            return noErr
        }

        engine.attach(mainMixer)
        engine.attach(sourceNode)
        let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        engine.connect(sourceNode, to: mainMixer, format: srcFormat)
        engine.connect(mainMixer, to: engine.outputNode, format: format)
        mainMixer.outputVolume = 0.95
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func configureRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let s = self else { return .commandFailed }
            s.state.isPlaying ? s.pause() : s.play(); return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.nextChorus(); return .success }
    }

    func play() {
        activateSessionIfNeeded()
        if !engine.isRunning { try? engine.start() }
        synth.isMuted = false
        synth.apply(style: state.subGenre, keyIndex: state.keyIndex, tempo: state.tempoBPM, swing: state.swing, sampleRate: sampleRate)
        startBarScheduler()
        state.isPlaying = true
        updateNowPlaying(rate: 1.0)
    }

    func pause() {
        synth.isMuted = true
        stopBarScheduler()
        state.isPlaying = false
        updateNowPlaying(rate: 0.0)
    }

    func nextChorus() {
        state.chorusIndex += 1
        synth.bumpEnergy()
        updateNowPlaying(rate: state.isPlaying ? 1.0 : 0.0)
    }

    func updateParams() {
        synth.apply(style: state.subGenre, keyIndex: state.keyIndex, tempo: state.tempoBPM, swing: state.swing, sampleRate: sampleRate)
        updateNowPlaying(rate: state.isPlaying ? 1.0 : 0.0)
    }

    private func activateSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func updateNowPlaying(rate: Float) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Infinite Blues – \(state.subGenre.rawValue)",
            MPMediaItemPropertyArtist: "Generative Band",
            MPMediaItemPropertyAlbumTitle: "Infinite Session",
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
        ]
        info[MPMediaItemPropertyComposer] = "Key: \(Keys.names[state.keyIndex]) • Tempo: \(Int(state.tempoBPM)) BPM • Chorus: \(state.chorusIndex)"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startBarScheduler() {
        stopBarScheduler()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let secondsPerBeat = 60.0 / state.tempoBPM
        let secondsPerBar = 4.0 * secondsPerBeat
        timer.schedule(deadline: .now() + secondsPerBar, repeating: secondsPerBar)
        timer.setEventHandler { [weak self] in self?.synth.onBarBoundary() }
        timer.resume(); barTimer = timer
    }
    private func stopBarScheduler() { barTimer?.cancel(); barTimer = nil }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .began { pause() }
        else if type == .ended, state.isPlaying { play() }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        if state.isPlaying, !engine.isRunning { try? engine.start() }
    }
}

enum Keys {
    static let names = ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]
    static func minorPentatonic(_ keyIndex: Int) -> [Int] {
        return [0,3,5,7,10].map { (keyIndex + $0) % 12 }
    }
}

final class SoloSynth {
    private var tempoBPM: Double = 84
    private var swing: Double = 0.60
    private var scale: [Int] = Keys.minorPentatonic(0)
    private var sampleRate: Double = 44100
    var isMuted: Bool = true

    private var phase: Double = 0
    private var currentFreq: Double = 440
    private var targetFreq: Double = 440
    private var vibratoPhase: Double = 0
    private var noteFramesRemaining: Int = 0
    private var framesPerBeat: Int = 44100

    private var env: Envelope = .init(a: 0.005, d: 0.08, s: 0.7, r: 0.06)
    private var envLevel: Double = 0
    private var envState: EnvState = .idle

    private var drive: Double = 0.9
    private var vibratoRate: Double = 5.8
    private var vibratoDepthCents: Double = 9
    private var bendTargetCents: Double = 0
    private var bendFramesRemaining: Int = 0

    private var rng = SeededGenerator(seed: 0xDEADBEEF)

    func apply(style: SubGenre, keyIndex: Int, tempo: Double, swing: Double, sampleRate: Double) {
        self.tempoBPM = tempo
        self.swing = swing
        self.sampleRate = sampleRate
        self.framesPerBeat = Int(sampleRate * 60.0 / tempo)
        self.scale = Keys.minorPentatonic(keyIndex)
        switch style {
        case .srv: drive = 0.95; vibratoDepthCents = 7; vibratoRate = 6.2
        case .kingfish: drive = 1.05; vibratoDepthCents = 11; vibratoRate = 6.0
        case .marcus: drive = 0.85; vibratoDepthCents = 6; vibratoRate = 5.2
        case .taj: drive = 0.80; vibratoDepthCents = 10; vibratoRate = 5.6
        }
    }

    func bumpEnergy() { vibratoDepthCents = min(18, vibratoDepthCents + 1); drive = min(1.2, drive + 0.03) }
    func onBarBoundary() { if Bool.random(using: &rng) { scheduleNote(lengthBeats: 1.5, bigBend: true) } }

    func render(frames: Int, to out: UnsafeMutablePointer<Float>, channels: Int) {
        if isMuted {
            // zero out
            for i in 0..<frames { out[i] = 0 }
            return
        }
        let twoPi = 2.0 * Double.pi
        for i in 0..<frames {
            if noteFramesRemaining <= 0 {
                let lenBeats = [0.5, 0.5, 1.0, 1.0, 1.5, 2.0].randomElement(using: &rng)!
                scheduleNote(lengthBeats: lenBeats, bigBend: false)
                noteFramesRemaining = Int(Double(framesPerBeat) * lenBeats)
            }
            let glideCoeff = 0.0025
            currentFreq += (targetFreq - currentFreq) * glideCoeff
            if bendFramesRemaining > 0 {
                let bendStep = bendTargetCents / Double(bendFramesRemaining)
                currentFreq *= pow(2.0, bendStep / 1200.0)
                bendFramesRemaining -= 1
            }
            vibratoPhase += vibratoRate / sampleRate
            let vib = sin(twoPi * vibratoPhase) * vibratoDepthCents
            let freq = currentFreq * pow(2.0, vib / 1200.0)
            let pickAccent = (i % (framesPerBeat/2 + 1) == 0) ? 1.08 : 1.0
            phase += freq / sampleRate; if phase >= 1.0 { phase -= 1.0 }
            let tri = 2.0 * abs(2.0 * (phase - floor(phase + 0.5))) - 1.0
            let shaped = tanh(tri * drive * 2.6)
            switch envState {
            case .idle: envLevel = 0
            case .attack:
                envLevel += 1.0 / (env.a * sampleRate)
                if envLevel >= 1.0 { envLevel = 1.0; envState = .decay }
            case .decay:
                envLevel -= (1.0 - env.s) / (env.d * sampleRate)
                if envLevel <= env.s { envLevel = env.s; envState = .sustain }
            case .sustain: envLevel = env.s
            case .release:
                envLevel -= env.s / (env.r * sampleRate)
                if envLevel <= 0 { envLevel = 0; envState = .idle }
            }
            let sample = Float(shaped * envLevel * pickAccent * 0.35)
            out[i] = sample
            noteFramesRemaining -= 1
            if noteFramesRemaining <= 0 && envState != .release { envState = .release }
        }
    }

    private func scheduleNote(lengthBeats: Double, bigBend: Bool) {
        let degree = scale.randomElement(using: &rng) ?? 0
        let midiRoot = 45 // A2 baseline
        let midi = midiRoot + degree + Int.random(in: 12...19, using: &rng) // mid-neck
        let freq = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
        targetFreq = freq
        envState = .attack
        if bigBend || Bool.random(using: &rng) {
            bendTargetCents = [100.0, 150.0, 200.0].randomElement(using: &rng)!
            bendFramesRemaining = Int(Double(framesPerBeat) * 0.5)
        } else { bendTargetCents = 0; bendFramesRemaining = 0 }
        noteFramesRemaining = Int(Double(framesPerBeat) * lengthBeats)
    }
}

struct Envelope { let a: Double; let d: Double; let s: Double; let r: Double }
fileprivate enum EnvState { case idle, attack, decay, sustain, release }

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct ContentView: View {
    @EnvironmentObject var audio: AudioController
    @State private var simpleMode = true
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SubGenre.allCases) { sg in
                            Button(action: { audio.state.subGenre = sg; audio.updateParams() }) {
                                Text(sg.rawValue)
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(audio.state.subGenre == sg ? Color.orange.opacity(0.25) : Color.gray.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }.padding(.horizontal)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Key").font(.caption).opacity(0.7)
                        Picker("Key", selection: $audio.state.keyIndex) {
                            ForEach(0..<Keys.names.count, id: \.self) { i in Text(Keys.names[i]) }
                        }
                        .onChange(of: audio.state.keyIndex) { _ in audio.updateParams() }
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading) {
                        Text("Tempo: \(Int(audio.state.tempoBPM)) BPM").font(.caption).opacity(0.7)
                        Slider(value: $audio.state.tempoBPM, in: 60...140, step: 1) { _ in audio.updateParams() }
                    }
                }.padding(.horizontal)
                VStack(alignment: .leading) {
                    Text("Swing: \(String(format: "%.2f", audio.state.swing))").font(.caption).opacity(0.7)
                    Slider(value: $audio.state.swing, in: 0.5...0.67) { _ in audio.updateParams() }
                }.padding(.horizontal)
                HStack(spacing: 18) {
                    Button(action: { audio.state.isPlaying ? audio.pause() : audio.play() }) {
                        HStack { Image(systemName: audio.state.isPlaying ? "pause.fill" : "play.fill"); Text(audio.state.isPlaying ? "Pause" : "Play") }
                            .font(.title3.weight(.bold))
                            .padding(.vertical, 12).padding(.horizontal, 22)
                            .background(Color.orange.opacity(0.25)).clipShape(Capsule())
                    }
                    Button(action: { audio.nextChorus() }) {
                        HStack { Image(systemName: "forward.end.fill"); Text("Next Chorus") }
                            .font(.title3.weight(.bold))
                            .padding(.vertical, 12).padding(.horizontal, 18)
                            .background(Color.gray.opacity(0.2)).clipShape(Capsule())
                    }
                }
                Text("Chorus \(audio.state.chorusIndex)  •  Key \(Keys.names[audio.state.keyIndex])  •  \(Int(audio.state.tempoBPM)) BPM")
                    .font(.footnote).opacity(0.7)
                Divider().padding(.horizontal)
                Toggle(isOn: $simpleMode) { Text("Simple Mode") }
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Infinite Blues")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Image(systemName: "infinity") } }
            .background(
                LinearGradient(colors: [Color(red: 0.35, green: 0.11, blue: 0.05),
                                        Color(red: 0.65, green: 0.27, blue: 0.10),
                                        Color(red: 0.95, green: 0.64, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            )
        }
    }
}
