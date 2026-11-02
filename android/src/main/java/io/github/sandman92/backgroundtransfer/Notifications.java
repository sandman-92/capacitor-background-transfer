package io.github.sandman92.backgroundtransfer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;
import androidx.core.app.NotificationCompat;

/**
 * The notification the job or the worker must show while it runs, which is
 * also its progress. Channel, title and text come from the transfer
 * ({@code notification} in its options), with plain defaults. With the
 * notification permission refused it isn't shown, and the transfer still runs.
 */
final class Notifications {

    static final String DEFAULT_CHANNEL = "background-transfer";
    static final String DEFAULT_CHANNEL_NAME = "Transfers";

    private Notifications() {}

    static int idFor(String direction) {
        return TransferRecord.UPLOAD.equals(direction) ? 0x0B7A0101 : 0x0B7A0102;
    }

    /** For {@code r}, or a placeholder in {@code direction} before the first transfer starts. */
    static Notification build(Context context, String direction, TransferRecord r) {
        String channelId = r != null && r.channelId != null ? r.channelId : DEFAULT_CHANNEL;
        String channelName = r != null && r.channelName != null ? r.channelName : DEFAULT_CHANNEL_NAME;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            if (manager != null && manager.getNotificationChannel(channelId) == null) {
                manager.createNotificationChannel(new NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW));
            }
        }
        boolean upload = TransferRecord.UPLOAD.equals(direction);
        String title = r != null && r.title != null ? r.title : upload ? "Uploading" : "Downloading";
        NotificationCompat.Builder b = new NotificationCompat.Builder(context, channelId)
            .setSmallIcon(upload ? android.R.drawable.stat_sys_upload : android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS);
        if (r != null && r.text != null) b.setContentText(r.text);
        if (r != null && r.total > 0) {
            b.setProgress(1000, (int) Math.min(1000, (r.bytes * 1000) / r.total), false);
        } else {
            b.setProgress(0, 0, true);
        }
        return b.build();
    }
}
