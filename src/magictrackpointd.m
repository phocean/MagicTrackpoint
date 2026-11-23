/*
 * magictrackpointd — minimal TrackPoint daemon for the Lenovo ThinkPad
 * TrackPoint Keyboard II (USB receiver 17EF:60EE, Bluetooth LE 17EF:60E1).
 *
 *   - hardware pointer sensitivity 1–9, applied on start, connection,
 *     reconnection, wake and reload;
 *   - middle button + TrackPoint scrolling (vertical and horizontal) from the
 *     firmware's own scroll reports, with a click/scroll threshold;
 *   - a middle click only when the button was released without scrolling.
 *
 * One process, one run loop. The only periodic timer is a 5 s re-check while
 * a permission or component is missing; it stops once everything runs.
 * Pure logic lives in mtp_core.h.
 *
 * Copyright (C) 2026 Jean-Christophe Baptiste
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version. It is distributed WITHOUT ANY WARRANTY; see LICENSE.
 */
#import "mtp_core.h"
#import <ApplicationServices/ApplicationServices.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreServices/CoreServices.h>
#import <IOKit/IOMessage.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <os/log.h>
#include <libproc.h>
#include <signal.h>
#include <sys/stat.h>

#ifndef MTP_VERSION
#define MTP_VERSION "dev"
#endif
#define MTP_LABEL "com.jcbaptiste.magictrackpoint"
#define MTP_MAX_DEVICES 8        /* the USB receiver exposes 3 interfaces */
#define MTP_RECHECK_SECONDS 5    /* only while a permission or component is missing */
#define MTP_MAX_RETRIES 3        /* failed configuration writes, per connection */
#define MTP_RETRY_SECONDS 2      /* first timed retry when no report can trigger one */

/* ── State ───────────────────────────────────────────────────────────────── */
typedef enum { MTP_W_NONE, MTP_W_OK, MTP_W_UNSUPPORTED, MTP_W_FAILED } MTPWrite;

typedef struct {
    IOHIDDeviceRef device;       /* retained; NULL = free slot */
    int productID;
    MTPGesture gesture;
    bool nativeMiddleDown;       /* USB: standard button 3, for the tap only */
    uint32_t motionDuringGesture;/* diagnostic (debug log only) */
    MTPWrite sensitivity, scroll;
    int retries;
    bool retryQueued;            /* one report-triggered retry at a time */
    MTPKeyState keys;            /* Lenovo top-row key code being rebuilt */
    bool keySettleQueued;
} MTPDevice;

static MTPConfig g_cfg;
static NSArray<NSString *> *g_cfgErrors;
static bool g_cfgExists;
static os_log_t g_log;
static MTPDevice g_dev[MTP_MAX_DEVICES];
static IOHIDManagerRef g_hid;
static CFMachPortRef g_buttonTap, g_scrollTap;
static MTPTapState g_tap;
static bool g_listenGranted, g_axGranted, g_natural;
static dispatch_source_t g_recheckTimer;
static uint64_t g_gestureEnds;   /* generation of the owed-wheel grace timer */
static io_connect_t g_rootPort;
static IONotificationPortRef g_powerPort;
static io_object_t g_powerNotifier;

#define LOG_ERROR(fmt, ...) os_log_error(g_log, fmt, ##__VA_ARGS__)
/* info and debug messages stay in memory (never persisted by the unified log);
 * view them live with `magictrackpointctl log`. */
#define LOG_INFO(fmt, ...) do { if (g_cfg.logLevel >= MTP_LOG_INFO) \
    os_log_info(g_log, fmt, ##__VA_ARGS__); } while (0)
#define LOG_DEBUG(fmt, ...) do { if (g_cfg.logLevel >= MTP_LOG_DEBUG) \
    os_log_debug(g_log, fmt, ##__VA_ARGS__); } while (0)

static void update_taps(void);
static void set_input_callbacks(void);
static void ensure_running(bool prompt);
static void write_status(void);

static NSString *config_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/magictrackpoint/config.plist"];
}
static NSString *status_dir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/" MTP_LABEL];
}
static const char *transport(int pid) { return pid == MTP_BLE_PID ? "bluetooth" : "usb"; }
static const char *write_name(MTPWrite w) {
    switch (w) {
    case MTP_W_OK: return "applied";
    case MTP_W_UNSUPPORTED: return "not-applicable";   /* e.g. USB keyboard interface */
    case MTP_W_FAILED: return "FAILED";
    default: return "pending";
    }
}

static int device_count(void) {
    int n = 0;
    for (int i = 0; i < MTP_MAX_DEVICES; i++) n += g_dev[i].device != NULL;
    return n;
}
static MTPDevice *device_for(IOHIDDeviceRef device) {
    if (!device) return NULL;
    for (int i = 0; i < MTP_MAX_DEVICES; i++)
        if (g_dev[i].device == device) return &g_dev[i];
    return NULL;
}
/* The TrackPoint's middle button is physically down (any source, any interface). */
static bool trackpoint_held(void) {
    for (int i = 0; i < MTP_MAX_DEVICES; i++)
        if (g_dev[i].device && (g_dev[i].gesture.active || g_dev[i].nativeMiddleDown))
            return true;
    return false;
}
/* Event taps serve scrolling only. Accessibility serves scrolling, and the
 * Bluetooth and screenshot keys (they drive the user interface). */
static bool needs_taps(void) { return g_cfg.scrollEnabled; }
static bool needs_accessibility(void) {
    return g_cfg.scrollEnabled || g_cfg.keyBluetooth || g_cfg.keyScreenshot;
}
static bool taps_ready(void) { return g_buttonTap && g_scrollTap; }
/* Scrolling is only switched on in the firmware when we can also neutralise
 * its native side effects; otherwise the keyboard stays in its native mode. */
static bool scroll_active(void) { return g_cfg.scrollEnabled && taps_ready(); }
static bool fully_running(void) {
    return g_listenGranted && g_hid && (!needs_accessibility() || g_axGranted) &&
           (!needs_taps() || taps_ready());
}

/* ── Microphone (F4) ─────────────────────────────────────────────────────── */
/* Mute property of the default input device, through Core Audio: no process
 * is started, no audio is read (only the mute control is changed). */
