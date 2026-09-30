package com.delbert.epdnav;

import android.app.Application;
import android.content.Context;

/**
 * Application entry point.
 *
 * When this APK is installed as a system app (see install-system.sh) the
 * manifest's android:persistent="true" is honoured -- PackageParser only sets
 * ApplicationInfo.FLAG_PERSISTENT when the package is parsed from the system
 * partition -- and ActivityManagerService launches this process by itself during
 * boot, via startPersistentApps(). That is the boot hook: it does not rely on
 * BOOT_COMPLETED being delivered, and it does not rely on the package having been
 * launched by the user first.
 *
 * For a /data install the persistent flag is ignored and this class simply does
 * nothing useful until the user opens the app -- the existing behaviour.
 */
public class NavBarApp extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        // Idempotent: NavBarService tolerates being requested repeatedly, and
        // requestStart() retries because this ROM silently drops a
        // startForegroundService() issued from a process it has not yet marked
        // foreground.
        NavBarService.requestStart(this);
    }

    /** Kept so callers do not need their own Context plumbing. */
    static Context appContext(Context any) {
        return any.getApplicationContext();
    }
}
