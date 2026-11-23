/*
 * MagicTrackpoint — pure logic, no system side effects.
 *
 * Everything here is deterministic and unit-tested (tests/core_test.m):
 * configuration validation, HID report encoding/decoding, the middle-button
 * gesture state machine and the event-tap filtering decision.
 *
 * Copyright (C) 2026 Jean-Christophe Baptiste
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version. It is distributed WITHOUT ANY WARRANTY; see LICENSE.
 */
#ifndef MTP_CORE_H
#define MTP_CORE_H

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Supported hardware (exact match only) ───────────────────────────────── */
#define MTP_LENOVO_VID 0x17EF
#define MTP_USB_PID    0x60EE   /* TrackPoint Keyboard II, USB receiver   */
#define MTP_BLE_PID    0x60E1   /* TrackPoint Keyboard II, Bluetooth LE   */

/* Configuration commands (USB Feature 0x13 / BLE Output 0x18). Fn Lock
 * (0x05) exists in the firmware but is deliberately never sent. */
#define MTP_CMD_SENSITIVITY      0x02
#define MTP_CMD_PREFERRED_SCROLL 0x09

/* One firmware scroll unit is rendered as one macOS "line", which Quartz
 * defines as 10 pixels (measured: a 1-line event carries a 10-point delta). */
#define MTP_PIXELS_PER_UNIT 10.0

/* Marks our own synthetic events (kCGEventSourceUserData). */
#define MTP_EVENT_MAGIC 0x4D54504Bll  /* "MTPK" */

/* ── Configuration ───────────────────────────────────────────────────────── */
typedef enum { MTP_LOG_ERROR = 0, MTP_LOG_INFO = 1, MTP_LOG_DEBUG = 2 } MTPLogLevel;

typedef struct {
    int sensitivity;        /* 1–9, hardware level                          */
    bool scrollEnabled;     /* firmware Preferred Scrolling + our handling  */
    double speed;           /* multiplier, 0.1–10                           */
    double acceleration;    /* force curve: units^(1+a), 0 (linear)–2       */
    bool horizontal;        /* emit horizontal scrolling                    */
    int threshold;          /* firmware scroll units before scrolling, 0–50 */
    bool clickIfNoScroll;   /* emit a middle click when no scroll happened  */
    bool keyMicrophone;     /* F4: mute/unmute the default microphone       */
    bool keyBluetooth;      /* F10: Control Center, Bluetooth module         */
    bool keyScreenshot;     /* Print Screen: send ⇧⌘5                        */
    MTPLogLevel logLevel;
} MTPConfig;

static inline MTPConfig mtp_default_config(void) {
    return (MTPConfig){ .sensitivity = 7, .scrollEnabled = true, .speed = 1.0,
        .acceleration = 1.0, .horizontal = true, .threshold = 3, .clickIfNoScroll = true,
        .keyMicrophone = true, .keyBluetooth = true, .keyScreenshot = true,
        .logLevel = MTP_LOG_ERROR };
}

/* Defaults for a configuration file that exists but cannot be used. Scrolling
 * is the only feature that makes keyboard reports reach this process: when the
 * user's choice cannot be read, it stays off (fail closed) rather than falling
 * back to the default "on". A missing file still means plain defaults. */
static inline MTPConfig mtp_failed_config(void) {
    MTPConfig c = mtp_default_config();
    c.scrollEnabled = false;
    return c;
}

static inline bool mtp_is_bool(id v) {
    return [v isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID();
}
static inline bool mtp_is_number(id v) {
    return [v isKindOfClass:NSNumber.class] && !mtp_is_bool(v);
}

/* Names coming from the file are shown in errors: strip control characters
 * so a hostile file cannot inject terminal escape sequences. */
static inline NSString *mtp_printable(id name) {
    NSString *s = [name isKindOfClass:NSString.class] ? name : [name description];
    if (s.length > 64) s = [[s substringToIndex:64] stringByAppendingString:@"…"];
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0)) c = '?';
        [out appendFormat:@"%C", c];
    }
    return out;
}

/* Reads one key of one section into *out. Invalid values keep the default
 * and append a message; absent keys silently keep the default. */