static bool default_input(AudioDeviceID *dev, AudioObjectPropertyAddress *mute) {
    AudioObjectPropertyAddress def = { kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = sizeof *dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &def, 0, NULL, &size, dev) ||
        *dev == kAudioObjectUnknown) return false;
    *mute = (AudioObjectPropertyAddress){ kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain };
    return AudioObjectHasProperty(*dev, mute);
}

static const char *microphone_state(void) {
    AudioDeviceID dev;
    AudioObjectPropertyAddress mute;
    if (!default_input(&dev, &mute)) return "no-mute-control";
    UInt32 muted = 0, size = sizeof muted;
    if (AudioObjectGetPropertyData(dev, &mute, 0, NULL, &size, &muted)) return "unknown";
    return muted ? "muted" : "on";
}

/* Audible feedback, since macOS shows nothing when the input is muted: two
 * distinct system sounds, loaded once. */
static void microphone_sound(bool muted) {
    static SystemSoundID sounds[2];
    const char *files[2] = { "/System/Library/Sounds/Tink.aiff", "/System/Library/Sounds/Pop.aiff" };
    int i = muted ? 1 : 0;
    if (!sounds[i]) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)files[i],
                                                               (CFIndex)strlen(files[i]), false);
        if (!url) return;
        if (AudioServicesCreateSystemSoundID(url, &sounds[i])) sounds[i] = 0;
        CFRelease(url);
    }
    if (sounds[i]) AudioServicesPlaySystemSound(sounds[i]);
}

static void toggle_microphone(void) {
    AudioDeviceID dev;
    AudioObjectPropertyAddress mute;
    Boolean settable = false;
    UInt32 muted = 0, size = sizeof muted;
    if (!default_input(&dev, &mute) || AudioObjectIsPropertySettable(dev, &mute, &settable) ||
        !settable || AudioObjectGetPropertyData(dev, &mute, 0, NULL, &size, &muted)) {
        LOG_ERROR("microphone key: the default input device has no mute control");
        return;
    }
    muted = !muted;
    if (AudioObjectSetPropertyData(dev, &mute, 0, NULL, sizeof muted, &muted)) {
        LOG_ERROR("microphone key: could not change the mute state");
        return;
    }
    LOG_INFO("microphone %{public}s", muted ? "muted" : "unmuted");
    microphone_sound(muted);
}

/* ── Status file (state only — never input data) ─────────────────────────── */
static void write_status(void) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"version=%s\npid=%d\nstate=%s\n", MTP_VERSION, getpid(),
            fully_running() ? "running" : "waiting (see MISSING below)"];
        [s appendFormat:@"input_monitoring=%s\naccessibility=%s\n",
            g_listenGranted ? "granted" : "MISSING",
            g_axGranted ? "granted" : needs_accessibility() ? "MISSING" : "not-needed"];
        [s appendFormat:@"hid=%s\nevent_taps=%s\n",
            g_hid ? "open" : "MISSING",
            taps_ready() ? "ready" : needs_taps() ? "MISSING" : "not-needed"];
        [s appendFormat:@"config=%@ (%s, %lu error(s))\n", config_path(),
            g_cfgExists ? "loaded" : "absent, defaults", (unsigned long)g_cfgErrors.count];
        [s appendFormat:@"sensitivity=%d\nscroll=%s speed=%g acceleration=%g threshold=%d "
            "horizontal=%s\nmiddle_click=%s\n", g_cfg.sensitivity,
            scroll_active() ? "on" : g_cfg.scrollEnabled ? "configured, inactive" : "off",
            g_cfg.speed, g_cfg.acceleration, g_cfg.threshold, g_cfg.horizontal ? "on" : "off",
            g_cfg.clickIfNoScroll ? "on" : "off"];
        [s appendFormat:@"keys=microphone:%s bluetooth:%s screenshot:%s\nmicrophone=%s\n",
            g_cfg.keyMicrophone ? "on" : "off", g_cfg.keyBluetooth ? "on" : "off",
            g_cfg.keyScreenshot ? "on" : "off", microphone_state()];
        [s appendFormat:@"devices=%d\n", device_count()];
        for (int i = 0; i < MTP_MAX_DEVICES; i++) {
            MTPDevice *d = &g_dev[i];
            if (!d->device) continue;
            [s appendFormat:@"device.%d=%s sensitivity:%s preferred_scrolling:%s\n", i,
                transport(d->productID), write_name(d->sensitivity), write_name(d->scroll)];
        }
        NSString *dir = status_dir();
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSString *file = [dir stringByAppendingPathComponent:@"status"];
        if ([s writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil])
            chmod(file.fileSystemRepresentation, 0600);
    }
}

/* ── Hardware configuration ──────────────────────────────────────────────── */
/* True when the interface's report descriptor has an element of `type` in
 * report `reportID`. Several interfaces can share one product ID (the USB
 * receiver exposes three); a configuration report is only ever written to
 * an interface that describes it. */
static bool interface_has_report(IOHIDDeviceRef device, IOHIDElementType type,
                                 uint32_t reportID) {
    CFArrayRef all = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (!all) return false;
    bool found = false;
    for (CFIndex i = 0, n = CFArrayGetCount(all); i < n && !found; i++) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(all, i);
        found = IOHIDElementGetType(e) == type && IOHIDElementGetReportID(e) == reportID;
    }
    CFRelease(all);
    return found;
}

static MTPWrite send_config(IOHIDDeviceRef device, int pid, uint8_t command, uint8_t value) {
    MTPConfigReport r;
    if (!mtp_build_config_report(pid, command, value, &r)) return MTP_W_UNSUPPORTED;
    IOHIDElementType elementType = r.feature ? kIOHIDElementTypeFeature : kIOHIDElementTypeOutput;
    IOHIDReportType reportType = r.feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput;
    if (!interface_has_report(device, elementType, r.reportID)) return MTP_W_UNSUPPORTED;
    IOReturn ret = IOHIDDeviceSetReport(device, reportType, r.reportID, r.bytes, r.length);
    if (ret != kIOReturnSuccess) {
        LOG_ERROR("%{public}s: command 0x%02x=%u failed: 0x%08x", transport(pid),
                  command, value, ret);
        return MTP_W_FAILED;
    }
    return MTP_W_OK;
}

/* Changes a tap's state only when it differs: each switch-off notifies the
 * tap callback (see tap_callback), so redundant calls are avoided. */
static void set_tap(CFMachPortRef tap, bool on) {
    if (tap && CGEventTapIsEnabled(tap) != on) CGEventTapEnable(tap, on);
}

