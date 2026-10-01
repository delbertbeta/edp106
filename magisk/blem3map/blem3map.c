/*
 * blem3map — BLE-M3 翻页器按键重映射（Allwinner EPD106 / Android 8.1）
 *
 * 背景：BLE-M3 不是"按键"式 HID。它的方向键和底部键是拿**鼠标相对位移模拟绝对
 * 坐标**：每次按下先发 REL_X/REL_Y = ±2047 撞到屏幕边角，再走一段固定偏移到
 * 目标点，然后按下左键、拖拽几步、松开。直接用它只能看着光标满屏乱跳。
 *
 * 做法：EVIOCGRAB 独占抓取它（系统从此看不到它，光标不再乱跑），把每个"手势"
 * 翻译成一个按键，经 /dev/uinput 的虚拟键盘注入；中键改成点真正的屏幕中心。
 *
 * 用法:  blem3map [设备名]                默认 "BLE-M3"
 *        Ctrl-C / kill 即退出；退出瞬间抓取自动释放，设备立刻恢复原样。
 * 编译:  ./build.sh（NDK, armv7a）
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define DEV_NAME "BLE-M3"
#define PARK     2047   /* 固件用 ±(2^11-1) 表示"撞到屏幕边角" */
#define TAP_X    379    /* 758x1024 的屏幕正中心 */
#define TAP_Y    512

/* 手势 -> 按键。px/py 是归位方向（-1 = 撞左/上边），mx/my 是归位后的偏移。
 * key 为 0 表示"点一下屏幕中心"。要改映射，只改这张表。 */
static const struct rule {
    int px, py, mx, my, key;
    const char *what;
} rules[] = {
    { -1, -1,  108,  168, KEY_PAGEUP,   "上   -> PageUp"       },
    { -1, +1,  108, -252, KEY_PAGEDOWN, "下   -> PageDown"     },
    { -1, -1,   40,  351, KEY_LEFT,     "左   -> DPAD_LEFT"    },
    { +1, -1,  -82,  351, KEY_RIGHT,    "右   -> DPAD_RIGHT"   },
    { -1, +1,  160, -381, 0,            "中   -> tap 屏幕中心" },
    { -1, +1,  170, -121, KEY_BACK,     "底部 -> Back"         },
};
#define NRULES (sizeof rules / sizeof rules[0])

static int ufd = -1;

static void emit_key(int key)
{
    struct input_event ev[2];

    memset(ev, 0, sizeof ev);
    ev[0].type = EV_KEY;
    ev[0].code = key;
    ev[0].value = 1;
    ev[1].type = EV_SYN;
    ev[1].code = SYN_REPORT;
    if (write(ufd, ev, sizeof ev) != (ssize_t)sizeof ev) {
        perror("uinput key down");
        return;
    }
    ev[0].value = 0;
    write(ufd, ev, sizeof ev);
}

static void tap_center(void)
{
    char cmd[64];

    snprintf(cmd, sizeof cmd, "input tap %d %d", TAP_X, TAP_Y);
    if (system(cmd))
        fprintf(stderr, "blem3map: `%s` 失败\n", cmd);
}