static void mtp_cfg_int(NSDictionary *sec, NSString *section, NSString *key,
                        int lo, int hi, int *out, NSMutableArray *errors) {
    id v = sec[key];
    if (!v) return;
    double d = mtp_is_number(v) ? [v doubleValue] : NAN;
    if (!isfinite(d) || d != floor(d) || d < lo || d > hi) {
        [errors addObject:[NSString stringWithFormat:
            @"%@.%@ must be an integer between %d and %d", section, key, lo, hi]];
        return;
    }
    *out = (int)d;
}
static void mtp_cfg_double(NSDictionary *sec, NSString *section, NSString *key,
                           double lo, double hi, double *out, NSMutableArray *errors) {
    id v = sec[key];
    if (!v) return;
    double d = mtp_is_number(v) ? [v doubleValue] : NAN;
    if (!isfinite(d) || d < lo || d > hi) {
        [errors addObject:[NSString stringWithFormat:
            @"%@.%@ must be a number between %g and %g", section, key, lo, hi]];
        return;
    }
    *out = d;
}
static void mtp_cfg_bool(NSDictionary *sec, NSString *section, NSString *key,
                         bool *out, NSMutableArray *errors) {
    id v = sec[key];
    if (!v) return;
    if (!mtp_is_bool(v)) {
        [errors addObject:[NSString stringWithFormat:
            @"%@.%@ must be a boolean (<true/> or <false/>)", section, key]];
        return;
    }
    *out = [v boolValue];
}

/* Validates a parsed property list. Never fails: every invalid or unknown
 * entry is reported in `errors` and the default value is kept for it. */
static MTPConfig mtp_config_from_plist(id plist, NSMutableArray<NSString *> *errors) {
    MTPConfig c = mtp_default_config();
    if (!plist) return c;
    if (![plist isKindOfClass:NSDictionary.class]) {
        [errors addObject:@"the top level must be a dictionary"];
        return mtp_failed_config();
    }
    NSDictionary *known = @{
        @"trackpoint": @[@"sensitivity"],
        @"scroll": @[@"enabled", @"speed", @"acceleration", @"horizontal", @"threshold"],
        @"middle_button": @[@"click_if_no_scroll"],
        @"keys": @[@"microphone", @"bluetooth", @"screenshot"],
        @"logging": @[@"level"],
    };
    for (id name in plist) {
        NSArray *keys = [name isKindOfClass:NSString.class] ? known[name] : nil;
        if (!keys) {
            [errors addObject:[NSString stringWithFormat:@"unknown section '%@'", mtp_printable(name)]];
            continue;
        }
        id sec = plist[name];
        if (![sec isKindOfClass:NSDictionary.class]) {
            [errors addObject:[NSString stringWithFormat:@"%@ must be a dictionary", mtp_printable(name)]];
            continue;
        }
        for (id key in sec)
            if (![keys containsObject:key])
                [errors addObject:[NSString stringWithFormat:@"unknown key '%@.%@'", mtp_printable(name),
                                   mtp_printable(key)]];
    }
    NSDictionary *(^section)(NSString *) = ^NSDictionary *(NSString *n) {
        id s = plist[n];
        return [s isKindOfClass:NSDictionary.class] ? s : @{};
    };
    mtp_cfg_int(section(@"trackpoint"), @"trackpoint", @"sensitivity", 1, 9, &c.sensitivity, errors);
    NSDictionary *scroll = section(@"scroll");
    if (plist[@"scroll"] && ![plist[@"scroll"] isKindOfClass:NSDictionary.class])
        c.scrollEnabled = false;                    /* unreadable choice: off */
    if (scroll[@"enabled"] && !mtp_is_bool(scroll[@"enabled"]))
        c.scrollEnabled = false;
    mtp_cfg_bool(scroll, @"scroll", @"enabled", &c.scrollEnabled, errors);
    mtp_cfg_double(scroll, @"scroll", @"speed", 0.1, 10.0, &c.speed, errors);
    mtp_cfg_double(scroll, @"scroll", @"acceleration", 0.0, 2.0, &c.acceleration, errors);
    mtp_cfg_bool(scroll, @"scroll", @"horizontal", &c.horizontal, errors);
    mtp_cfg_int(scroll, @"scroll", @"threshold", 0, 50, &c.threshold, errors);
    mtp_cfg_bool(section(@"middle_button"), @"middle_button", @"click_if_no_scroll",
                 &c.clickIfNoScroll, errors);
    NSDictionary *keys = section(@"keys");
    mtp_cfg_bool(keys, @"keys", @"microphone", &c.keyMicrophone, errors);
    mtp_cfg_bool(keys, @"keys", @"bluetooth", &c.keyBluetooth, errors);
    mtp_cfg_bool(keys, @"keys", @"screenshot", &c.keyScreenshot, errors);
    id level = section(@"logging")[@"level"];
    if (level) {
        NSUInteger i = [level isKindOfClass:NSString.class]
            ? [@[@"error", @"info", @"debug"] indexOfObject:level] : NSNotFound;
        if (i == NSNotFound)
            [errors addObject:@"logging.level must be \"error\", \"info\" or \"debug\""];
        else
            c.logLevel = (MTPLogLevel)i;
    }
    return c;
}