static bool write_failed(const MTPDevice *d) {
    return d->sensitivity == MTP_W_FAILED || d->scroll == MTP_W_FAILED;
}

static void schedule_timed_retry(MTPDevice *d);

/* IOHIDDeviceSetReport is synchronous (Bluetooth can take a while): both taps
 * are suspended meanwhile, so no mouse's buttons or wheel wait for it. */
static void apply_settings(MTPDevice *d) {
    set_tap(g_buttonTap, false);
    set_tap(g_scrollTap, false);
    IOHIDDeviceRef device = (IOHIDDeviceRef)CFRetain(d->device);
    @autoreleasepool {
        d->sensitivity = send_config(device, d->productID, MTP_CMD_SENSITIVITY,
                                     (uint8_t)g_cfg.sensitivity);
        d->scroll = send_config(device, d->productID, MTP_CMD_PREFERRED_SCROLL,
                                scroll_active() ? 1 : 0);
        LOG_INFO("%{public}s: sensitivity %d %{public}s, preferred scrolling %{public}s %{public}s",
                 transport(d->productID), g_cfg.sensitivity, write_name(d->sensitivity),
                 scroll_active() ? "on" : "off", write_name(d->scroll));
    }
    CFRelease(device);
    update_taps();
    schedule_timed_retry(d);
}

static void apply_all(void) {
    for (int i = 0; i < MTP_MAX_DEVICES; i++)
        if (g_dev[i].device) { g_dev[i].retries = 0; apply_settings(&g_dev[i]); }
}

/* A write that failed (link not ready right after wake, for instance) is
 * retried a few times at most, never from inside an input callback and never
 * during a gesture:
 *  - while scrolling is active, at the keyboard's next report (it shows the
 *    link is alive), deferred to after the callback;
 *  - otherwise no report reaches this process, so after 2, 4 then 8 s.
 * The device is looked up again when the retry runs: it may be gone. */
static void retry_device(IOHIDDeviceRef device) {
    MTPDevice *d = device_for(device);
    if (!d) return;
    d->retryQueued = false;
    if (!write_failed(d) || d->retries >= MTP_MAX_RETRIES) return;
    if (d->gesture.active) return;      /* the next report or timer will do it */
    d->retries++;
    LOG_INFO("%{public}s: retrying the configuration (%d/%d)", transport(d->productID),
             d->retries, MTP_MAX_RETRIES);
    apply_settings(d);
    write_status();
}

static void schedule_timed_retry(MTPDevice *d) {
    if (scroll_active() || !write_failed(d) || d->retries >= MTP_MAX_RETRIES) return;
    IOHIDDeviceRef device = d->device;   /* compared, never dereferenced, later */
    int64_t delay = (int64_t)MTP_RETRY_SECONDS << d->retries;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { retry_device(device); } });
}

static void retry_at_next_report(MTPDevice *d) {
    if (!write_failed(d) || d->retries >= MTP_MAX_RETRIES || d->gesture.active ||
        d->retryQueued) return;
    d->retryQueued = true;
    IOHIDDeviceRef device = d->device;
    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { retry_device(device); } });
}

/* Leaves the firmware in its native mode when the daemon stops, so the
 * keyboard behaves like an ordinary one without it. */
static void restore_native_mode(void) {
    for (int i = 0; i < MTP_MAX_DEVICES; i++)
        if (g_dev[i].device)
            send_config(g_dev[i].device, g_dev[i].productID, MTP_CMD_PREFERRED_SCROLL, 0);
}

static void cancel_all_gestures(void) {
    for (int i = 0; i < MTP_MAX_DEVICES; i++) {
        mtp_gesture_cancel(&g_dev[i].gesture);
        g_dev[i].nativeMiddleDown = false;
    }
}

static void destroy_tap(CFMachPortRef *tap) {
    if (!*tap) return;
    CFMachPortInvalidate(*tap);      /* also invalidates its run loop source */
    CFRelease(*tap);
    *tap = NULL;
}

/* Accessibility was removed while running. The taps can no longer hold back
 * the keyboard's native events, so scrolling is switched off: input callbacks
 * removed, firmware back to its native mode (the middle button clicks
 * natively again). The re-check timer brings everything back once it is
 * granted again (start_components recreates the taps). */
static void accessibility_lost(void) {
    LOG_ERROR("Accessibility was removed: scrolling off, keyboard back to its native mode");
    cancel_all_gestures();
    g_tap = (MTPTapState){0};
    destroy_tap(&g_buttonTap);
    destroy_tap(&g_scrollTap);
    set_input_callbacks();           /* scroll_active() is now false: removed */
    apply_all();
}

/* ── Event taps ──────────────────────────────────────────────────────────── */
/* Two taps, both only while a keyboard is connected and scrolling is on:
 *  - button tap (middle press/release/drag), always armed: rare events;
 *  - scroll tap, armed only while the TrackPoint middle button is held or a
 *    native wheel event from it is still expected, so trackpad and mouse
 *    scrolling never go through this process otherwise. */
static void update_taps(void) {
    bool armed = g_axGranted && scroll_active() && device_count() > 0;
    if (!armed) g_tap = (MTPTapState){0};
    set_tap(g_buttonTap, armed);
    set_tap(g_scrollTap, armed && (trackpoint_held() || g_tap.owedWheel));
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    /* Observed on macOS 27: switching a tap off with CGEventTapEnable(false),
     * as set_tap() does on purpose, delivers kCGEventTapDisabledByUserInput to
     * its callback. Reacting to it by calling update_taps() looped thousands of
     * times per second. It is the daemon's own doing: nothing to repair, and
     * update_taps() re-enables whatever is needed on the next state change. */
    if (type == kCGEventTapDisabledByUserInput) return event;
    if (type == kCGEventTapDisabledByTimeout) {
        LOG_ERROR("event tap disabled by the system (timeout), re-arming");
        g_tap = (MTPTapState){0};   /* events were missed: pairing is unknown */
        update_taps();                /* the tap reads as disabled: set_tap() re-enables it */
        return event;
    }
    MTPEventKind kind =
        type == kCGEventOtherMouseDown ? MTP_EV_OTHER_DOWN :
        type == kCGEventOtherMouseUp ? MTP_EV_OTHER_UP :
        type == kCGEventOtherMouseDragged ? MTP_EV_OTHER_DRAGGED :
        type == kCGEventScrollWheel ? MTP_EV_SCROLL : MTP_EV_IGNORED;
    bool held = trackpoint_held();
    bool drop = mtp_tap_should_drop(&g_tap, kind,
        (long)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber),
        CGEventGetIntegerValueField(event, kCGEventSourceUserData) == MTP_EVENT_MAGIC,
        kind == MTP_EV_SCROLL &&
            CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous) != 0,
        held);
    if (kind == MTP_EV_SCROLL && !held && !g_tap.owedWheel) update_taps();  /* disarm */
    return drop ? NULL : event;
}

