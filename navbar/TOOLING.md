# Toolchain

Everything lives in the WSL Debian image; nothing is installed on Windows.

| Tool | Path |
|---|---|
| Android build-tools | `/opt/android-sdk/build-tools/35.0.0` (also 36.0.0) |
| `android.jar` (compile SDK) | `/opt/android-sdk/platforms/android-36/android.jar` |
| `javac` | `openjdk-21-jdk-headless` (installed during this work) |
| Python | `python3` 3.13, system |

Overridable via environment variables in `build.sh`: `BT`, `PLATFORM`, `KEY`, `CERT`.

Device: Allwinner **EPD106** (`virgo_perf1`), Android 8.1.0 / API 27, `armeabi-v7a`.

## Why no Gradle

The build is five commands long. Gradle would add a daemon, a wrapper, a network
dependency on the Android plugin, and a project scaffold far larger than the app.
`aapt2` + `javac` + `d8` + `zipalign` + `apksigner` is the whole pipeline.

## Why we sign with the platform key

The device is signed with the well-known AOSP `platform` key, so its signature
checks accept an APK signed with the same key. That is what makes the
signature-level permissions this app needs grantable without root:

    SHA-1   27196E386B875E76ADF700E7EA84E4C6EEE33DFA
    SHA-256 C8A2E9BCCF597C2FB6DC66BEE293FC13F2FC47EC77BC6B2B0D52C11F51192AB8

The private key is public (AOSP `build/target/product/security/platform.pk8`),
which is why `keys/` is committed here. It is only dangerous when *every* device
on earth ships with it -- which is a property of the ROM, not of this project.
