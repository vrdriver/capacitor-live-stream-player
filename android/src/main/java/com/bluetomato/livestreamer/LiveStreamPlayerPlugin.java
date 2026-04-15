package com.bluetomato.livestreamer;

import android.content.ComponentName;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.annotation.NonNull;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.InputStream;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@CapacitorPlugin(name = "LiveStreamPlayer")
public class LiveStreamPlayerPlugin extends Plugin {

    private ExoPlayer player;
    private MediaSessionCompat mediaSession;
    private String currentUrl;
    private String currentTitle  = "";
    private String currentArtist = "";
    private String currentAlbum  = "";
    private String currentArtworkUrl = "";
    private boolean isLive = true;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @Override
    public void load() {
        Context context = getContext();
        ComponentName receiver = new ComponentName(context, LiveStreamPlayerPlugin.class);
        mediaSession = new MediaSessionCompat(context, "LiveStreamPlayer", receiver, null);
        mediaSession.setFlags(
            MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS |
            MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
        );
        mediaSession.setCallback(new MediaSessionCompat.Callback() {
            @Override public void onPlay()  { getActivity().runOnUiThread(() -> handleRemotePlay()); }
            @Override public void onPause() { getActivity().runOnUiThread(() -> handleRemotePause()); }
            @Override public void onFastForward() { getActivity().runOnUiThread(() -> handleSeekForward()); }
            @Override public void onRewind()      { getActivity().runOnUiThread(() -> handleSeekBackward()); }
            @Override public void onSeekTo(long pos) { getActivity().runOnUiThread(() -> handleSeekTo(pos / 1000.0)); }
        });
        mediaSession.setActive(true);
    }

    @PluginMethod
    public void play(PluginCall call) {
        String url = call.getString("url");
        if (url == null || url.isEmpty()) { call.reject("Missing URL"); return; }

        currentUrl        = url;
        currentTitle      = call.getString("title",      "");
        currentArtist     = call.getString("artist",     "");
        currentAlbum      = call.getString("album",      "");
        currentArtworkUrl = call.getString("artworkUrl", "");
        isLive            = Boolean.TRUE.equals(call.getBoolean("isLive", true));
        double startPos   = call.getDouble("startPosition", 0.0);

        getActivity().runOnUiThread(() -> {
            destroyPlayer();
            player = new ExoPlayer.Builder(getContext()).build();
            player.setMediaItem(MediaItem.fromUri(url));

            if (!isLive && startPos > 0) {
                player.seekTo((long)(startPos * 1000));
            }

            player.addListener(new Player.Listener() {
                @Override public void onPlaybackStateChanged(int state) {
                    if (state == Player.STATE_READY) player.play();
                    else if (state == Player.STATE_ENDED) notifyEvent("stop");
                }
                @Override public void onPlayerError(@NonNull androidx.media3.common.PlaybackException e) {
                    JSObject d = new JSObject(); d.put("type","error"); d.put("message", e.getMessage());
                    notifyListeners("playerEvent", d);
                }
            });
            player.prepare();

            updateMediaSession(true);
            loadArtworkAsync(currentArtworkUrl);
            call.resolve();
            notifyEvent("play");
        });
    }