static CFMachPortRef create_tap(CGEventMask mask) {
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, tap_callback, NULL);
    if (!tap) { LOG_ERROR("cannot create event tap (Accessibility)"); return NULL; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    if (!src) { CFRelease(tap); LOG_ERROR("cannot schedule event tap"); return NULL; }
    CGEventTapEnable(tap, false);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    return tap;
}

/* Synthetic events go to the session tap, downstream of our HID-level taps,
 * so they never come back to us. They are also tagged. */
static void post(CGEventRef e) {
    if (!e) return;
    CGEventSetIntegerValueField(e, kCGEventSourceUserData, MTP_EVENT_MAGIC);
    CGEventPost(kCGSessionEventTap, e);
    CFRelease(e);
}

static void post_middle_click(void) {
    CGEventRef now = CGEventCreate(NULL);
    CGPoint at = now ? CGEventGetLocation(now) : CGPointZero;
    if (now) CFRelease(now);
    CGEventType types[2] = { kCGEventOtherMouseDown, kCGEventOtherMouseUp };
    for (int i = 0; i < 2; i++) {
        CGEventRef e = CGEventCreateMouseEvent(NULL, types[i], at, kCGMouseButtonCenter);
        if (e) CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
        post(e);
    }
}

/* ── Gestures ────────────────────────────────────────────────────────────── */
static bool natural_scrolling(void) {
    /* Absent key = macOS default = natural scrolling on. */
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("com.apple.swipescrolldirection"),
                                                    kCFPreferencesAnyApplication);
    bool natural = true;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) natural = CFBooleanGetValue(v);
    if (v) CFRelease(v);
    return natural;
}

/* Clears what is still owed (and USB button-3 flags) once no gesture is
 * active MTP_OWED_GRACE_MS after the last one ended: a one-shot delay started
 * by the release, not a periodic check. */
static void gesture_ended(void) {
    uint64_t generation = ++g_gestureEnds;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MTP_OWED_GRACE_MS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (generation != g_gestureEnds) return;          /* a later release re-armed it */
        for (int i = 0; i < MTP_MAX_DEVICES; i++)
            if (g_dev[i].gesture.active) return;          /* a new gesture owns the state */
        if (g_tap.owedWheel) LOG_DEBUG("cleared %u owed wheel event(s)", g_tap.owedWheel);
        g_tap.owedWheel = 0;
        for (int i = 0; i < MTP_MAX_DEVICES; i++) g_dev[i].nativeMiddleDown = false;
        update_taps();
    });
}

/* Accessibility is checked again at every press (an event, not a timer):
 * macOS sends no notification when the user removes it. Deferred, since it
 * changes the input callbacks this call comes from. */
static bool accessibility_still_granted(void) {
    if (AXIsProcessTrusted()) return true;
    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool {
        ensure_running(false);
        write_status();
    }});
    return false;
}

static void middle_changed(MTPDevice *d, MTPMiddleSource src, bool down) {
    bool wasActive = d->gesture.active;
    if (down && !wasActive) {
        if (!accessibility_still_granted()) return;   /* the native click goes through */
        g_natural = natural_scrolling();
        d->motionDuringGesture = 0;
        g_tap.owedWheel = 0;         /* a new press: nothing is owed any more */
    }
    MTPGesture before = d->gesture;
    MTPGestureResult result = mtp_gesture_middle(&d->gesture, src, down, &g_cfg);
    if (wasActive && !d->gesture.active) {
        LOG_DEBUG("gesture end: travel=%u scrolled=%{public}s click=%{public}s "
                  "pointer-motion-reports=%u ignored-wheel-reports=%u", before.travel,
                  before.scrolling ? "yes" : "no", result == MTP_CLICK ? "yes" : "no",
                  d->motionDuringGesture, before.ignored);
    } else if (!wasActive && d->gesture.active) {
        LOG_DEBUG("gesture start (%{public}s)", src == MTP_SRC_STANDARD ? "button 3" : "vendor");
    }
    if (result == MTP_CLICK) post_middle_click();
    if (wasActive && !d->gesture.active) gesture_ended();
    if (wasActive != d->gesture.active) update_taps();
}

static void wheel_report(MTPDevice *d, uint8_t h, uint8_t v) {
    int32_t px, py;
    bool emit = mtp_gesture_wheel(&d->gesture, h, v, &g_cfg, g_natural, &px, &py);
    LOG_DEBUG("wheel raw h=0x%02x v=0x%02x held=%{public}s -> %d,%d px", h, v,
              d->gesture.active ? "yes" : "no", px, py);
    if (emit)
        post(CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, py, px));
}

/* ── Bluetooth key (F10): Control Center, Bluetooth module ───────────────── */
/* No public API opens Control Center. The Accessibility API (already granted
 * for scrolling) can: press the Control Center menu bar item, then use the
 * Bluetooth module's "show details" action. Elements are found by their
 * stable identifiers, never by localized names; nothing they contain is read
 * or logged. The module's own press action toggles Bluetooth (and would
 * disconnect this keyboard): it is never used. Any failure falls back to the
 * Bluetooth pane of System Settings. Each Accessibility call is bounded by a
 * short timeout, so a busy system cannot block the daemon. */
#define MTP_AX_TIMEOUT 0.25f
#define MTP_CC_ITEM    "com.apple.menuextra.controlcenter"
#define MTP_CC_BT      "controlcenter-bluetooth"   /* module, main view    */
#define MTP_CC_BT_LIST "bluetooth-header"          /* its details view     */

static void open_bluetooth_settings(void) {
    CFURLRef url = CFURLCreateWithString(NULL,
        CFSTR("x-apple.systempreferences:com.apple.BluetoothSettings"), NULL);
    if (!url) return;
    OSStatus err = LSOpenCFURLRef(url, NULL);
    CFRelease(url);
    if (err) LOG_ERROR("Bluetooth key: cannot open System Settings (%d)", (int)err);
}

