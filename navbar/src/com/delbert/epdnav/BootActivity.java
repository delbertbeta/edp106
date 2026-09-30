package com.delbert.epdnav;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.util.List;

/**
 * Transparent, self-finishing activity used to get a foreground process at boot.
 *
 * Why this is needed: this ROM's ActivityManager silently drops a
 * startForegroundService() issued while the process is not foreground -- no
 * exception, no log, nothing. Measured at boot from the broadcast-started process:
 * eight attempts spread over 20 seconds, all dropped.
 *
 * Android 8.1 still permits starting an activity from the background (that
 * restriction arrived in Android 10), so the boot receiver starts this activity.
 *
 * Important detail: the process does not become foreground the instant the
 * activity resumes -- ActivityManagerService updates process importance on its own
 * handler. An earlier version of this class called finish() in the same
 * millisecond as the request and the request was still dropped, so it now stays up
 * and retries until the service actually reports itself running.
 *
 * The theme is translucent and there is no content view, so the user sees nothing.
 */
public class BootActivity extends Activity {
    private static final String TAG = "EpdNavBar";

    private static final long RETRY_MS = 500;
    private static final long GIVE_UP_MS = 15000;

    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private long mStartedAt;
    private boolean mFinished;

    private final Runnable mAttempt = new Runnable() {
        @Override
        public void run() {
            if (mFinished) {
                return;
            }
            if (NavBarService.isRunning()) {
                Log.i(TAG, "BootActivity: service is up, finishing");
                finishOnce();
                return;
            }
            Log.i(TAG, "BootActivity: importance=" + importanceName()
                    + ", requesting service");
            NavBarService.requestStart(BootActivity.this);

            if (System.currentTimeMillis() - mStartedAt > GIVE_UP_MS) {
                Log.w(TAG, "BootActivity: giving up after " + GIVE_UP_MS + "ms");
                finishOnce();
                return;
            }
            mHandler.postDelayed(this, RETRY_MS);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "BootActivity.onCreate");
        mStartedAt = System.currentTimeMillis();
    }

    @Override
    protected void onResume() {
        super.onResume();
        Log.i(TAG, "BootActivity.onResume");
        mHandler.post(mAttempt);
    }

    @Override
    protected void onPause() {
        mHandler.removeCallbacks(mAttempt);
        super.onPause();
    }

    private void finishOnce() {
        if (!mFinished) {
            mFinished = true;
            Log.i(TAG, "BootActivity.finish");
            finish();
        }
    }

    @Override
    public void finish() {
        super.finish();
        // No animation: this activity is invisible, there is nothing to animate.
        overridePendingTransition(0, 0);
    }

    /** Diagnostic: our own process importance, straight from ActivityManager. */
    private String importanceName() {
        try {
            ActivityManager am =
                    (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            List<ActivityManager.RunningAppProcessInfo> procs = am.getRunningAppProcesses();
            if (procs != null) {
                int myPid = android.os.Process.myPid();
                for (ActivityManager.RunningAppProcessInfo info : procs) {
                    if (info.pid == myPid) {
                        return info.importance + "/" + info.importanceReasonCode;
                    }
                }
            }
            return "?";
        } catch (Throwable t) {
            return "err";
        }
    }
}
