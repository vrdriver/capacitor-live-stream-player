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
        let startPos     = call.getDouble("startPosition") ?? 0.0

        DispatchQueue.main.async {
            self.setupAudioSession()
            self.destroyPlayer()

            self.playerItem = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: self.playerItem)

            if !self.isLive && startPos > 0 {
                let time = CMTime(seconds: startPos, preferredTimescale: 1000)
                self.player?.seek(to: time)
            }

            self.player?.play()
            self.setupRemoteCommandCenter()
            self.updateNowPlayingInfo(title: title, artist: artist, album: album, artworkUrl: artworkUrl)

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
            self.updateNowPlayingInfo(title: title, artist: artist, album: album, artworkUrl: artworkUrl)
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[LiveStreamPlayer] AVAudioSession error: \(error)")
        }
    }

    // MARK: - Player

    private func destroyPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
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

        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func handleRemotePlay() {
        guard let urlString = currentUrl, let url = URL(string: urlString) else { return }
        if isLive {
            let item = AVPlayerItem(url: url)
            self.playerItem = item
            player?.replaceCurrentItem(with: item)
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:            title,
            MPMediaItemPropertyArtist:           artist,
            MPMediaItemPropertyAlbumTitle:       album,
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: 1.0),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: self.isLive),
        ]

        if !isLive {
            // Populate duration and elapsed for podcast scrubber
            if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration]     = NSNumber(value: duration)
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: player?.currentTime().seconds ?? 0)
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

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
    }

    private func updateElapsedTime() {
        guard !isLive else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: player?.currentTime().seconds ?? 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