/* pid of this user's process named `name`, or 0. */
static pid_t user_process(const char *name) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t *pids = calloc((size_t)count + 16, sizeof *pids);
    if (!pids) return 0;
    count = proc_listallpids(pids, (int)((size_t)(count + 16) * sizeof *pids));
    pid_t found = 0;
    for (int i = 0; i < count && !found; i++) {
        char comm[2 * MAXCOMLEN + 1] = {0};
        struct proc_bsdshortinfo info;
        if (proc_name(pids[i], comm, sizeof comm) <= 0 || strcmp(comm, name)) continue;
        if (proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof info) == sizeof info &&
            info.pbsi_uid == getuid()) found = pids[i];
    }
    free(pids);
    return found;
}

static bool ax_identifier_is(AXUIElementRef e, const char *ident) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXIdentifierAttribute, &v) != kAXErrorSuccess || !v)
        return false;
    char buf[128] = {0};
    bool same = CFGetTypeID(v) == CFStringGetTypeID() &&
        CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8) && !strcmp(buf, ident);
    CFRelease(v);
    return same;
}

/* Depth-first search of `root`'s attribute `attr` (children, windows…) for an
 * element with identifier `ident`. Retained result, or NULL. */
static AXUIElementRef ax_find(AXUIElementRef root, CFStringRef attr, const char *ident, int depth) {
    if (depth > 7) return NULL;
    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue(root, attr, &kids) != kAXErrorSuccess || !kids) return NULL;
    AXUIElementRef hit = NULL;
    if (CFGetTypeID(kids) == CFArrayGetTypeID()) {
        for (CFIndex i = 0, n = CFArrayGetCount(kids); i < n && !hit; i++) {
            AXUIElementRef e = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
            if (ax_identifier_is(e, ident)) hit = (AXUIElementRef)CFRetain(e);
            else hit = ax_find(e, kAXChildrenAttribute, ident, depth + 1);
        }
    } else if (CFGetTypeID(kids) == AXUIElementGetTypeID()) {   /* single element */
        AXUIElementRef e = (AXUIElementRef)kids;
        hit = ax_identifier_is(e, ident) ? (AXUIElementRef)CFRetain(e)
                                         : ax_find(e, kAXChildrenAttribute, ident, depth + 1);
    }
    CFRelease(kids);
    return hit;
}

/* The Control Center menu bar item: owned by MenuBarAgent (macOS 27) or by
 * ControlCenter itself (earlier versions). */
static AXUIElementRef control_center_item(void) {
    const char *owners[] = { "MenuBarAgent", "ControlCenter" };
    for (int i = 0; i < 2; i++) {
        pid_t pid = user_process(owners[i]);
        if (!pid) continue;
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, MTP_AX_TIMEOUT);
        AXUIElementRef item = ax_find(app, kAXWindowsAttribute, MTP_CC_ITEM, 0);
        if (!item) item = ax_find(app, CFSTR("AXExtrasMenuBar"), MTP_CC_ITEM, 0);
        CFRelease(app);
        if (item) return item;
    }
    return NULL;
}

/* The Bluetooth module's "show details" action: the one custom action (not
 * AXPress) of the element. Retained, or NULL. */
static CFStringRef details_action(AXUIElementRef module) {
    CFArrayRef actions = NULL;
    if (AXUIElementCopyActionNames(module, &actions) != kAXErrorSuccess || !actions) return NULL;
    CFStringRef found = NULL;
    for (CFIndex i = 0, n = CFArrayGetCount(actions); i < n && !found; i++) {
        CFStringRef a = CFArrayGetValueAtIndex(actions, i);
        if (CFStringHasPrefix(a, CFSTR("Name:"))) found = CFRetain(a);
    }
    CFRelease(actions);
    return found;
}

/* An element of an open Control Center panel. Retained, or NULL. */
static AXUIElementRef control_center_element(const char *ident) {
    pid_t pid = user_process("ControlCenter");
    if (!pid) return NULL;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, MTP_AX_TIMEOUT);
    AXUIElementRef found = ax_find(app, kAXWindowsAttribute, ident, 0);
    CFRelease(app);
    return found;
}
static AXUIElementRef bluetooth_module(void) { return control_center_element(MTP_CC_BT); }

/* Number of Control Center windows: 0 once its panel is closed. */
static long control_center_windows(void) {
    pid_t pid = user_process("ControlCenter");
    if (!pid) return 0;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, MTP_AX_TIMEOUT);
    CFTypeRef wins = NULL;
    long n = 0;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins) {
        if (CFGetTypeID(wins) == CFArrayGetTypeID()) n = CFArrayGetCount(wins);
        CFRelease(wins);
    }
    CFRelease(app);
    return n;
}

static void press_control_center_item(void) {
    AXUIElementRef item = control_center_item();
    if (!item) return;
    AXUIElementPerformAction(item, kAXPressAction);
    CFRelease(item);
}

/* Closes Control Center entirely. Measured on macOS 27: pressing its menu bar
 * item while the Bluetooth list is shown only goes back to the main panel
 * (a ~300 ms animation during which no element is visible); a second press
 * closes it. So: watch every 100 ms; press again only once the main panel is
 * actually displayed; stop as soon as no Control Center window is left. The
 * item is never pressed while the panel is closed, so it is never reopened.
 * Bounded: 3 presses, 2 seconds. */
static void close_control_center_step(int presses, int polls) {
    if (!control_center_windows()) {
        LOG_INFO("Bluetooth key: Control Center closed");
        return;
    }
    AXUIElementRef main = bluetooth_module();
    if (main) {
        CFRelease(main);
        if (presses >= 3) { LOG_ERROR("Bluetooth key: Control Center did not close"); return; }
        press_control_center_item();
        presses++;
    }
    if (polls >= 20) { LOG_ERROR("Bluetooth key: Control Center did not close"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ close_control_center_step(presses, polls + 1); });
}

static void close_control_center(void) {
    if (!control_center_windows()) return;
    AXUIElementRef list = control_center_element(MTP_CC_BT_LIST);
    if (list) { CFRelease(list); press_control_center_item(); close_control_center_step(1, 0); }
    else close_control_center_step(0, 0);
}

