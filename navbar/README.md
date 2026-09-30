# EpdNavBar — bottom navigation bar for the Allwinner EPD106 e-reader

Gives this Android 8.1 e-reader the three-button navigation bar
(Back / Home / Recents) that the vendor removed from the ROM.

```
┌──────────────────────────────┐
│ 0:40                         │   status bar  (40px)
├──────────────────────────────┤
│                              │
│         app content          │   758 x 896
│                              │
├──────────────────────────────┤
│    ◀         ◯         ▢     │   this app   (64px)
└──────────────────────────────┘
```

## Why the navigation bar is missing

Not a settings problem, and **not fixable with an RRO overlay**.

* The ROM's `PhoneWindowManager` is stock. It reads
  `bool/config_showNavigationBar`, and `prepareAddWindowLw()` happily binds
  `mNavigationBar` for window type `0x7e3` (`TYPE_NAVIGATION_BAR`) as long as the
  caller holds the signature-level `STATUS_BAR_SERVICE` permission.
* The ROM's own `/vendor/overlay/framework-res__auto_generated_rro.apk` **already
  sets `config_showNavigationBar = true`**, and that overlay *is* applied. So the
  framework already answers "yes, there is a navigation bar".
* The vendor deleted the code that would have used it. In `SystemUI.apk`'s
  `StatusBar.makeStatusBarView()`, the `.line` table jumps from 1089 straight to
  1099 — AOSP's `if (showNav) { createNavigationBar(); }` and the method
  `createNavigationBar()` itself are both gone. Instead the vendor draws Back and
  Menu into the status bar (extra ids `my_stat_home_img_view`,
  `my_stat_more_img` in `PhoneStatusBarView`).

An overlay can replace resources. It cannot put back deleted code. Hence: nothing
ever adds a `TYPE_NAVIGATION_BAR` window, so the framework never carves the bottom
inset and no bar appears.

Full evidence: [`docs/FINDINGS.md`](docs/FINDINGS.md).

## How this app fixes it

It adds the missing window itself, which is all the framework was waiting for.

* Signed with the well-known **AOSP `platform`** key — the same key the device is
  signed with — so the signature-level permissions it declares are actually
  granted. See [`TOOLING.md`](TOOLING.md).
* Adds a `TYPE_NAVIGATION_BAR` (`2019`) window pinned to the bottom, height from
  `navigation_bar_height` (48dp → 64px on this 212dpi panel).
* Home / Back / Recents are the ROM's own icons, lifted out of its
  `SystemUI.apk` (`res/drawable-hdpi-v4/ic_sysbar_{back,home,recent}_dark.png`).
  The `_dark` variants are pure black + alpha, so there is nothing for the e-ink
  panel to dither into grey noise.
* Taps are injected with `Instrumentation.sendKeyDownUpSync` (needs the
  signature-level `INJECT_EVENTS`).
* Installed into `/data` only. **`/system` is never touched.**

## Build and install

Requires WSL with the Android SDK; see [`TOOLING.md`](TOOLING.md).
No Gradle, no external dependencies.

```sh
cd navbar       # from the repo root
./build.sh              # build only  -> build/epdnav.apk
./build.sh --install    # build + adb install
```

Then launch it once, so the package leaves the "stopped" state (a never-launched
package cannot have its services started, and would not receive `BOOT_COMPLETED`
either):

```sh
adb shell am start -n com.delbert.epdnav/.MainActivity
```

The bar appears a few seconds later, and from then on starts automatically on
every boot.

## Auto-start after a reboot

It works, from a plain `/data` install, with **no root**. Getting there took
some reverse engineering, because this ROM's ActivityManager **silently drops**
a `startForegroundService()` it does not like: the call returns normally, throws
nothing, logs nothing, and the service is never created.

Measured behaviour:

| Request issued from | Result |
|---|---|
| `BOOT_COMPLETED` receiver, process launched for the broadcast | dropped |
| ...retried at +3s, +8s, +20s (background process) | all dropped |
| `Activity.onResume`, immediately | dropped |
| `Activity.onResume`, retried 500 ms later | **accepted** |
| `adb shell am start-foreground-service` (root/shell caller) | accepted |

The process importance at the time was logged from `ActivityManager` and was
`100` (`IMPORTANCE_FOREGROUND`) on *both* the dropped and the accepted attempt, so
this is **not** the usual Android 8.0 background-service restriction — it is a
race in this ROM's ActivityManager, which needs a moment after a process becomes
foreground before it will accept a foreground-service start.

So the boot path is:

1. `BootReceiver` receives `BOOT_COMPLETED` — this spawns the process, but the
   process is background, so asking for the service here goes nowhere.
2. It starts `BootActivity`: an invisible, translucent, self-finishing activity.
   Android 8.1 still allows background activity starts (that restriction arrived
   in Android 10).
