package com.delbert.btpan;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.ParcelUuid;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * 收到 com.delbert.btpan.RECONNECT 之后，把蓝牙 PAN 连回来。
 *
 * 只连 SDP 里真的带 NAP（0x1116，蓝牙共享网络）的已配对设备 —— 不无脑试。
 * 本机实测：BLE-M3 只有 HID(0x1812) 被跳过；手机带 PANU(0x1115)+NAP(0x1116) 被选中。
 *
 * 为什么必须是真 app：PanService 不在 servicemanager 里，connect() 只能在 Java 侧经
 * getProfileProxy 调到，而那条路要 Context.bindService —— AMS 按 pid 归属调用方，
 * app_process 没有 app 记录，必被拒（getProfileProxy 和 bluetooth_manager.bind*
 * 两条路都实测失败）。所以这一小步必须跑在 app 进程里。
 */
public class PanConnectReceiver extends BroadcastReceiver {
    static final String TAG = "BtPanStby";
    static final int PAN = 5;                    // BluetoothProfile.PAN，SDK 里是 @hide
    static final UUID NAP = UUID.fromString("00001116-0000-1000-8000-00805F9B34FB");
    static final long ENABLE_WAIT_MS = 30000;    // 蓝牙栈起来慢，实测 enable 后约 15s PanService 才 ready
    static final long PROXY_WAIT_MS = 20000;

    @Override
    public void onReceive(Context ctx, Intent intent) {
        final PendingResult pr = goAsync();       // 允许我们在返回后继续干活
        final Context app = ctx.getApplicationContext();
        new Thread(new Runnable() {
            public void run() {
                try {
                    connect(app);
                } catch (Throwable t) {
                    Log.e(TAG, "失败", t);
                } finally {
                    pr.finish();
                }
            }
        }, "btpan-connect").start();
    }

    static void connect(Context ctx) throws Exception {
        BluetoothAdapter ad = BluetoothAdapter.getDefaultAdapter();
        if (ad == null) { Log.e(TAG, "没有蓝牙适配器"); return; }

        long until = System.currentTimeMillis() + ENABLE_WAIT_MS;
        while (!ad.isEnabled() && System.currentTimeMillis() < until) Thread.sleep(500);
        if (!ad.isEnabled()) { Log.e(TAG, "等蓝牙打开超时"); return; }

        final Object[] holder = new Object[1];
        final CountDownLatch ready = new CountDownLatch(1);
        ad.getProfileProxy(ctx, new BluetoothProfile.ServiceListener() {
            public void onServiceConnected(int profile, BluetoothProfile proxy) {
                if (profile == PAN) { holder[0] = proxy; ready.countDown(); }
            }
            public void onServiceDisconnected(int profile) {
                if (profile == PAN) ready.countDown();
            }
        }, PAN);

        if (!ready.await(PROXY_WAIT_MS, TimeUnit.MILLISECONDS) || holder[0] == null) {
            Log.e(TAG, "拿不到 PAN 代理");
            return;
        }
        Object pan = holder[0];

        Set<BluetoothDevice> bonded = ad.getBondedDevices();
        if (bonded == null) return;
        for (BluetoothDevice d : bonded) {
            if (!supportsNap(d)) {
                Log.i(TAG, "跳过 " + d.getAddress() + " " + d.getName() + "（无 NAP）");
                continue;
            }
            if (isConnected(pan, d.getAddress())) {
                Log.i(TAG, "已在连 " + d.getAddress());
                return;
            }
            Method m = Class.forName("android.bluetooth.BluetoothPan")
                    .getMethod("connect", BluetoothDevice.class);
            Object ok = m.invoke(pan, d);
            Log.i(TAG, "发起连接 " + d.getAddress() + " -> " + ok);
            return;                               // 连接是异步的，发起了就算完成
        }
        Log.w(TAG, "没有支持 NAP 的已配对设备");
    }

    /** UUIDS 没缓存时退回"非 LE 单模"。 */
    static boolean supportsNap(BluetoothDevice d) {
        ParcelUuid[] uu = d.getUuids();
        if (uu == null) return d.getType() != BluetoothDevice.DEVICE_TYPE_LE;
        for (ParcelUuid u : uu) if (NAP.equals(u.getUuid())) return true;
        return false;
    }

    @SuppressWarnings("unchecked")
    static boolean isConnected(Object pan, String mac) throws Exception {
        Method m = pan.getClass().getMethod("getConnectedDevices");
        List<BluetoothDevice> ds = (List<BluetoothDevice>) m.invoke(pan);
        for (BluetoothDevice d : ds) if (d.getAddress().equalsIgnoreCase(mac)) return true;
        return false;
    }
}