/* Control Center draws its panel asynchronously: the module is looked for a
 * few times, 100 ms apart, then the attempt gives up (closing the panel).
 * `item` (retained) is NULL when the panel was already open. */
static void show_bluetooth_details(AXUIElementRef item, int attempt) {
    AXUIElementRef module = bluetooth_module();
    CFStringRef action = module ? details_action(module) : NULL;
    if (action) {
        AXError err = AXUIElementPerformAction(module, action);
        if (err == kAXErrorSuccess) LOG_INFO("Bluetooth key: Control Center, Bluetooth module");
        else { LOG_ERROR("Bluetooth key: details action failed (%d)", (int)err); open_bluetooth_settings(); }
    } else if (attempt < 10) {
        if (module) CFRelease(module);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ show_bluetooth_details(item, attempt + 1); });
        return;                                   /* item is released by the last attempt */
    } else {
        LOG_ERROR("Bluetooth key: no Bluetooth module in Control Center, opening System Settings");
        close_control_center();
        open_bluetooth_settings();
    }
    if (action) CFRelease(action);
    if (module) CFRelease(module);
    if (item) CFRelease(item);
}

/* F10 toggles: a second press, while the Bluetooth list is shown, closes
 * Control Center entirely. */
static void bluetooth_key(void) {
    if (!AXIsProcessTrusted()) { open_bluetooth_settings(); return; }
    AXUIElementRef list = control_center_element(MTP_CC_BT_LIST);
    if (list) { CFRelease(list); close_control_center(); return; }
    AXUIElementRef open = bluetooth_module();     /* panel already open */
    if (open) { CFRelease(open); show_bluetooth_details(NULL, 0); return; }
    AXUIElementRef item = control_center_item();
    if (!item || AXUIElementPerformAction(item, kAXPressAction) != kAXErrorSuccess) {
        LOG_ERROR("Bluetooth key: Control Center item not found, opening System Settings");
        if (item) CFRelease(item);
        open_bluetooth_settings();
        return;
    }
    show_bluetooth_details(item, 0);
}

/* ── Screenshot key (Print Screen): ⇧⌘5 ──────────────────────────────────── */
/* The standard macOS screenshot shortcut, also used by tools such as CleanShot.
 * Key code 0x17 is the "5" key position (kVK_ANSI_5), independent of the
 * keyboard layout, as macOS shortcuts are. */
static void screenshot_key(void) {
    if (!AXIsProcessTrusted()) {
        LOG_ERROR("screenshot key: Accessibility not granted");
        return;
    }
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)0x17, down);
        if (!e) continue;
        CGEventSetFlags(e, kCGEventFlagMaskShift | kCGEventFlagMaskCommand);
        CGEventSetIntegerValueField(e, kCGEventSourceUserData, MTP_EVENT_MAGIC);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
    LOG_INFO("screenshot key: sent shift-command-5");
}

static void run_key(MTPKey key) {
    if (!mtp_key_enabled(key, &g_cfg)) return;
    switch (key) {
    case MTP_KEY_MICROPHONE: toggle_microphone(); write_status(); break;
    case MTP_KEY_BLUETOOTH:  bluetooth_key(); break;
    case MTP_KEY_SCREENSHOT: screenshot_key(); break;
    default: break;
    }
}

/* All bit elements of one report are delivered in one go; the code is
 * evaluated once they are, right after the callback. */
static void settle_keys(MTPDevice *d) {
    if (d->keySettleQueued) return;
    d->keySettleQueued = true;
    IOHIDDeviceRef device = d->device;    /* compared, never dereferenced, later */
    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool {
        MTPDevice *x = device_for(device);
        if (!x) return;
        x->keySettleQueued = false;
        run_key(mtp_key_settle(&x->keys));
    }});
}

/* ── HID callbacks ───────────────────────────────────────────────────────── */
/* Registered only while scrolling is active. Receives every input report of
 * the matched keyboard, keyboard keys included (they share the Bluetooth
 * device). Only the mouse report 0x02 and the vendor reports 0x15/0x16 are
 * looked at; everything else is returned from on the first comparison, never
 * copied, stored or logged. */
static void report_callback(void *context, IOReturn result, void *sender,
                            IOHIDReportType type, uint32_t reportID,
                            uint8_t *report, CFIndex length) {
    (void)context;
    if (reportID != 0x16 && reportID != 0x15 && reportID != 0x02) return;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput) return;
    MTPDevice *d = device_for((IOHIDDeviceRef)sender);
    if (!d || !scroll_active()) return;
    retry_at_next_report(d);
    uint8_t h, v;
    bool down;
    MTPBlePointer ptr;
    if (mtp_decode_wheel(reportID, report, length, &h, &v)) {
        wheel_report(d, h, v);
    } else if (d->productID == MTP_BLE_PID &&
               mtp_decode_ble_middle(reportID, report, length, &down)) {
        middle_changed(d, MTP_SRC_VENDOR, down);
    } else if (d->productID == MTP_BLE_PID &&
               mtp_decode_ble_pointer(reportID, report, length, &ptr)) {
        /* Every mouse report restates button 3; pointer motion with the button
         * up during a gesture proves a lost release (see the core). */
        if (mtp_gesture_motion_proves_release(&d->gesture, &ptr)) {
            LOG_ERROR("middle-button release lost: gesture ended on pointer motion");
            gesture_ended();
            update_taps();
            return;
        }
        if (ptr.middle != d->gesture.down[MTP_SRC_STANDARD])
            middle_changed(d, MTP_SRC_STANDARD, ptr.middle);
        if (d->gesture.active && ptr.wheel) {
            mtp_tap_native_wheel(&g_tap);      /* macOS will emit it: drop it */
            update_taps();
        }
        if (d->gesture.active && ptr.motion) d->motionDuringGesture++;
    }
}

/* Value callbacks are restricted by matching to the two middle-button usages,
 * the Lenovo key page and the Print Screen key: never to the typing keys. */
