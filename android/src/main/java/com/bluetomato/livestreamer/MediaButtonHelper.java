package com.bluetomato.livestreamer;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.support.v4.media.session.PlaybackStateCompat;
import android.view.KeyEvent;

import androidx.media.session.MediaButtonReceiver;

public class MediaButtonHelper {
    public static PendingIntent buildMediaButtonPendingIntent(Context context, long action) {
        ComponentName receiver = new ComponentName(context, MediaButtonReceiver.class);
        int keyCode = keyCodeForAction(action);
        Intent intent = new Intent(Intent.ACTION_MEDIA_BUTTON);
        intent.setComponent(receiver);
        intent.putExtra(Intent.EXTRA_KEY_EVENT, new KeyEvent(KeyEvent.ACTION_DOWN, keyCode));
        return PendingIntent.getBroadcast(
            context,
            keyCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
    }

    private static int keyCodeForAction(long action) {
        if (action == PlaybackStateCompat.ACTION_PLAY)  return KeyEvent.KEYCODE_MEDIA_PLAY;
        if (action == PlaybackStateCompat.ACTION_PAUSE) return KeyEvent.KEYCODE_MEDIA_PAUSE;
        if (action == PlaybackStateCompat.ACTION_PLAY_PAUSE) return KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE;
        if (action == PlaybackStateCompat.ACTION_STOP) return KeyEvent.KEYCODE_MEDIA_STOP;
        return KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE;
    }
}