/* Loads a configuration file. A missing file is not an error (defaults). */
#define MTP_CONFIG_MAX_BYTES 65536
static MTPConfig mtp_config_load(NSString *path, NSMutableArray<NSString *> *errors,
                                 bool *exists) {
    *exists = false;
    /* One descriptor for check and read: no race, and O_NONBLOCK keeps a
     * FIFO from blocking the daemon. Symlinks are followed (dotfiles). */
    if (!path.length) return mtp_default_config();
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno != ENOENT && errno != ENOTDIR) {
            *exists = true;
            [errors addObject:[NSString stringWithFormat:@"cannot open: %s", strerror(errno)]];
            return mtp_failed_config();
        }
        return mtp_default_config();
    }
    *exists = true;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > MTP_CONFIG_MAX_BYTES) {
        close(fd);
        [errors addObject:@"not a regular file of at most 64 KiB"];
        return mtp_failed_config();
    }
    NSMutableData *data = [NSMutableData dataWithLength:MTP_CONFIG_MAX_BYTES + 1];
    ssize_t total = 0, n;
    while (total <= MTP_CONFIG_MAX_BYTES &&
           (n = read(fd, (char *)data.mutableBytes + total,
                     (size_t)(MTP_CONFIG_MAX_BYTES + 1 - total))) > 0)
        total += n;
    close(fd);
    if (total > MTP_CONFIG_MAX_BYTES) {                 /* grew after the check */
        [errors addObject:@"not a regular file of at most 64 KiB"];
        return mtp_failed_config();
    }
    data.length = (NSUInteger)total;
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:&error];
    if (!plist) {
        [errors addObject:[NSString stringWithFormat:@"unreadable property list: %@",
                           error.localizedDescription ?: @"unknown error"]];
        return mtp_failed_config();
    }
    return mtp_config_from_plist(plist, errors);
}

/* ── Lenovo top-row keys ─────────────────────────────────────────────────── */
/* Several top-row keys (F4 microphone, F8–F12) send vendor report 0x05 instead
 * of a standard key, which macOS ignores. The report carries a 13-bit code
 * (measured on the Bluetooth keyboard, 2026-11-23: F4 0x0BB, F8 0x0C1,
 * F9 0x0BC, F10 0x0B6, F11 0x1B7, F12 0x0B8; 0 on release). Its descriptor
 * declares the code as 13 one-bit elements of page 0xFF00 (usages
 * 0xF1–0xFD), so IOKit delivers it bit by bit: the daemon matches only that
 * page, which never carries typing, and rebuilds the code. */
#define MTP_KEYS_PAGE      0xFF00
#define MTP_KEYS_REPORT    0x05
#define MTP_KEYS_FIRST     0xF1
#define MTP_KEYS_BITS      13
#define MTP_CODE_MICROPHONE 0x0BB   /* F4  */
#define MTP_CODE_BLUETOOTH  0x0B6   /* F10 */

/* Print Screen is a standard key (keyboard page 0x07, usage 0x46; macOS treats
 * it as F13). Only this one usage is matched, never the rest of the typing. */
#define MTP_PRINT_SCREEN_PAGE  0x07
#define MTP_PRINT_SCREEN_USAGE 0x46

typedef enum { MTP_KEY_NONE = 0, MTP_KEY_MICROPHONE, MTP_KEY_BLUETOOTH,
               MTP_KEY_SCREENSHOT } MTPKey;

