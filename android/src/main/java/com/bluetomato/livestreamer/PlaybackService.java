package com.bluetomato.livestreamer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Binder;
import android.os.Build;
import android.os.IBinder;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.core.app.NotificationCompat;
import androidx.media.app.NotificationCompat.MediaStyle;

// Foreground service that hosts the MediaStyle notification for lock-screen
// playback controls. The plugin creates/updates the MediaSession and calls
// this service to post/update/cancel the notification.
public class PlaybackService extends Service {

    public static final String CHANNEL_ID = "livestreamplayer_playback";
    public static final int NOTIFICATION_ID = 7412;

    public static final String ACTION_START   = "com.bluetomato.livestreamer.START";
    public static final String ACTION_UPDATE  = "com.bluetomato.livestreamer.UPDATE";
    public static final String ACTION_STOP    = "com.bluetomato.livestreamer.STOP";

    private static MediaSessionCompat mediaSession;

    public static void setMediaSession(MediaSessionCompat session) {
        mediaSession = session;
    }

    private final IBinder binder = new LocalBinder();
    public class LocalBinder extends Binder {
        PlaybackService getService() { return PlaybackService.this; }
    }

    @Override
    public IBinder onBind(Intent intent) { return binder; }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_STOP.equals(action)) {
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        Notification n = buildNotification();
        if (n != null) {
            startForeground(NOTIFICATION_ID, n);
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
    }

    public void updateNotification() {
        Notification n = buildNotification();
        if (n == null) return;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, n);
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW
        );
        channel.setShowBadge(false);
        channel.setSound(null, null);
        nm.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        if (mediaSession == null) return null;

        MediaMetadataCompat meta = mediaSession.getController().getMetadata();
        PlaybackStateCompat state = mediaSession.getController().getPlaybackState();
        boolean isPlaying = state != null && state.getState() == PlaybackStateCompat.STATE_PLAYING;

        String title  = meta != null ? meta.getString(MediaMetadataCompat.METADATA_KEY_TITLE)  : null;
        String artist = meta != null ? meta.getString(MediaMetadataCompat.METADATA_KEY_ARTIST) : null;
        Bitmap artwork = meta != null ? meta.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART) : null;

        int smallIcon = getApplicationInfo().icon;
        if (smallIcon == 0) smallIcon = android.R.drawable.ic_media_play;

        Intent contentIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent contentPending = contentIntent != null
            ? PendingIntent.getActivity(this, 0, contentIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE)
            : null;

        NotificationCompat.Builder b = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title != null ? title : "")
            .setContentText(artist != null ? artist : "")
            .setLargeIcon(artwork)
            .setOngoing(isPlaying)
            .setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentPending);

        NotificationCompat.Action playPause = isPlaying
            ? new NotificationCompat.Action(
                android.R.drawable.ic_media_pause, "Pause",
                mediaButtonPending(PlaybackStateCompat.ACTION_PAUSE))
            : new NotificationCompat.Action(
                android.R.drawable.ic_media_play, "Play",
                mediaButtonPending(PlaybackStateCompat.ACTION_PLAY));
        b.addAction(playPause);

        MediaStyle style = new MediaStyle()
            .setMediaSession(mediaSession.getSessionToken())
            .setShowActionsInCompactView(0);
        b.setStyle(style);

        return b.build();
    }

    private PendingIntent mediaButtonPending(long action) {
        return MediaButtonHelper.buildMediaButtonPendingIntent(this, action);
    }
}
