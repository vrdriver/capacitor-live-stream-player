import { WebPlugin } from '@capacitor/core';
import type { LiveStreamPlayerPlugin, PlayOptions, NowPlayingOptions, PlayerState, SeekOptions } from './definitions';

/**
 * Web fallback — uses HTML5 <audio> + MediaSession API.
 * Lock screen controls on desktop browsers that support MediaSession.
 */
export class LiveStreamPlayerWeb extends WebPlugin implements LiveStreamPlayerPlugin {
  private audio: HTMLAudioElement | null = null;
  private currentUrl: string | null = null;
  private isLive: boolean = true;

  async play(options: PlayOptions): Promise<void> {
    if (this.audio) {
      this.audio.pause();
      this.audio.src = '';
    }
    this.audio = new Audio(options.url);
    this.currentUrl = options.url;
    this.isLive = options.isLive !== false;
    if (!this.isLive && (options.startPosition ?? 0) > 0) {
      this.audio.currentTime = options.startPosition!;
    }

    this.audio.addEventListener('error', () => {
      this.notifyListeners('playerEvent', { type: 'error', message: 'Stream error' });
    });

    this.setMediaSession(options);

    await this.audio.play();
    if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = 'playing';
    }
    this.notifyListeners('playerEvent', { type: 'play' });
  }

  async pause(): Promise<void> {
    if (this.audio) {
      this.audio.pause();
      this.audio.src = '';
      this.audio.load();
    }
    if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = 'paused';
    }
    this.notifyListeners('playerEvent', { type: 'pause' });
  }

  async resume(): Promise<void> {
    if (this.audio && this.currentUrl) {
      this.audio.src = this.currentUrl;
      await this.audio.play();
      if ('mediaSession' in navigator) {
        navigator.mediaSession.playbackState = 'playing';
      }
      this.notifyListeners('playerEvent', { type: 'play' });
    }
  }

  async stop(): Promise<void> {
    if (this.audio) {
      this.audio.pause();
      this.audio.src = '';
      this.audio.load();
      this.audio = null;
    }
    this.currentUrl = null;
    this.notifyListeners('playerEvent', { type: 'stop' });
  }

  async setNowPlaying(options: NowPlayingOptions): Promise<void> {
    this.setMediaSession(options);
  }

  async seekTo(options: SeekOptions): Promise<void> {
    if (this.isLive || !this.audio) return;
    this.audio.currentTime = options.position;
  }

  async getState(): Promise<PlayerState> {
    return {
      isPlaying: this.audio ? !this.audio.paused : false,
      url: this.currentUrl,
      position: this.audio?.currentTime ?? 0,
      duration: this.audio ? (isFinite(this.audio.duration) ? this.audio.duration : -1) : -1,
    };
  }

  private setMediaSession(options: NowPlayingOptions & { isLive?: boolean }) {
    if (!('mediaSession' in navigator)) return;

    const artwork: MediaImage[] = [];
    if (options.artworkUrl) {
      artwork.push({ src: options.artworkUrl, sizes: '512x512', type: 'image/jpeg' });
      artwork.push({ src: options.artworkUrl, sizes: '256x256', type: 'image/jpeg' });
    }

    navigator.mediaSession.metadata = new MediaMetadata({
      title: options.title,
      artist: options.artist,
      album: options.album || '',
      artwork,
    });

    if (options.isLive !== false) {
      try {
        (navigator.mediaSession as any).setPositionState({
          duration: Infinity,
          position: 0,
          playbackRate: 1,
        });
      } catch (e) {}
    }

    navigator.mediaSession.setActionHandler('play', () => {
      this.notifyListeners('playerEvent', { type: 'remotePlay' });
    });
    navigator.mediaSession.setActionHandler('pause', () => {
      this.notifyListeners('playerEvent', { type: 'remotePause' });
    });
    try { navigator.mediaSession.setActionHandler('nexttrack', null); } catch (e) {}
    try { navigator.mediaSession.setActionHandler('previoustrack', null); } catch (e) {}
    try { navigator.mediaSession.setActionHandler('seekforward', null); } catch (e) {}
    try { navigator.mediaSession.setActionHandler('seekbackward', null); } catch (e) {}
    try { navigator.mediaSession.setActionHandler('seekto', null); } catch (e) {}
  }
}
