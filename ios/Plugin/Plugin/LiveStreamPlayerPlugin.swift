import Foundation
import Capacitor
import AVFoundation
import MediaPlayer

@objc(LiveStreamPlayerPlugin)
public class LiveStreamPlayerPlugin: CAPPlugin {

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var currentUrl: String?
    private var isLive: Bool = true
    private var artworkImage: UIImage?
    private var timeObserver: Any?
    private var album: String = ""

    // Stall / reconnect tracking for live streams.
    private var timeControlObservation: NSKeyValueObservation?
    private var stallNotificationObserver: NSObjectProtocol?
    private var failedNotificationObserver: NSObjectProtocol?
    private var isStalled: Bool = false
    private var reconnectAttempt: Int = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectWatchdog: DispatchWorkItem?
    // Grace period before rebuilding the AVPlayerItem on stall — lets a brief
    // burble recover naturally before we force a skip-to-live.
    private let stallGraceSeconds: TimeInterval = 2.0
    // Time we give a fresh AVPlayerItem to reach .playing before emitting
    // 'reconnecting' and retrying with backoff.
    private let reconnectTimeoutSeconds: TimeInterval = 5.0

    // Metadata polling (runs natively so it keeps ticking when JS is suspended)
    private var metadataTimer: Timer?
    private var metadataURL: URL?
    private var metadataTitlePath: String = ""
    private var metadataArtistPath: String = ""
    private var metadataArtworkPath: String?
    private var metadataFastInterval: TimeInterval = 20
    private var metadataSlowInterval: TimeInterval = 120
    private var metadataLastKey: String = ""

    // MARK: - Capacitor Methods

