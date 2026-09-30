package com.delbert.epdnav;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Boot hook.
 *
 * Asks BootActivity to come to the foreground, which is what makes the service
 * start get accepted -- see BootActivity for the measurements showing that a
 * request from a background process is silently dropped on this ROM.
 *
 * When the app is installed as a system app with android:persistent="true",
 * ActivityManagerService starts the process by itself and NavBarApp handles it,
 * so this receiver becomes a harmless second path.
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "EpdNavBar";

    @Override
    public void onReceive(Context context, Intent intent) {
        Log.i(TAG, "BootReceiver.onReceive: " + intent.getAction());
        Intent foreground = new Intent(context, BootActivity.class);
        foreground.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_CLEAR_TOP
                | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        try {
            context.startActivity(foreground);
            Log.i(TAG, "BootReceiver: started BootActivity");
        } catch (Throwable t) {
            Log.e(TAG, "BootReceiver: could not start BootActivity", t);
            // fall back to asking directly; it works if the process already
            // happens to be foreground
            NavBarService.requestStart(context);
        }
    }
}