/* 日志时间用开机以来的秒数（和 getevent / 内核日志同一时基），方便事后跟某个现象对账 */
static void stamp(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    fprintf(stderr, "[%9.2f] ", (double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

static void fire(int px, int py, int mx, int my)
{
    unsigned i;

    for (i = 0; i < NRULES; i++) {
        if (rules[i].px == px && rules[i].py == py &&
            rules[i].mx == mx && rules[i].my == my) {
            stamp();
            fprintf(stderr, "blem3map: %s\n", rules[i].what);
            if (rules[i].key)
                emit_key(rules[i].key);
            else
                tap_center();
            return;
        }
    }
    stamp();
    fprintf(stderr, "blem3map: 未知手势 park(%d,%d) move(%d,%d)，忽略\n",
            px, py, mx, my);
}

static int uinput_setup(void)
{
    struct uinput_user_dev dev;
    int fd;
    unsigned i;

    if ((fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK)) < 0) {
        perror("open /dev/uinput");
        return -1;
    }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (i = 0; i < NRULES; i++)
        if (rules[i].key)
            ioctl(fd, UI_SET_KEYBIT, rules[i].key);

    memset(&dev, 0, sizeof dev);
    snprintf(dev.name, UINPUT_MAX_NAME_SIZE, "blem3map");
    dev.id.bustype = BUS_VIRTUAL;
    dev.id.vendor = 0x1209;
    dev.id.product = 0x0001;
    dev.id.version = 1;
    if (write(fd, &dev, sizeof dev) != (ssize_t)sizeof dev) {
        perror("uinput write");
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return -1;
    }
    return fd;
}

static int open_clicker(const char *want)
{
    char path[64], name[128];
    int i;

    for (i = 0; i < 32; i++) {
        int fd;

        snprintf(path, sizeof path, "/dev/input/event%d", i);
        if ((fd = open(path, O_RDONLY)) < 0)
            continue;
        memset(name, 0, sizeof name);
        if (ioctl(fd, EVIOCGNAME(sizeof name - 1), name) > 0 &&
            !strcmp(name, want))
            return fd;
        close(fd);
    }
    return -1;
}

static void run(int fd)
{
    struct input_event ev;
    int px = 0, py = 0;     /* 当前归位方向 */
    int mx = 0, my = 0;     /* 归位后的偏移 = 目标点 */
    int armed = 0;          /* 已归位，等偏移和左键按下 */
    int emitted = 0;        /* 这一轮按压已经翻译过了 */

    while (read(fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type == EV_REL) {
            if (ev.value == PARK || ev.value == -PARK) {
                if (ev.code == REL_X)
                    px = ev.value > 0 ? 1 : -1;
                else if (ev.code == REL_Y)
                    py = ev.value > 0 ? 1 : -1;
                armed = 1;
                emitted = 0;
            } else if (ev.code == REL_X) {
                mx = ev.value;
            } else if (ev.code == REL_Y) {
                my = ev.value;
            }
            continue;
        }
        if (ev.type == EV_KEY && ev.value == 1) {
            if (ev.code == BTN_MOUSE && armed && !emitted) {
                /* 真按压一定带一次左键按下；"回位"动作不带 —— 靠这个区分，
                 * 否则一次按压会被翻译成两下 */
                fire(px, py, mx, my);
                armed = 0;
                emitted = 1;
            } else if (ev.code == KEY_VOLUMEUP || ev.code == KEY_VOLUMEDOWN) {
                /* 底部键偶尔只发音量、不带坐标，同样当返回处理 */
                if (!emitted) {
                    emit_key(KEY_BACK);
                    emitted = 1;
                }
            }
        }
    }
    perror("read /dev/input");
}

int main(int argc, char **argv)
{
    const char *want = argc > 1 ? argv[1] : DEV_NAME;
    int waited = 0;

    if ((ufd = uinput_setup()) < 0)
        return 1;

    for (;;) {
        int fd = open_clicker(want);

        if (fd < 0) {
            if (!waited) {              /* 进入等待时只打一行，别每 2 秒刷屏 */
                stamp();
                fprintf(stderr, "blem3map: 等 %s 出现…\n", want);
                waited = 1;
            }
            sleep(2);
            continue;
        }
        waited = 0;
        if (ioctl(fd, EVIOCGRAB, 1) < 0) {
            perror("EVIOCGRAB");
            close(fd);
            sleep(2);
            continue;
        }
        stamp();
        fprintf(stderr, "blem3map: 已独占抓取 %s\n", want);
        run(fd);
        ioctl(fd, EVIOCGRAB, 0);
        close(fd);
        sleep(1);
    }
}