static void value_callback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    /* Resolve through the element: older IOKit passes its queue as sender. */
    MTPDevice *d = device_for(IOHIDElementGetDevice(element));
    if (!d) return;
    uint32_t page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element);
    bool down = IOHIDValueGetIntegerValue(value) != 0;
    if (mtp_key_bit(&d->keys, IOHIDElementGetReportID(element), page, usage, down)) {
        settle_keys(d);
        return;
    }
    if (page == MTP_PRINT_SCREEN_PAGE && usage == MTP_PRINT_SCREEN_USAGE) {
        if (down) run_key(MTP_KEY_SCREENSHOT);
        return;
    }
    if (!scroll_active()) return;
    if (page == kHIDPage_Button && usage == 3) {
        if (d->productID == MTP_BLE_PID) {
            middle_changed(d, MTP_SRC_STANDARD, down);
        } else {
            /* USB: the receiver splits the keyboard into several interfaces,
             * so button 3 may sit on a different one than the vendor button.
             * Only the vendor button drives the gesture (one click per
             * press); button 3 only informs the tap. */
            d->nativeMiddleDown = down;
            update_taps();
        }
    } else if (page == 0xFFA0 && usage == 0xFB) {
        middle_changed(d, MTP_SRC_VENDOR, down);
    }
}

/* Integer property of a HID device (vendor or product ID); -1 if absent. */
static int32_t hid_int_property(IOHIDDeviceRef device, const char *key) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingASCII);
    CFTypeRef prop = name ? IOHIDDeviceGetProperty(device, name) : NULL;
    if (name) CFRelease(name);
    int32_t out = -1;
    if (!prop || CFGetTypeID(prop) != CFNumberGetTypeID() ||
        !CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt32Type, &out)) return -1;
    return out;
}

static void device_added(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    @autoreleasepool {
        (void)context; (void)result; (void)sender;
        int32_t vid = hid_int_property(device, kIOHIDVendorIDKey);
        int32_t pid = hid_int_property(device, kIOHIDProductIDKey);
        if (vid != MTP_LENOVO_VID || (pid != MTP_USB_PID && pid != MTP_BLE_PID)) return;
        if (device_for(device)) return;
        MTPDevice *d = NULL;
        for (int i = 0; i < MTP_MAX_DEVICES && !d; i++) if (!g_dev[i].device) d = &g_dev[i];
        if (!d) { LOG_ERROR("too many matching HID interfaces, ignoring one"); return; }
        *d = (MTPDevice){ .device = (IOHIDDeviceRef)CFRetain(device), .productID = pid };
        LOG_INFO("TrackPoint Keyboard II connected (%{public}s)", transport(pid));
        apply_settings(d);
        write_status();
    }
}

static void device_removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    @autoreleasepool {
        (void)context; (void)result; (void)sender;
        MTPDevice *d = device_for(device);
        if (!d) return;
        LOG_INFO("TrackPoint Keyboard II disconnected (%{public}s)", transport(d->productID));
        CFRelease(d->device);
        *d = (MTPDevice){0};         /* a gesture in progress is cancelled: no click */
        update_taps();
        write_status();
    }
}

/* Whole input reports (typing included, discarded on the first comparison)
 * reach this process only while scrolling is active. The value callback only
 * ever sees the matched elements (middle button, Lenovo keys, Print Screen). */
static void set_input_callbacks(void) {
    if (!g_hid) return;
    bool reports = scroll_active();
    bool values = reports || mtp_any_key_enabled(&g_cfg);
    IOHIDManagerRegisterInputReportCallback(g_hid, reports ? report_callback : NULL, NULL);
    IOHIDManagerRegisterInputValueCallback(g_hid, values ? value_callback : NULL, NULL);
}

static void start_hid(void) {
    if (g_hid) return;
    g_hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!g_hid) { LOG_ERROR("IOHIDManagerCreate failed"); return; }
    IOHIDManagerSetDeviceMatchingMultiple(g_hid, (__bridge CFArrayRef)@[
        @{@kIOHIDVendorIDKey: @(MTP_LENOVO_VID), @kIOHIDProductIDKey: @(MTP_USB_PID)},
        @{@kIOHIDVendorIDKey: @(MTP_LENOVO_VID), @kIOHIDProductIDKey: @(MTP_BLE_PID)},
    ]);
    IOHIDManagerSetInputValueMatchingMultiple(g_hid, (__bridge CFArrayRef)@[
        @{@kIOHIDElementUsagePageKey: @(kHIDPage_Button), @kIOHIDElementUsageKey: @3},
        @{@kIOHIDElementUsagePageKey: @0xFFA0, @kIOHIDElementUsageKey: @0xFB},
        @{@kIOHIDElementUsagePageKey: @(MTP_KEYS_PAGE)},
        @{@kIOHIDElementUsagePageKey: @(MTP_PRINT_SCREEN_PAGE),
          @kIOHIDElementUsageKey: @(MTP_PRINT_SCREEN_USAGE)},
    ]);
    /* Callbacks are registered before scheduling and opening. */
    IOHIDManagerRegisterDeviceMatchingCallback(g_hid, device_added, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_hid, device_removed, NULL);
    set_input_callbacks();
    IOHIDManagerScheduleWithRunLoop(g_hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn ret = IOHIDManagerOpen(g_hid, kIOHIDOptionsTypeNone);
    if (ret != kIOReturnSuccess) {
        LOG_ERROR("IOHIDManagerOpen failed: 0x%08x (will retry)", ret);
        IOHIDManagerUnscheduleFromRunLoop(g_hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(g_hid);
        g_hid = NULL;
        return;
    }
    LOG_INFO("waiting for the keyboard (event-driven)");
}

/* ── Permissions and start-up ────────────────────────────────────────────── */
static void start_components(void) {
    if (g_listenGranted) start_hid();
    if (g_axGranted && needs_taps() && !taps_ready()) {
        if (!g_buttonTap)
            g_buttonTap = create_tap(CGEventMaskBit(kCGEventOtherMouseDown) |
                CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventOtherMouseDragged));
        if (!g_scrollTap)
            g_scrollTap = create_tap(CGEventMaskBit(kCGEventScrollWheel));
        if (taps_ready()) {          /* scrolling can now be switched on */
            set_input_callbacks();
            apply_all();
        }
    }
    update_taps();
}

static void check_permissions(bool prompt) {
    @autoreleasepool {
        bool listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
        bool ax = AXIsProcessTrusted();
        if (prompt && !listen) IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        if (prompt && !ax && needs_accessibility())
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)
                @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
        if (listen != g_listenGranted || ax != g_axGranted || prompt) {
            if (!listen) LOG_ERROR("Input Monitoring not granted: keyboard cannot be read");
            if (!ax && needs_accessibility())
                LOG_ERROR("Accessibility not granted: scrolling, middle click and keys unavailable");
        }
        g_listenGranted = listen;
        g_axGranted = ax;
    }
}

