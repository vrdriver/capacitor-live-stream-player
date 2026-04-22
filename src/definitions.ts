export interface LiveStreamPlayerPlugin {
  /**
   * Play an audio URL — live stream or podcast/file.
   * On iOS uses AVPlayer (full native lock screen control).
   * On Android uses ExoPlayer.
   */
  play(options: PlayOptions): Promise<void>;

  /**
   * Pause playback.
   * For live streams, also releases the network connection.
   */
  pause(): Promise<void>;

  /**
   * Resume after pause.
   * For live streams, reconnects. For podcasts, resumes from position.
   */
  resume(): Promise<void>;

  /**
   * Stop playback and destroy the player instance.
   */
  stop(): Promise<void>;

  /**
   * Update lock screen / notification metadata.
   * Call this when the now-playing song changes.
   */
  setNowPlaying(options: NowPlayingOptions): Promise<void>;

  /**
   * Seek to a position in seconds (podcasts / on-demand only).
   * Has no effect on live streams.
   */
  seekTo(options: SeekOptions): Promise<void>;

  /**
   * Returns current playback state.
   */
  getState(): Promise<PlayerState>;

  /**
   * Listen for events from the native player.
   */
  addListener(
    eventName: 'playerEvent',
    listenerFunc: (event: PlayerEvent) => void,
  ): Promise<any>;

  removeAllListeners(): Promise<void>;
}

export interface PlayOptions {
  /** The audio URL (http/https live stream or podcast file) */
  url: string;
  /** Display title for the lock screen */
  title: string;
  /** Artist / subtitle for the lock screen */
  artist: string;
  /** Album name shown on lock screen */
  album?: string;
  /** Full HTTPS URL to artwork image */
  artworkUrl?: string;
  /**
   * true  = live stream: hides scrubber, disables seek/skip on lock screen.
   * false = on-demand (podcast): shows scrubber, enables seek forward/back.
   * Default: true
   */
  isLive?: boolean;
  /** Starting position in seconds (on-demand only). Default: 0 */
  startPosition?: number;
  /**
   * Optional: native-side polling of a now-playing JSON URL so the lock-screen
   * metadata updates while the app is backgrounded (iOS suspends JS when the
   * screen locks). The plugin fetches the URL, extracts song/artist/artwork
   * via simple dot-path expressions, and updates the lock screen directly.
   * Live streams only.
   */
  metadataPoll?: MetadataPollOptions;
}

export interface MetadataPollOptions {
  /** URL returning JSON with the current song info */
  url: string;
  /** Dot-path to the song title, e.g. "localChart.songs.0.song_name" */
  titlePath: string;
  /** Dot-path to the artist name */
  artistPath: string;
  /** Dot-path to the artwork URL (optional) */
  artworkPath?: string;
  /** Fast cadence in seconds when song is unchanged. Default: 20 */
  fastIntervalSec?: number;
  /** Slow cadence after a song change. Default: 120 */
  slowIntervalSec?: number;
}

export interface NowPlayingOptions {
  title: string;
  artist: string;
  album?: string;
  artworkUrl?: string;
  /** Keep in sync with the current play mode. Default: true */
  isLive?: boolean;
}

export interface SeekOptions {
  /** Position in seconds */
  position: number;
}

export interface PlayerState {
  isPlaying: boolean;
  url: string | null;
  /** Current playback position in seconds */
  position: number;
  /** Total duration in seconds. -1 for live streams. */
  duration: number;
}

export interface PlayerEvent {
  /**
   * 'play' | 'pause' | 'stop' | 'error' |
   * 'remotePlay' | 'remotePause' |
   * 'remoteSeekForward' | 'remoteSeekBackward' | 'remoteSeekTo' |
   * 'stall' | 'reconnecting' | 'recovered'
   *
   * Live-stream lifecycle:
   *   'stall'        - buffer drained (e.g. reception blackspot). Fired once.
   *   'reconnecting' - rebuild attempt didn't reach playing in time; includes
   *                    `attempt` (1-indexed). Retries with backoff.
   *   'recovered'    - playback resumed at the live edge after a stall.
   */
  type: string;
  /** Seek position in seconds (for remoteSeekTo events) */
  position?: number;
  /** Error message if type === 'error' */
  message?: string;
  /** Retry counter for 'reconnecting' events (1-indexed) */
  attempt?: number;
}
