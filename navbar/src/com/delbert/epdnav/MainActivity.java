package com.delbert.epdnav;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.widget.TextView;

/**
 * Launcher activity.
 *
 * Its real job is to move the package out of the stopped state -- a freshly
 * installed package that has never been launched cannot have its services
 * started, and would not receive BOOT_COMPLETED either. It also asks for the
 * service and reports the outcome on screen, which is a convenient debug channel
 * on an e-ink panel where logcat is not always conclusive.
 *
 * Once this app is installed as a system app (install-system.sh) none of this is
 * needed for boot: android:persistent makes ActivityManagerService start the
 * process, and NavBarApp asks for the service from there.
 */
public class MainActivity extends Activity {
    private static final String TAG = "EpdNavBar";

    private static TextView sStatus;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "MainActivity.onCreate");

        TextView tv = new TextView(this);
        tv.setBackgroundColor(Color.WHITE);
        tv.setTextColor(Color.BLACK);
        tv.setTextSize(16);
        tv.setGravity(Gravity.CENTER);
        tv.setText("EpdNavBar: requesting nav bar...");
        setContentView(tv);
        sStatus = tv;

        NavBarService.requestStart(this);
    }

    /** Called by NavBarService so the result is visible on the e-ink screen. */
    static void report(final String message) {
        final TextView tv = sStatus;
        if (tv == null) {
            return;
        }
        tv.post(new Runnable() {
            @Override
            public void run() {
                tv.setText(message);
            }
        });
    }
}
