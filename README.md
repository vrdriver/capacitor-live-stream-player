# capacitor-live-stream-player

A Capacitor plugin for live audio stream playback with **full native lock screen controls**.

- **iOS** — uses `AVPlayer` + `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`. No WKWebView `<audio>` interference. Only play/pause shown — no scrubber, no skip buttons.
- **Android** — uses `ExoPlayer` + `MediaSessionCompat`. Duration set to `-1` (live stream mode) to hide the scrubber.
- **Web** — falls back to HTML5 `<audio>` + `MediaSession API`.

## Install

```bash
npm install capacitor-live-stream-player
npx cap sync
```

## API

### `play(options)`

Start streaming a URL. Sets up the lock screen immediately.

```typescript
await LiveStreamPlayer.play({
  url: 'https://stream.example.com/live',
  title: 'Blast FM',
  artist: 'Live Radio',
  album: 'Radio Station Company',
  artworkUrl: 'https://example.com/artwork.jpg',
  isLive: true, // hides scrubber/skip on lock screen
});
```

### `pause()`

Pause and **fully release the network connection** (important for metered connections).

```typescript
await LiveStreamPlayer.pause();
```

### `resume()`

Reconnect and resume the stream without needing to call `play()` again.

```typescript
await LiveStreamPlayer.resume();
```

### `stop()`

Stop playback and destroy the player instance.

```typescript
await LiveStreamPlayer.stop();
```

### `setNowPlaying(options)`

Update lock screen metadata (call this when the song changes).

```typescript
await LiveStreamPlayer.setNowPlaying({
  title: 'BEFORE I KNEW JESUS',
  artist: 'Leanna Crawford',
  album: 'Life FM',
  artworkUrl: 'https://example.com/song-art.jpg',
  isLive: true,
});
```

### `getState()`

```typescript
const { isPlaying, url } = await LiveStreamPlayer.getState();
```

### Events

```typescript
await LiveStreamPlayer.addListener('playerEvent', (event) => {
  switch (event.type) {
    case 'play':        // playback started
    case 'pause':       // playback paused
    case 'stop':        // player destroyed
    case 'remotePlay':  // user tapped play on lock screen
    case 'remotePause': // user tapped pause on lock screen
    case 'error':       // stream error — event.message has details
  }
});
```

## iOS Setup

No extra setup needed. The plugin uses `AVAudioSession.Category.playback` automatically, which enables background audio.

Ensure your `Info.plist` has:
```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

## Android Setup

Add INTERNET permission to `AndroidManifest.xml` (usually already present):
```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## Why not `<audio>`?

On iOS, WKWebView's `<audio>` element is hardwired into `MPNowPlayingInfoCenter`. iOS reads the stream's `Content-Length` header and calculates a fake duration (often 18+ hours), which causes it to show a scrubber and 10-second skip buttons on the lock screen. There is no JavaScript API to prevent this.

This plugin bypasses WKWebView entirely by playing through native `AVPlayer`, giving full control over what appears on the lock screen.

## License

MIT
