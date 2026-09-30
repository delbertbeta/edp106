package com.delbert.epdnav;

import android.content.Context;
import android.content.res.Resources;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.drawable.Drawable;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;

/**
 * The navigation bar surface: Back, Home and Recents, one third of the width
 * each, matching the platform's own arrangement.
 *
 * Icons are lifted from this ROM's own SystemUI.apk
 * (res/drawable-hdpi-v4/ic_sysbar_{back,home,recent}_dark.png) rather than drawn
 * by hand, so they are the real stock shapes. The `_dark` variants are pure
 * black with an alpha channel, which is exactly right for a white bar on an
 * e-ink panel: no anti-aliased mid-greys for the panel to dither into noise.
 * They are drawn at intrinsic size, which the resource system already scales from
 * hdpi (240dpi) down to this panel's 212dpi.
 */
class NavBarView extends View {
    private static final String TAG = "EpdNavBar";

    private static final int BACK = 0;
    private static final int HOME = 1;
    private static final int RECENTS = 2;

    /** Drawable names inside this APK, in layout order. */
    private static final String[] ICONS = {
            "ic_sysbar_back_dark",
            "ic_sysbar_home_dark",
            "ic_sysbar_recent_dark",
    };

    private final Drawable[] mIcons = new Drawable[ICONS.length];
    private final Paint mFill = new Paint(Paint.ANTI_ALIAS_FLAG);

    private int mPressed = -1;

    NavBarView(Context context) {
        super(context);
        mFill.setColor(Color.BLACK);
        setBackgroundColor(Color.WHITE);

        Resources res = context.getResources();
        String pkg = context.getPackageName();
        for (int i = 0; i < ICONS.length; i++) {
            int id = res.getIdentifier(ICONS[i], "drawable", pkg);
            if (id != 0) {
                mIcons[i] = res.getDrawable(id);
            }
            Log.i(TAG, "icon " + ICONS[i] + " -> " + (mIcons[i] != null ? "loaded" : "MISSING"));
        }
    }

    private float columnWidth() {
        return getWidth() / 3f;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        final int height = getHeight();

        if (mPressed >= 0) {
            float column = columnWidth();
            mFill.setColor(0xFFDDDDDD);
            canvas.drawRect(column * mPressed, 0, column * (mPressed + 1), height, mFill);
            mFill.setColor(Color.BLACK);
        }

        final float cy = height / 2f;
        for (int i = 0; i < mIcons.length; i++) {
            Drawable icon = mIcons[i];
            if (icon == null) {
                continue;
            }
            float cx = columnWidth() * (i + 0.5f);
            int w = icon.getIntrinsicWidth();
            int h = icon.getIntrinsicHeight();
            icon.setBounds((int) (cx - w / 2f), (int) (cy - h / 2f),
                    (int) (cx + w / 2f), (int) (cy + h / 2f));
            icon.draw(canvas);
        }
    }

    private void setPressed(int index) {
        if (mPressed == index) {
            return;
        }
        mPressed = index;
        invalidateColumn(index);
    }

    private void clearPressed() {
        if (mPressed < 0) {
            return;
        }
        int previous = mPressed;
        mPressed = -1;
        invalidateColumn(previous);
    }

    /** Repaint only this column -- e-ink refresh cost is per changed area. */
    private void invalidateColumn(int index) {
        float column = columnWidth();
        invalidate((int) (column * index), 0, (int) (column * (index + 1)), getHeight());
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        float column = columnWidth();
        int index = (int) (event.getX() / column);
        if (index < 0) {
            index = 0;
        } else if (index > ICONS.length - 1) {
            index = ICONS.length - 1;
        }

        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                setPressed(index);
                return true;
            case MotionEvent.ACTION_UP:
                clearPressed();
                switch (index) {
                    case BACK:
                        KeyInjector.send(KeyInjector.back());
                        break;
                    case HOME:
                        KeyInjector.send(KeyInjector.home());
                        break;
                    default:
                        KeyInjector.send(KeyInjector.recents());
                        break;
                }
                return true;
            case MotionEvent.ACTION_CANCEL:
                clearPressed();
                return true;
            default:
                return super.onTouchEvent(event);
        }
    }
}