typedef struct {
    uint16_t bits;      /* code being rebuilt from the bit elements          */
    uint16_t pressed;   /* code acted upon, until the release (code 0)       */
} MTPKeyState;

/* One bit element of report 0x05 changed. False if it is not one. */
static inline bool mtp_key_bit(MTPKeyState *s, uint32_t reportID, uint32_t page,
                               uint32_t usage, bool on) {
    if (reportID != MTP_KEYS_REPORT || page != MTP_KEYS_PAGE ||
        usage < MTP_KEYS_FIRST || usage >= MTP_KEYS_FIRST + MTP_KEYS_BITS) return false;
    uint16_t bit = (uint16_t)(1u << (usage - MTP_KEYS_FIRST));
    s->bits = on ? (uint16_t)(s->bits | bit) : (uint16_t)(s->bits & ~bit);
    return true;
}

/* Called once all elements of a report were delivered. Returns the key newly
 * pressed (once per press), MTP_KEY_NONE otherwise. */
static inline MTPKey mtp_key_settle(MTPKeyState *s) {
    if (!s->bits) { s->pressed = 0; return MTP_KEY_NONE; }
    if (s->pressed) return MTP_KEY_NONE;      /* still held, or a chord */
    s->pressed = s->bits;
    switch (s->bits) {
    case MTP_CODE_MICROPHONE: return MTP_KEY_MICROPHONE;
    case MTP_CODE_BLUETOOTH:  return MTP_KEY_BLUETOOTH;
    default:                  return MTP_KEY_NONE;
    }
}

/* Whether a key is enabled in the configuration. */
static inline bool mtp_key_enabled(MTPKey k, const MTPConfig *cfg) {
    switch (k) {
    case MTP_KEY_MICROPHONE: return cfg->keyMicrophone;
    case MTP_KEY_BLUETOOTH:  return cfg->keyBluetooth;
    case MTP_KEY_SCREENSHOT: return cfg->keyScreenshot;
    default:                 return false;
    }
}

static inline bool mtp_any_key_enabled(const MTPConfig *cfg) {
    return cfg->keyMicrophone || cfg->keyBluetooth || cfg->keyScreenshot;
}

/* ── HID reports ─────────────────────────────────────────────────────────── */
typedef struct {
    bool feature;       /* true: Feature report (USB); false: Output (BLE) */
    uint8_t reportID;
    uint8_t bytes[8];
    long length;
} MTPConfigReport;

static inline bool mtp_build_config_report(int productID, uint8_t command,
                                           uint8_t value, MTPConfigReport *r) {
    memset(r, 0, sizeof *r);
    if (productID == MTP_USB_PID) { r->feature = true;  r->reportID = 0x13; r->length = 8; }
    else if (productID == MTP_BLE_PID) { r->feature = false; r->reportID = 0x18; r->length = 3; }
    else return false;
    r->bytes[0] = r->reportID;
    r->bytes[1] = command;
    r->bytes[2] = value;
    return true;
}

/* Native Preferred Scrolling report 0x16: [0x16, horizontal, vertical]. */
static inline bool mtp_decode_wheel(uint32_t reportID, const uint8_t *report,
                                    long length, uint8_t *h, uint8_t *v) {
    if (reportID != 0x16 || !report || length != 3 || report[0] != 0x16) return false;
    *h = report[1];
    *v = report[2];
    return true;
}

/* Bluetooth vendor middle-button report 0x15 (9 bytes): bit 0x04 of byte 2. */
static inline bool mtp_decode_ble_middle(uint32_t reportID, const uint8_t *report,
                                         long length, bool *down) {
    if (reportID != 0x15 || !report || length != 9 || report[0] != 0x15) return false;
    *down = (report[2] & 0x04) != 0;
    return true;
}

/* Bluetooth mouse report 0x02: [02, buttons, X, Y, wheel]. Only what the
 * daemon needs: button 3, whether the pointer moved, whether a native wheel
 * value is present. */
typedef struct { bool middle, motion, wheel; } MTPBlePointer;

static inline bool mtp_decode_ble_pointer(uint32_t reportID, const uint8_t *report,
                                          long length, MTPBlePointer *out) {
    if (reportID != 0x02 || !report || length != 5 || report[0] != 0x02) return false;
    out->middle = (report[1] & 0x04) != 0;
    out->motion = report[2] != 0 || report[3] != 0;
    out->wheel = report[4] != 0;
    return true;
}