3. `BootActivity` retries `startForegroundService` every 500 ms until
   `NavBarService.isRunning()` reports the service is up, then finishes. In
   practice the second attempt succeeds, so the bar is up about a second after
   `BOOT_COMPLETED` and the activity is gone before anyone notices it.

The activity has no content view and a `@style/Theme.Transparent` theme, so
nothing is drawn and there is no animation.

`BOOT_COMPLETED` only reaches the app if the package has been launched at least
once, because a never-launched package stays in the stopped state. Hence: launch
it once after installing (see above).

### Optional: privileged-system-app install

`install-system.sh` additionally installs the app to `/system/priv-app` with a
privapp permission whitelist. With `android:persistent="true"` (honoured only for
packages parsed from the system partition, so it is inert for the `/data`
install) `ActivityManagerService` starts the process on boot by itself, removing
the dependence on `BOOT_COMPLETED` and on the retry race, and making the process
unkillable. **This is not needed for auto-start to work** — it is belt and braces,
and it needs root, which the stock build does not provide (`ro.secure=1`, no `su`,
`adbd` refuses to run as root in a production build).

## Leaving the bar running without the launcher icon

The launcher activity has no UI worth looking at — it exists to un-stop the
package and to kick the service off. You can hide its icon from the launcher:

```sh
adb shell pm disable-user com.delbert.epdnav/.MainActivity   # hides icon, keeps service
adb shell pm enable com.delbert.epdnav/.MainActivity         # bring it back
```

This is safe: the service and boot receiver are separate components, and the
package is already un-stopped.

## Undo everything

```sh
adb shell am force-stop com.delbert.epdnav
adb uninstall com.delbert.epdnav
```

The bottom inset disappears immediately and the layout returns to
`mStable=(0,40)-(758,1024)`, i.e. the original `app=758x960`. Nothing in `/system`
was modified, so this is a complete reversal.

## Verifying it is working

```sh
# the window exists, is 64px tall and sits at y=960
adb shell dumpsys window windows | grep -A6 'Window{.*EpdNavBar}'

# the framework bound it as the navigation bar
adb shell dumpsys window policy | grep -E 'mNavigationBar=|BarController'

# the bottom inset is carved out (960 instead of 1024)
adb shell dumpsys window | grep mStable
```

## Two quirks of this ROM worth knowing

**1. A foreground-service start immediately after an activity resumes is silently
dropped.** `startForegroundService()` returns normally, throws nothing, logs
nothing, and does nothing — even with the process at `importance=100`. Retrying
500 ms later succeeds. Both `BootActivity` and `NavBarService.requestStart()`
retry for this reason. If you add code that needs the service up immediately, do
not assume the first call worked — poll `NavBarService.isRunning()`.

**2. Some vendor apps crash on configuration changes.**
Adding a bottom bar changes the app area, which is a configuration change, and
this ROM's SystemUI and Settings have vendor patches with NPEs on that path:

```
com.android.systemui  QuickStatusBarHeader.onFinishInflate:101
                      RadioGroup.setOnCheckedChangeListener on null
com.android.settings  SettingsActivity.onCreate:359
                      MoguSwitchBar.setVisibility on null  (class is vendor-only)
```

Both reproduce **with the bar removed**, so they are pre-existing ROM bugs, not
caused by this app. SystemUI restarts itself when it crashes.

## Layout

```
AndroidManifest.xml                 permissions, activity, service, boot receiver
build.sh                            aapt2 -> javac -> d8 -> zipalign -> apksigner
install-system.sh                   optional: install as a persistent system app
keys/                               AOSP platform signing key (public)
res/drawable-hdpi/                  stock nav icons from the device's SystemUI.apk
res/values/styles.xml               transparent theme for BootActivity
system/etc/permissions/             privapp whitelist, used by install-system.sh
src/com/delbert/epdnav/
  NavBarApp.java                    Application; boot hook when persistent
  MainActivity.java                 un-stops the package, requests the service
  BootActivity.java                 invisible activity; makes the service start stick
  BootReceiver.java                 BOOT_COMPLETED -> BootActivity
  NavBarService.java                foreground service; adds the nav bar window
  NavBarView.java                   draws the bar, handles taps
  KeyInjector.java                  injects BACK/HOME/APP_SWITCH
docs/FINDINGS.md                    the full reverse-engineering write-up
docs/DEVICE-BACKUP.md               device files backed up before starting
```

## Device

| | |
|---|---|
| Model | Allwinner **EPD106** (`virgo_perf1` / `virgo-perf1`) |
| Android | 8.1.0, API 27, `armeabi-v7a` |
| Build | `OPM1.171019.026`, `user`, `ro.secure=1` |
| Display | 758x1024 @ 212dpi, e-ink |
| Root | none — no `su`, `adb root` refused in production builds |