    @objc func play(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url"),
              let url = URL(string: urlString) else {
            call.reject("Invalid or missing URL")
            return
        }

        let title        = call.getString("title") ?? ""
        let artist       = call.getString("artist") ?? ""
        let album        = call.getString("album") ?? ""
        let artworkUrl   = call.getString("artworkUrl")
        self.isLive      = call.getBool("isLive") ?? true
        self.currentUrl  = urlString
        self.album       = album
        let startPos     = call.getDouble("startPosition") ?? 0.0
        let metadataPoll = call.getObject("metadataPoll")

        DispatchQueue.main.async {
            self.setupAudioSession()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            self.destroyPlayer()

            self.setupRemoteCommandCenter()

            self.playerItem = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: self.playerItem)

            if !self.isLive && startPos > 0 {
                let time = CMTime(seconds: startPos, preferredTimescale: 1000)
                self.player?.seek(to: time)
            }

            self.updateNowPlayingInfo(title: self.htmlDecode(title), artist: self.htmlDecode(artist), album: album, artworkUrl: artworkUrl)
            self.player?.play()
            self.startTimeObserver()
            self.attachStallObservers()

            if self.isLive, let poll = metadataPoll {
                self.startMetadataPolling(config: poll)
            } else {
                self.stopMetadataPolling()
            }

            call.resolve()
            self.notifyListeners("playerEvent", data: ["type": "play"])
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player?.pause()
            if self.isLive {
                // Live stream: release network connection entirely
                self.player?.replaceCurrentItem(with: nil)
            }
            self.updateNowPlayingPlaybackState(isPlaying: false)
            call.resolve()
            self.notifyListeners("playerEvent", data: ["type": "pause"])
        }
    }

    @objc func resume(_ call: CAPPluginCall) {
        guard let urlString = self.currentUrl,
              let url = URL(string: urlString) else {
            call.reject("No URL to resume")
            return
        }
        DispatchQueue.main.async {
            if self.isLive {
                // Live stream: reconnect
                let item = AVPlayerItem(url: url)
                self.playerItem = item
                self.player?.replaceCurrentItem(with: item)
                self.attachStallObservers()
            }
            self.player?.play()
            self.updateNowPlayingPlaybackState(isPlaying: true)
            call.resolve()
            self.notifyListeners("playerEvent", data: ["type": "play"])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.destroyPlayer()
            self.currentUrl = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            call.resolve()
            self.notifyListeners("playerEvent", data: ["type": "stop"])
        }
    }

    @objc func setNowPlaying(_ call: CAPPluginCall) {
        let title      = call.getString("title") ?? ""
        let artist     = call.getString("artist") ?? ""
        let album      = call.getString("album") ?? ""
        let artworkUrl = call.getString("artworkUrl")
        if let live = call.getBool("isLive") { self.isLive = live }

        DispatchQueue.main.async {
            self.updateNowPlayingInfo(title: self.htmlDecode(title), artist: self.htmlDecode(artist), album: album, artworkUrl: artworkUrl)
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        guard !isLive else {
            // Silently ignore seek on live streams
            call.resolve()
            return
        }
        let position = call.getDouble("position") ?? 0.0
        let time = CMTime(seconds: position, preferredTimescale: 1000)
        DispatchQueue.main.async {
            self.player?.seek(to: time) { _ in
                self.updateElapsedTime()
                call.resolve()
            }
        }
    }

    @objc func getState(_ call: CAPPluginCall) {
        let isPlaying = (player?.timeControlStatus == .playing)
        let position  = player?.currentTime().seconds ?? 0.0
        let duration  = player?.currentItem?.duration.seconds ?? -1.0
        call.resolve([
            "isPlaying": isPlaying,
            "url":       currentUrl ?? NSNull(),
            "position":  position.isNaN ? 0.0 : position,
            "duration":  (duration.isNaN || duration.isInfinite) ? -1.0 : duration
        ])
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            // .longFormAudio tells the system this is a long-form audio app
            // (podcasts / radio) — this is what CarPlay uses to attribute the
            // now-playing client correctly.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("[LiveStreamPlayer] AVAudioSession error: \(error)")
        }
    }

    // MARK: - Player

    private func destroyPlayer() {
        stopTimeObserver()
        stopMetadataPolling()
        detachStallObservers()
        cancelReconnect()
        isStalled = false
        reconnectAttempt = 0
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
    }

    // MARK: - Stall / Reconnect (live streams)
    // AVPlayer handles buffer underruns silently and resumes from the buffered
    // position when the network returns — that causes audio to lag the now-
    // playing JSON. We detect stalls, force-skip to live by rebuilding the
    // AVPlayerItem, and surface stall/reconnecting/recovered events to JS.

    private func attachStallObservers() {
        guard isLive, let item = self.playerItem, let player = self.player else { return }
        detachStallObservers()

        stallNotificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleStall()
        }

        failedNotificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleStall()
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch p.timeControlStatus {
                case .playing:
                    // Playback (re)started — if we were reconnecting, tell JS.
                    if self.isStalled {
                        self.isStalled = false
                        self.reconnectAttempt = 0
                        self.cancelReconnect()
                        self.notifyListeners("playerEvent", data: ["type": "recovered"])
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffer underrun on a live stream — treat as a stall.
                    if self.isLive && !self.isStalled {
                        self.handleStall()
                    }
                default:
                    break
                }
            }
        }
    }

    private func detachStallObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let obs = stallNotificationObserver {
            NotificationCenter.default.removeObserver(obs)
            stallNotificationObserver = nil
        }
        if let obs = failedNotificationObserver {
            NotificationCenter.default.removeObserver(obs)
            failedNotificationObserver = nil
        }
    }

    private func handleStall() {
        guard isLive, !isStalled else { return }
        isStalled = true
        notifyListeners("playerEvent", data: ["type": "stall"])

        // Give the player a brief grace period to recover naturally before
        // we force a skip-to-live rebuild.
        cancelReconnect()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildLiveItem()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stallGraceSeconds, execute: work)
    }

    private func rebuildLiveItem() {
        guard isLive, let urlString = currentUrl, let url = URL(string: urlString) else { return }
        // If the player already recovered on its own during the grace window,
        // timeControlStatus observer will have cleared isStalled.
        if !isStalled { return }

        let item = AVPlayerItem(url: url)
        self.playerItem = item
        self.player?.replaceCurrentItem(with: item)
        attachStallObservers()
        self.player?.play()

        // Watchdog: if we don't reach .playing within the timeout, emit
        // 'reconnecting' and retry with exponential backoff (capped).
        cancelReconnectWatchdog()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.isStalled else { return }
            self.reconnectAttempt += 1
            self.notifyListeners("playerEvent", data: [
                "type": "reconnecting",
                "attempt": self.reconnectAttempt
            ])
            let backoff = min(30.0, pow(2.0, Double(min(self.reconnectAttempt, 4))))
            let next = DispatchWorkItem { [weak self] in self?.rebuildLiveItem() }
            self.reconnectWorkItem = next
            DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: next)
        }
        reconnectWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectTimeoutSeconds, execute: watchdog)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        cancelReconnectWatchdog()
    }

    private func cancelReconnectWatchdog() {
        reconnectWatchdog?.cancel()
        reconnectWatchdog = nil
    }

    // MARK: - Metadata Polling
    // Polls a JSON URL natively and pushes updates to MPNowPlayingInfoCenter.
    // Runs via a Timer on the main run loop — keeps firing while backgrounded
    // because the app has UIBackgroundModes=audio and an active AVAudioSession.

    private func startMetadataPolling(config: [String: Any]) {
        guard let urlString = config["url"] as? String,
              let url = URL(string: urlString),
              let titlePath = config["titlePath"] as? String,
              let artistPath = config["artistPath"] as? String else {
            return
        }
        self.metadataURL = url
        self.metadataTitlePath = titlePath
        self.metadataArtistPath = artistPath
        self.metadataArtworkPath = config["artworkPath"] as? String
        if let f = config["fastIntervalSec"] as? Double { self.metadataFastInterval = f }
        if let s = config["slowIntervalSec"] as? Double { self.metadataSlowInterval = s }
        self.metadataLastKey = ""

        stopMetadataPolling()
        // Fire immediately, then schedule adaptive next runs.
        self.pollMetadataOnce()
    }

    private func stopMetadataPolling() {
        metadataTimer?.invalidate()
        metadataTimer = nil
    }

    private func scheduleNextMetadataPoll(after seconds: TimeInterval) {
        stopMetadataPolling()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.pollMetadataOnce()
        }
        RunLoop.main.add(metadataTimer!, forMode: .common)
    }

    private func pollMetadataOnce() {
        guard let url = self.metadataURL else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else {
                self?.scheduleNextMetadataPoll(after: self?.metadataFastInterval ?? 20)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                self.scheduleNextMetadataPoll(after: self.metadataFastInterval)
                return
            }
            let title  = self.extractString(from: obj, path: self.metadataTitlePath)  ?? ""
            let artist = self.extractString(from: obj, path: self.metadataArtistPath) ?? ""
            let artworkUrl = self.metadataArtworkPath.flatMap { self.extractString(from: obj, path: $0) }

            let key = title + "|" + artist
            let isFirstFetch = self.metadataLastKey.isEmpty
            var next = self.metadataFastInterval

            if key != self.metadataLastKey && !title.isEmpty {
                self.metadataLastKey = key
                let decodedTitle  = self.htmlDecode(title)
                let decodedArtist = self.htmlDecode(artist)
                DispatchQueue.main.async {
                    self.updateNowPlayingInfo(
                        title: decodedTitle,
                        artist: decodedArtist,
                        album: self.album,
                        artworkUrl: artworkUrl
                    )
                }
                if !isFirstFetch { next = self.metadataSlowInterval }
            }
            DispatchQueue.main.async {
                self.scheduleNextMetadataPoll(after: next)
            }
        }.resume()
    }

    // Walks "a.b.0.c" style paths against nested dictionaries/arrays.
    private func extractString(from obj: Any, path: String) -> String? {
        var current: Any? = obj
        for part in path.split(separator: ".") {
            if let idx = Int(part), let arr = current as? [Any], idx >= 0, idx < arr.count {
                current = arr[idx]
            } else if let dict = current as? [String: Any] {
                current = dict[String(part)]
            } else {
                return nil
            }
        }
        return current as? String
    }

    // Decode common HTML entities (&amp;, &#39;, &quot;, etc.) so artist names
    // like "Philips, Craig &amp; Dean" render cleanly on the lock screen.
    private func htmlDecode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let data = s.data(using: .utf8) else { return s }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attr.string
        }
        return s
    }

    // Periodic observer: keeps MPNowPlayingInfoCenter elapsed time in sync for podcasts
    // so the iOS lock-screen scrubber animates.
    private func startTimeObserver() {
        stopTimeObserver()
        guard !isLive, let player = self.player else { return }
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updateElapsedTime()
        }
    }

    private func stopTimeObserver() {
        if let obs = self.timeObserver {
            self.player?.removeTimeObserver(obs)
            self.timeObserver = nil
        }
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        // Always enable play/pause
        cc.playCommand.isEnabled = true
        cc.playCommand.removeTarget(nil)
        cc.playCommand.addTarget { [weak self] _ in
            self?.handleRemotePlay(); return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.removeTarget(nil)
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemotePause(); return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.player?.timeControlStatus == .playing { self.handleRemotePause() }
            else { self.handleRemotePlay() }
            return .success
        }

        if isLive {
            // Live stream — disable all seek/skip controls
            cc.nextTrackCommand.isEnabled = false;          cc.nextTrackCommand.removeTarget(nil)
            cc.previousTrackCommand.isEnabled = false;      cc.previousTrackCommand.removeTarget(nil)
            cc.skipForwardCommand.isEnabled = false;        cc.skipForwardCommand.removeTarget(nil)
            cc.skipBackwardCommand.isEnabled = false;       cc.skipBackwardCommand.removeTarget(nil)
            cc.seekForwardCommand.isEnabled = false;        cc.seekForwardCommand.removeTarget(nil)
            cc.seekBackwardCommand.isEnabled = false;       cc.seekBackwardCommand.removeTarget(nil)
            cc.changePlaybackPositionCommand.isEnabled = false; cc.changePlaybackPositionCommand.removeTarget(nil)
            cc.changePlaybackRateCommand.isEnabled = false; cc.changePlaybackRateCommand.removeTarget(nil)
        } else {
            // Podcast / on-demand — enable 30s skip forward/back and scrub
            cc.skipForwardCommand.isEnabled = true
            cc.skipForwardCommand.preferredIntervals = [30]
            cc.skipForwardCommand.removeTarget(nil)
            cc.skipForwardCommand.addTarget { [weak self] event in
                if let e = event as? MPSkipIntervalCommandEvent {
                    let current = self?.player?.currentTime().seconds ?? 0
                    let newTime = CMTime(seconds: current + e.interval, preferredTimescale: 1000)
                    self?.player?.seek(to: newTime) { _ in self?.updateElapsedTime() }
                    self?.notifyListeners("playerEvent", data: ["type": "remoteSeekForward"])
                }
                return .success
            }

            cc.skipBackwardCommand.isEnabled = true
            cc.skipBackwardCommand.preferredIntervals = [30]
            cc.skipBackwardCommand.removeTarget(nil)
            cc.skipBackwardCommand.addTarget { [weak self] event in
                if let e = event as? MPSkipIntervalCommandEvent {
                    let current = self?.player?.currentTime().seconds ?? 0
                    let newTime = CMTime(seconds: max(0, current - e.interval), preferredTimescale: 1000)
                    self?.player?.seek(to: newTime) { _ in self?.updateElapsedTime() }
                    self?.notifyListeners("playerEvent", data: ["type": "remoteSeekBackward"])
                }
                return .success
            }

            cc.changePlaybackPositionCommand.isEnabled = true
            cc.changePlaybackPositionCommand.removeTarget(nil)
            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                if let e = event as? MPChangePlaybackPositionCommandEvent {
                    let newTime = CMTime(seconds: e.positionTime, preferredTimescale: 1000)
                    self?.player?.seek(to: newTime) { _ in self?.updateElapsedTime() }
                    self?.notifyListeners("playerEvent", data: ["type": "remoteSeekTo", "position": e.positionTime])
                }
                return .success
            }

            cc.nextTrackCommand.isEnabled = false;     cc.nextTrackCommand.removeTarget(nil)
            cc.previousTrackCommand.isEnabled = false; cc.previousTrackCommand.removeTarget(nil)
            cc.seekForwardCommand.isEnabled = false;   cc.seekForwardCommand.removeTarget(nil)
            cc.seekBackwardCommand.isEnabled = false;  cc.seekBackwardCommand.removeTarget(nil)
            cc.changePlaybackRateCommand.isEnabled = false; cc.changePlaybackRateCommand.removeTarget(nil)
        }
    }

    private func handleRemotePlay() {
        guard let urlString = currentUrl, let url = URL(string: urlString) else { return }
        if isLive {
            let item = AVPlayerItem(url: url)
            self.playerItem = item
            player?.replaceCurrentItem(with: item)
            attachStallObservers()
        }
        player?.play()
        updateNowPlayingPlaybackState(isPlaying: true)
        notifyListeners("playerEvent", data: ["type": "remotePlay"])
    }

    private func handleRemotePause() {
        player?.pause()
        if isLive { player?.replaceCurrentItem(with: nil) }
        updateNowPlayingPlaybackState(isPlaying: false)
        notifyListeners("playerEvent", data: ["type": "remotePause"])
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo(title: String, artist: String, album: String, artworkUrl: String?) {
        let isPlaying = (player?.rate ?? 0) > 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:            title,
            MPMediaItemPropertyArtist:           artist,
            MPMediaItemPropertyAlbumTitle:       album,
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? 1.0 : 0.0),
            MPNowPlayingInfoPropertyMediaType:   NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
        ]

        if !isLive {
            // Populate duration and elapsed for podcast scrubber
            if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration]     = NSNumber(value: duration)
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: player?.currentTime().seconds ?? 0)
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        // Load artwork async
        if let artStr = artworkUrl, let artURL = URL(string: artStr) {
            URLSession.shared.dataTask(with: artURL) { [weak self] data, _, _ in
                guard let data = data, let image = UIImage(data: data) else { return }
                self?.artworkImage = image
                DispatchQueue.main.async {
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }.resume()
        }
    }

    private func updateNowPlayingPlaybackState(isPlaying: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: isPlaying ? 1.0 : 0.0)
        if !isLive {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: player?.currentTime().seconds ?? 0)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func updateElapsedTime() {
        guard !isLive else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: player?.currentTime().seconds ?? 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