    @PluginMethod
    public void pause(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (player != null) {
                player.stop();
                if (isLive) {
                    // Release network connection for live streams
                    player.clearMediaItems();
                }
            }
            updatePlaybackState(false);
            call.resolve();
            notifyEvent("pause");
        });
    }

    @PluginMethod
    public void resume(PluginCall call) {
        if (currentUrl == null) { call.reject("No URL to resume"); return; }
        getActivity().runOnUiThread(() -> {
            if (player == null) player = new ExoPlayer.Builder(getContext()).build();
            if (isLive) {
                player.setMediaItem(MediaItem.fromUri(currentUrl));
            }
            player.prepare();
            updatePlaybackState(true);
            call.resolve();
            notifyEvent("play");
        });
    }

    @PluginMethod
    public void stop(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            destroyPlayer();
            currentUrl = null;
            if (mediaSession != null) mediaSession.setActive(false);
            call.resolve();
            notifyEvent("stop");
        });
    }

    @PluginMethod
    public void setNowPlaying(PluginCall call) {
        if (call.getString("title")      != null) currentTitle      = call.getString("title");
        if (call.getString("artist")     != null) currentArtist     = call.getString("artist");
        if (call.getString("album")      != null) currentAlbum      = call.getString("album");
        if (call.getString("artworkUrl") != null) currentArtworkUrl = call.getString("artworkUrl");
        if (call.getBoolean("isLive")    != null) isLive = Boolean.TRUE.equals(call.getBoolean("isLive"));

        getActivity().runOnUiThread(() -> {
            boolean playing = player != null && player.isPlaying();
            updateMediaSession(playing);
            loadArtworkAsync(currentArtworkUrl);
            call.resolve();
        });
    }

    @PluginMethod
    public void seekTo(PluginCall call) {
        if (isLive) { call.resolve(); return; } // ignore seek on live streams
        double position = call.getDouble("position", 0.0);
        getActivity().runOnUiThread(() -> {
            if (player != null) {
                player.seekTo((long)(position * 1000));
                updateElapsedTime();
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void getState(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            JSObject result = new JSObject();
            result.put("isPlaying", player != null && player.isPlaying());
            result.put("url", currentUrl != null ? currentUrl : JSObject.NULL);
            result.put("position", player != null ? player.getCurrentPosition() / 1000.0 : 0.0);
            result.put("duration", player != null && player.getDuration() != androidx.media3.common.C.TIME_UNSET
                ? player.getDuration() / 1000.0 : -1.0);
            call.resolve(result);
        });
    }

    // MARK: - Helpers

    private void destroyPlayer() {
        if (player != null) { player.stop(); player.release(); player = null; }
    }

    private void handleRemotePlay() {
        if (currentUrl == null) return;
        if (player == null) player = new ExoPlayer.Builder(getContext()).build();
        if (isLive) player.setMediaItem(MediaItem.fromUri(currentUrl));
        player.prepare();
        updatePlaybackState(true);
        notifyEvent("remotePlay");
    }

    private void handleRemotePause() {
        if (player != null) { player.stop(); if (isLive) player.clearMediaItems(); }
        updatePlaybackState(false);
        notifyEvent("remotePause");
    }

    private void handleSeekForward() {
        if (isLive || player == null) return;
        player.seekTo(player.getCurrentPosition() + 30_000);
        updateElapsedTime();
        notifyEvent("remoteSeekForward");
    }

    private void handleSeekBackward() {
        if (isLive || player == null) return;
        player.seekTo(Math.max(0, player.getCurrentPosition() - 30_000));
        updateElapsedTime();
        notifyEvent("remoteSeekBackward");
    }

    private void handleSeekTo(double seconds) {
        if (isLive || player == null) return;
        player.seekTo((long)(seconds * 1000));
        updateElapsedTime();
        JSObject d = new JSObject(); d.put("type","remoteSeekTo"); d.put("position", seconds);
        notifyListeners("playerEvent", d);
    }

    private void updateMediaSession(boolean isPlaying) {
        if (mediaSession == null) return;
        long durationMs = isLive ? -1L
            : (player != null && player.getDuration() != androidx.media3.common.C.TIME_UNSET
                ? player.getDuration() : -1L);

        MediaMetadataCompat.Builder meta = new MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE,  currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM,  currentAlbum)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs);
        mediaSession.setMetadata(meta.build());
        updatePlaybackState(isPlaying);
    }

    private void updatePlaybackState(boolean isPlaying) {
        if (mediaSession == null) return;
        long actions = PlaybackStateCompat.ACTION_PLAY |
                       PlaybackStateCompat.ACTION_PAUSE |
                       PlaybackStateCompat.ACTION_PLAY_PAUSE;
        if (!isLive) {
            actions |= PlaybackStateCompat.ACTION_FAST_FORWARD |
                       PlaybackStateCompat.ACTION_REWIND |
                       PlaybackStateCompat.ACTION_SEEK_TO;
        }
        long position = player != null ? player.getCurrentPosition() : PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN;
        PlaybackStateCompat state = new PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(isPlaying ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED,
                      position, 1.0f)
            .build();
        mediaSession.setPlaybackState(state);
    }

    private void updateElapsedTime() {
        if (isLive || mediaSession == null || player == null) return;
        PlaybackStateCompat current = mediaSession.getController().getPlaybackState();
        if (current == null) return;
        PlaybackStateCompat updated = new PlaybackStateCompat.Builder(current)
            .setState(current.getState(), player.getCurrentPosition(), 1.0f)
            .build();
        mediaSession.setPlaybackState(updated);
    }

    private void loadArtworkAsync(String artworkUrl) {
        if (artworkUrl == null || artworkUrl.isEmpty()) return;
        executor.execute(() -> {
            try {
                InputStream is = new URL(artworkUrl).openStream();
                Bitmap bmp = BitmapFactory.decodeStream(is);
                if (bmp != null && mediaSession != null) {
                    MediaMetadataCompat current = mediaSession.getController().getMetadata();
                    MediaMetadataCompat.Builder builder = new MediaMetadataCompat.Builder(current)
                        .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bmp);
                    getActivity().runOnUiThread(() -> mediaSession.setMetadata(builder.build()));
                }
            } catch (Exception e) { /* artwork load failed — not critical */ }
        });
    }

    private void notifyEvent(String type) {
        JSObject d = new JSObject(); d.put("type", type);
        notifyListeners("playerEvent", d);
    }

    @Override
    protected void handleOnDestroy() {
        destroyPlayer();
        if (mediaSession != null) { mediaSession.release(); mediaSession = null; }
        executor.shutdown();
    }
}