/* Firmware byte → signed scroll units: a signed byte limited to ±7
 * (01…07 → +1…+7; FF…F9 → −1…−7; anything else ignored).
 * The table of Lenovo's Windows driver (FF and FE → −1, FD → −2, …) was used
 * first; measured on the Bluetooth keyboard (2026-11-22), a push ramps up as
 * 01→02→03 one way and FF→FE→FD the other, and that table made up/left
 * scrolling visibly slower. The signed reading is symmetric. */
static inline int mtp_wheel_units(uint8_t raw) {
    int units = (int8_t)raw;                 /* two's complement */
    return units >= -7 && units <= 7 ? units : 0;
}

/* Pixels for one report of `units` (signed): |units|^(1+acceleration) × 10 px
 * × speed. The firmware's units already measure how hard the stick is pushed
 * (1 gentle … 3–4 hard), so this is a force curve, like TrackPoint pointer
 * acceleration: deterministic, independent of time and of the report rate.
 * acceleration 0 = linear; 1 = 1, 4, 9, 16 × 10 px for 1, 2, 3, 4 units. */
static inline double mtp_scroll_pixels(int units, const MTPConfig *cfg) {
    if (!units) return 0;
    double m = pow((double)abs(units), 1.0 + cfg->acceleration);
    return (units < 0 ? -m : m) * cfg->speed * MTP_PIXELS_PER_UNIT;
}

/* ── Middle-button gesture ───────────────────────────────────────────────── */
/* The middle button can be reported by two sources: the standard HID button 3
 * and a vendor usage (USB FFA0:FB, Bluetooth report 0x15). The gesture lasts
 * while at least one of them is down. */
typedef enum { MTP_SRC_STANDARD = 0, MTP_SRC_VENDOR = 1 } MTPMiddleSource;

typedef struct {
    bool down[2];
    bool active;       /* middle held (from this device's HID reports)        */
    bool scrolling;    /* travel reached the threshold: no click on release   */
    uint32_t travel;   /* |h|+|v| firmware scroll units since the press        */
    uint32_t ignored;  /* wheel reports received while not held (diagnostic)  */
    double restX, restY; /* sub-pixel remainders, so slow scrolls are not lost */
} MTPGesture;

typedef enum { MTP_NOTHING = 0, MTP_CLICK = 1 } MTPGestureResult;

/* Middle button edge. Returns MTP_CLICK when the gesture ends without
 * scrolling and clicks are enabled. Deterministic: no timers. */
static inline MTPGestureResult mtp_gesture_middle(MTPGesture *g, MTPMiddleSource src,
                                                  bool down, const MTPConfig *cfg) {
    g->down[src] = down;
    bool held = g->down[0] || g->down[1];
    if (held && !g->active) {
        uint32_t ignored = g->ignored;
        *g = (MTPGesture){0};
        g->down[src] = true;
        g->active = true;
        g->ignored = ignored;
        return MTP_NOTHING;
    }
    if (!held && g->active) {
        bool click = !g->scrolling && cfg->clickIfNoScroll;
        g->active = false;
        g->scrolling = false;
        return click ? MTP_CLICK : MTP_NOTHING;
    }
    return MTP_NOTHING;
}

/* Firmware scroll report. Writes the pixel deltas to emit (already signed for
 * the user's scroll direction) and returns true if an event must be posted.
 * `natural` is macOS's "natural scrolling" setting. */
static inline bool mtp_gesture_wheel(MTPGesture *g, uint8_t rawH, uint8_t rawV,
                                     const MTPConfig *cfg, bool natural,
                                     int32_t *pixelsX, int32_t *pixelsY) {
    *pixelsX = *pixelsY = 0;
    if (!g->active) {               /* never scroll without the middle button */
        if (g->ignored < UINT32_MAX) g->ignored++;
        return false;
    }
    if (rawH && rawV) return false; /* firmware never sends both; reject */
    int h = mtp_wheel_units(rawH), v = mtp_wheel_units(rawV);
    if (!h && !v) return false;
    uint32_t step = (uint32_t)(abs(h) + abs(v));
    g->travel = g->travel > UINT32_MAX - step ? UINT32_MAX : g->travel + step;
    if (!g->scrolling) {
        if (g->travel < (uint32_t)cfg->threshold) return false;  /* dead zone */
        g->scrolling = true;
    }
    double sign = natural ? -1.0 : 1.0;
    double y = mtp_scroll_pixels(v, cfg) * sign + g->restY;
    double x = cfg->horizontal ? mtp_scroll_pixels(h, cfg) * sign + g->restX : 0;
    *pixelsY = (int32_t)trunc(y);
    *pixelsX = (int32_t)trunc(x);
    g->restY = y - *pixelsY;
    g->restX = x - *pixelsX;
    return *pixelsX || *pixelsY;
}

