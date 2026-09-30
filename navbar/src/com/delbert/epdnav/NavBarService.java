package com.delbert.epdnav;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

/**
 * Adds a real TYPE_NAVIGATION_BAR window at the bottom of the display, and keeps
 * the process alive as a foreground service.
 *
 * Why this works: the ROM's PhoneWindowManager is stock. prepareAddWindowLw()
 * binds mNavigationBar for window type 0x7e3 (TYPE_NAVIGATION_BAR) once the
 * caller holds the signature-level STATUS_BAR_SERVICE permission; layoutWindowLw()
 * positions it; and the bottom inset is derived from that window being visible.
 * SystemUI's own createNavigationBar() call was deleted by the vendor, so nothing
 * ever adds this window -- that is the entire bug. See docs/FINDINGS.md.
 */
public class NavBarService extends Service {
    private static final String TAG = "EpdNavBar";
    private static final String CHANNEL = "epdnav";
    private static final int NOTIFICATION_ID = 1;

    /** WindowManager.LayoutParams.TYPE_NAVIGATION_BAR (@hide, value is stable). */
    private static final int TYPE_NAVIGATION_BAR = 2019;

    /**
     * When to ask for the service, in milliseconds from the request.
     *
     * This ROM's ActivityManager silently drops a startForegroundService() issued
     * from a process it has not yet marked foreground: the call returns normally,
     * throws nothing, logs nothing, and the service is never created. Measured
     * directly -- calling from Activity.onCreate/onResume does nothing, the same
     * call three seconds later works. So ask repeatedly; repeated requests are
     * harmless because the service only ever owns one window.
     */
    private static final long[] REQUEST_RETRY_MS = {0, 3000, 8000, 20000};

    private WindowManager mWindowManager;
    private View mBar;

    /** Volatile so BootActivity can see it across threads. */
    private static volatile boolean sRunning;

    /** Whether the nav bar window has been added. */
    static boolean isRunning() {
        return sRunning;
    }

    /**
     * Ask for the navigation bar service, retrying over the next ~20 seconds.
     *
     * Safe to call from anywhere and any number of times.
     */
    static void requestStart(Context context) {
        final Context appContext = context.getApplicationContext();
        final Handler handler = new Handler(Looper.getMainLooper());
        for (final long delay : REQUEST_RETRY_MS) {
            Runnable attempt = new Runnable() {
                @Override
                public void run() {
                    try {
                        appContext.startForegroundService(
                                new Intent(appContext, NavBarService.class));
                        Log.i(TAG, "service requested (delay=" + delay + "ms)");
                    } catch (Throwable t) {
                        Log.e(TAG, "service request failed (delay=" + delay + "ms)", t);
                    }
                }
            };
            if (delay == 0) {
                attempt.run();
            } else {
                handler.postDelayed(attempt, delay);
            }
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "NavBarService.onCreate");
        sRunning = true;
        startForeground(NOTIFICATION_ID, buildNotification());
        addBar();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Log.i(TAG, "NavBarService.onStartCommand");
        if (mBar == null) {
            addBar();
        }
        return START_STICKY;
    }

    private Notification buildNotification() {
        NotificationManager nm =
                (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL, "Navigation bar", NotificationManager.IMPORTANCE_MIN);
            channel.setShowBadge(false);
            nm.createNotificationChannel(channel);
        }
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL)
                : new Notification.Builder(this);
        return builder
                .setContentTitle("Navigation bar")
                .setContentText("running")
                .setSmallIcon(android.R.drawable.ic_menu_more)
                .setPriority(Notification.PRIORITY_MIN)
                .build();
    }

    /** Height the framework itself uses, so the reserved inset matches. */
    private int navBarHeightPx() {
        int id = getResources().getIdentifier("navigation_bar_height", "dimen", "android");
        if (id != 0) {
            return getResources().getDimensionPixelSize(id);
        }
        float density = getResources().getDisplayMetrics().density;
        return (int) (48 * density + 0.5f);
    }

    private void addBar() {
        mWindowManager = (WindowManager) getSystemService(WINDOW_SERVICE);
        int height = navBarHeightPx();

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                height,
                TYPE_NAVIGATION_BAR,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.OPAQUE);
        lp.gravity = Gravity.BOTTOM | Gravity.START;
        lp.setTitle("EpdNavBar");

        mBar = new NavBarView(this);
        try {
            mWindowManager.addView(mBar, lp);
            Log.i(TAG, "nav bar window added: type=" + lp.type + " height=" + height);
            MainActivity.report("nav bar window added\nheight=" + height + "px");
        } catch (Throwable t) {
            Log.e(TAG, "addView failed", t);
            MainActivity.report("addView FAILED:\n" + t);
            mBar = null;
        }
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "NavBarService.onDestroy");
        sRunning = false;
        if (mBar != null && mWindowManager != null) {
            try {
                mWindowManager.removeViewImmediate(mBar);
            } catch (Throwable ignored) {
                // process is going away anyway
            }
            mBar = null;
        }
        super.onDestroy();
    }
}
