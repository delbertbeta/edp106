package com.delbert.epdnav;

import android.app.Instrumentation;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.KeyEvent;

/**
 * Injects a global key press.
 *
 * Instrumentation.sendKeyDownUpSync() is public API and needs the
 * signature-level INJECT_EVENTS permission, which this APK holds because it is
 * signed with the device's own platform key. It refuses to run on the app's main
 * thread, so injections are posted to a dedicated worker thread.
 */
final class KeyInjector {
    private static Handler sHandler;

    private KeyInjector() {
    }

    static void send(int keyCode) {
        if (sHandler == null) {
            HandlerThread thread = new HandlerThread("keyinject");
            thread.start();
            sHandler = new Handler(thread.getLooper());
        }
        final int code = keyCode;
        sHandler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    new Instrumentation().sendKeyDownUpSync(code);
                } catch (Throwable ignored) {
                    // the tap simply has no effect
                }
            }
        });
    }

    static int back() {
        return KeyEvent.KEYCODE_BACK;
    }

    static int home() {
        return KeyEvent.KEYCODE_HOME;
    }

    static int recents() {
        return KeyEvent.KEYCODE_APP_SWITCH;
    }
}