/* Cancels a gesture without clicking (disconnect, sleep, reload). */
static inline void mtp_gesture_cancel(MTPGesture *g) {
    uint32_t ignored = g->ignored;
    *g = (MTPGesture){0};
    g->ignored = ignored;
}

/* A lost release. While the middle button is held, the firmware turns
 * TrackPoint motion into scroll reports and sends no pointer motion (measured:
 * 0 motion reports over 55 gestures, docs/architecture.md §11, H4). So a
 * Bluetooth pointer report that moves with button 3 up, during a gesture,
 * proves the button was released and its release report (from either source)
 * was lost. The gesture then ends without a click: the user is pointing, and a
 * late click could land anywhere. Returns true when it ended the gesture. */
static inline bool mtp_gesture_motion_proves_release(MTPGesture *g, const MTPBlePointer *p) {
    if (!g->active || !p->motion || p->middle) return false;
    mtp_gesture_cancel(g);
    return true;
}

/* After a gesture ends, native wheel events still owed (MTPTapState) are only
 * expected for a short while: a native event normally follows its report by a
 * few milliseconds, and one that preceded its report already counted against
 * the held button. Past this delay, what is still owed is cleared so that it
 * can never swallow another mouse's wheel later. */
#define MTP_OWED_GRACE_MS 250

/* ── Event-tap filtering decision ────────────────────────────────────────── */
/* Quartz events do not say which device produced them (no public API).
 * Attribution therefore relies on state observed directly from the keyboard's
 * own HID reports, which reach this process before WindowServer's event:
 *  - a non-synthetic middle-button press is dropped only if the TrackPoint's
 *    middle button is held at that moment; middle releases and middle drags
 *    are dropped only while such a press is being held back. Other buttons
 *    are never touched;
 *  - the firmware's own Bluetooth wheel output (mouse report 0x02) is replaced
 *    by our synthetic scrolling. Each such HID report is counted ("owed");
 *    a non-continuous (wheel, not trackpad) scroll event is dropped while one
 *    is owed or while the TrackPoint's middle button is held. Counting, not
 *    timing, also catches the last native event arriving after the release. */
typedef enum { MTP_EV_OTHER_DOWN, MTP_EV_OTHER_UP, MTP_EV_OTHER_DRAGGED,
               MTP_EV_SCROLL, MTP_EV_IGNORED } MTPEventKind;

#define MTP_MAX_OWED_WHEEL 64

typedef struct {
    bool swallowing;       /* a TrackPoint middle press is being held back   */
    uint32_t owedWheel;    /* native wheel events still expected from it      */
} MTPTapState;

/* A TrackPoint HID report carrying a native wheel value was seen. */
static inline void mtp_tap_native_wheel(MTPTapState *s) {
    if (s->owedWheel < MTP_MAX_OWED_WHEEL) s->owedWheel++;
}

static inline bool mtp_tap_should_drop(MTPTapState *s, MTPEventKind kind, long button,
                                       bool synthetic, bool continuous,
                                       bool trackpointHeld) {
    if (synthetic) return false;
    switch (kind) {
    case MTP_EV_OTHER_DOWN:
        if (button != 2) return false;
        s->swallowing = trackpointHeld;   /* every press re-decides the pair */
        return s->swallowing;
    case MTP_EV_OTHER_DRAGGED:
        return button == 2 && s->swallowing;
    case MTP_EV_OTHER_UP:
        if (button != 2 || !s->swallowing) return false;
        s->swallowing = false;
        return true;
    case MTP_EV_SCROLL:
        if (continuous) return false;          /* trackpad: never touched */
        if (s->owedWheel) { s->owedWheel--; return true; }
        return trackpointHeld;
    default:
        return false;
    }
}

#endif