/* While a permission or a component is missing (and only then), re-check
 * every few seconds: macOS sends no notification when the user grants one. */
static void ensure_running(bool prompt) {
    check_permissions(prompt);
    if (!g_axGranted && (g_buttonTap || g_scrollTap)) accessibility_lost();
    start_components();
    if (fully_running()) {
        if (g_recheckTimer) {
            dispatch_source_cancel(g_recheckTimer);
            g_recheckTimer = nil;
            LOG_INFO("all permissions granted, running");
        }
    } else if (!g_recheckTimer) {
        g_recheckTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                dispatch_get_main_queue());
        dispatch_source_set_timer(g_recheckTimer,
            dispatch_time(DISPATCH_TIME_NOW, MTP_RECHECK_SECONDS * NSEC_PER_SEC),
            MTP_RECHECK_SECONDS * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_recheckTimer, ^{ @autoreleasepool {
            ensure_running(false);
            write_status();
        }});
        dispatch_resume(g_recheckTimer);
    }
}

/* ── Configuration ───────────────────────────────────────────────────────── */
static void load_config(void) {
    NSMutableArray *errors = [NSMutableArray array];
    bool exists = false;
    g_cfg = mtp_config_load(config_path(), errors, &exists);
    g_cfgErrors = errors;
    g_cfgExists = exists;
    for (NSString *e in errors)
        LOG_ERROR("config: %{public}@ (default kept)", e);
}

/* A gesture in progress survives a reload (its pairing state too), unless
 * scrolling was just switched off. */
static void reload(void) {
    @autoreleasepool {
        load_config();
        if (!g_cfg.scrollEnabled) cancel_all_gestures();
        ensure_running(false);
        set_input_callbacks();
        apply_all();
        write_status();
        LOG_INFO("configuration reloaded");
    }
}

/* ── Sleep / wake ────────────────────────────────────────────────────────── */
static void power_callback(void *refcon, io_service_t service, natural_t message, void *arg) {
    @autoreleasepool {
        (void)refcon; (void)service;
        switch (message) {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(g_rootPort, (long)arg);
            break;
        case kIOMessageSystemWillSleep:
            cancel_all_gestures();
            g_tap = (MTPTapState){0};
            update_taps();
            IOAllowPowerChange(g_rootPort, (long)arg);
            break;
        case kIOMessageSystemHasPoweredOn:
            /* Permissions may have changed while asleep. A keyboard that
             * stayed attached may have lost its settings; a failed write is
             * retried (retry_device). One that reconnects is reconfigured by
             * device_added anyway. */
            ensure_running(false);
            apply_all();
            write_status();
            LOG_INFO("settings reapplied after wake");
            break;
        default:
            break;
        }
    }
}

static void start_power_notifications(void) {
    g_rootPort = IORegisterForSystemPower(NULL, &g_powerPort, power_callback, &g_powerNotifier);
    if (!g_rootPort) { LOG_ERROR("cannot register for sleep/wake notifications"); return; }
    IONotificationPortSetDispatchQueue(g_powerPort, dispatch_get_main_queue());
}

/* ── Entry point ─────────────────────────────────────────────────────────── */
static dispatch_source_t watch_signal(int sig, void (^handler)(void)) {
    signal(sig, SIG_IGN);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig,
                                                 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, handler);
    dispatch_resume(s);
    return s;
}

static int check_config(const char *path) {
    NSString *p = path ? @(path) : config_path();
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    bool exists = false;
    MTPConfig c = mtp_config_load(p, errors, &exists);
    printf("config: %s%s\n", p.UTF8String, exists ? "" : " (absent: defaults)");
    printf("trackpoint.sensitivity = %d\nscroll.enabled = %s\nscroll.speed = %g\n"
           "scroll.acceleration = %g\n"
           "scroll.horizontal = %s\nscroll.threshold = %d\nmiddle_button.click_if_no_scroll = %s\n"
           "keys.microphone = %s\nkeys.bluetooth = %s\nkeys.screenshot = %s\n"
           "logging.level = %s\n", c.sensitivity, c.scrollEnabled ? "true" : "false", c.speed,
           c.acceleration, c.horizontal ? "true" : "false", c.threshold, c.clickIfNoScroll ? "true" : "false",
           c.keyMicrophone ? "true" : "false", c.keyBluetooth ? "true" : "false",
           c.keyScreenshot ? "true" : "false",
           (const char *[]){"error", "info", "debug"}[c.logLevel]);
    for (NSString *e in errors) printf("error: %s (default kept)\n", e.UTF8String);
    return errors.count ? 1 : 0;
}

int main(int argc, const char *argv[]) {
    /* A reload request (SIGHUP) arriving before its handler is installed
     * would otherwise terminate the process; it is handled from below. */
    signal(SIGHUP, SIG_IGN);
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--version")) { puts(MTP_VERSION); return 0; }
        if ((argc == 2 || argc == 3) && !strcmp(argv[1], "--check-config"))
            return check_config(argc == 3 ? argv[2] : NULL);
        if (argc != 1) {
            fprintf(stderr, "usage: magictrackpointd [--version | --check-config [PATH]]\n");
            return 2;
        }
        if (getuid() == 0 || geteuid() == 0) {
            fprintf(stderr, "magictrackpointd must not run as root\n");
            return 1;
        }
        umask(077);
        g_log = os_log_create(MTP_LABEL, "daemon");
        load_config();
        LOG_INFO("magictrackpointd %{public}s starting", MTP_VERSION);

        static dispatch_source_t signals[3];   /* kept alive for the process lifetime */
        signals[0] = watch_signal(SIGHUP, ^{ reload(); });
        void (^quit)(void) = ^{
            cancel_all_gestures();
            restore_native_mode();
            LOG_INFO("stopping, keyboard left in its native mode");
            [NSFileManager.defaultManager removeItemAtPath:
                [status_dir() stringByAppendingPathComponent:@"status"] error:nil];
            exit(0);
        };
        signals[1] = watch_signal(SIGTERM, quit);
        signals[2] = watch_signal(SIGINT, quit);

        start_power_notifications();
        ensure_running(true);
        write_status();
        CFRunLoopRun();
    }
    return 0;
}
