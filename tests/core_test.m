/*
 * Unit tests for src/mtp_core.h (pure logic).
 *
 * Copyright (C) 2026 Jean-Christophe Baptiste
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   clang -O0 -g -fobjc-arc -Wall -Wextra -fsanitize=address,undefined \
 *         -I src -o <tmp>/core_test tests/core_test.m -framework Foundation
 *
 * Plain checks with a counter; every failure prints group, line, condition and
 * the values involved. Exit status is non-zero if any check failed.
 *
 * Lines tagged "NOTE" record questionable but non-failing behaviour.
 */
#import <Foundation/Foundation.h>
#include "mtp_core.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Mini harness ────────────────────────────────────────────────────────── */
static int g_checks, g_fails, g_notes;
static const char *g_group = "-";

#define CHECK(cond, ...) do { \
    g_checks++; \
    if (!(cond)) { \
        g_fails++; \
        fprintf(stderr, "FAIL [%s] core_test.m:%d: %s -- ", g_group, __LINE__, #cond); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
    } \
} while (0)

#define NOTE(...) do { g_notes++; printf("NOTE [%s] ", g_group); printf(__VA_ARGS__); putchar('\n'); } while (0)

static void group(const char *name) { g_group = name; }

/* ── Helpers ─────────────────────────────────────────────────────────────── */
static bool cfg_equal(MTPConfig a, MTPConfig b) {
    return a.sensitivity == b.sensitivity && a.scrollEnabled == b.scrollEnabled &&
        a.speed == b.speed && a.acceleration == b.acceleration &&
        a.horizontal == b.horizontal && a.threshold == b.threshold &&
        a.clickIfNoScroll == b.clickIfNoScroll && a.logLevel == b.logLevel;
}

static bool errors_contain(NSArray<NSString *> *errors, NSString *needle) {
    for (NSString *e in errors) if ([e containsString:needle]) return true;
    return false;
}

static const char *joined(NSArray<NSString *> *errors) {
    return [[errors componentsJoinedByString:@" | "] UTF8String] ?: "";
}

/* Runs mtp_config_from_plist on {section: {key: value}}. */
static MTPConfig cfg_one(NSString *section, NSString *key, id value,
                         NSMutableArray<NSString *> **errorsOut) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    MTPConfig c = mtp_config_from_plist(@{section: @{key: value}}, errors);
    if (errorsOut) *errorsOut = errors;
    return c;
}

/* Expects the value to be rejected: default kept (scroll.enabled: off, fail
 * closed), exactly one error naming the key. */
static void expect_rejected(int line, NSString *section, NSString *key, id value) {
    NSMutableArray<NSString *> *errors;
    MTPConfig c = cfg_one(section, key, value, &errors);
    NSString *full = [NSString stringWithFormat:@"%@.%@", section, key];
    MTPConfig want = [full isEqualToString:@"scroll.enabled"] ? mtp_failed_config()
                                                              : mtp_default_config();
    g_checks++;
    if (!cfg_equal(c, want) || errors.count != 1 || !errors_contain(errors, full)) {
        g_fails++;
        fprintf(stderr, "FAIL [%s] core_test.m:%d: %s = %s (%s) should be rejected with the "
                "default kept and one error naming the key; got %lu error(s): %s, config %s\n",
                g_group, line, full.UTF8String, [[value description] UTF8String],
                [NSStringFromClass([value class]) UTF8String], (unsigned long)errors.count,
                joined(errors), cfg_equal(c, want) ? "default" : "CHANGED");
    }
}
#define REJECT(sec, key, val) expect_rejected(__LINE__, sec, key, val)

static NSString *tmp_dir;

static NSString *tmp_path(NSString *name) {
    return [tmp_dir stringByAppendingPathComponent:name];
}

static void write_data(NSString *path, NSData *data) {
    if (![data writeToFile:path atomically:NO]) {
        fprintf(stderr, "test setup: cannot write %s\n", path.UTF8String);
        exit(3);
    }
}

static NSData *plist_data(id plist, NSPropertyListFormat format) {
    NSError *error = nil;
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:plist format:format
                                                         options:0 error:&error];
    if (!d) {
        fprintf(stderr, "test setup: cannot serialize plist: %s\n",
                error.localizedDescription.UTF8String);
        exit(3);
    }
    return d;
}

/* ── 1. Configuration: mtp_config_from_plist ─────────────────────────────── */
static void test_config_from_plist(void) {
    group("config.defaults");
    MTPConfig d = mtp_default_config();
    CHECK(d.sensitivity == 7 && d.scrollEnabled && d.speed == 1.0 && d.acceleration == 1.0 &&
          d.horizontal && d.threshold == 3 && d.clickIfNoScroll && d.logLevel == MTP_LOG_ERROR,
          "documented defaults: sensitivity 7, scroll on, speed 1, acceleration 1, "
          "horizontal on, threshold 3, click on, level error");
    group("config.acceleration");
    {
        NSMutableArray *errors;
        const double ok[] = {0.0, 0.5, 1.0, 1.5, 2.0};
        for (size_t i = 0; i < sizeof ok / sizeof *ok; i++) {
            MTPConfig c = cfg_one(@"scroll", @"acceleration", @(ok[i]), &errors);
            CHECK(errors.count == 0 && c.acceleration == ok[i], "acceleration %g accepted (%s)",
                  ok[i], joined(errors));
        }
        MTPConfig c = cfg_one(@"scroll", @"acceleration", @2, &errors);
        CHECK(errors.count == 0 && c.acceleration == 2.0, "integer acceleration 2 accepted");
        REJECT(@"scroll", @"acceleration", @(-0.01));
        REJECT(@"scroll", @"acceleration", @(2.01));
        REJECT(@"scroll", @"acceleration", @"1");
        REJECT(@"scroll", @"acceleration", @YES);
        REJECT(@"scroll", @"acceleration", @(NAN));
        REJECT(@"scroll", @"acceleration", @(INFINITY));
    }
    {
        NSMutableArray *errors = [NSMutableArray array];
        MTPConfig c = mtp_config_from_plist(nil, errors);
        CHECK(cfg_equal(c, d) && errors.count == 0, "nil plist -> defaults, no error (%s)",
              joined(errors));
        c = mtp_config_from_plist(@{}, errors);
        CHECK(cfg_equal(c, d) && errors.count == 0, "empty dict -> defaults, no error (%s)",
              joined(errors));
        c = mtp_config_from_plist(@{@"scroll": @{}, @"trackpoint": @{}, @"logging": @{},
                                    @"middle_button": @{}}, errors);
        CHECK(cfg_equal(c, d) && errors.count == 0, "empty sections -> defaults, no error (%s)",
              joined(errors));
    }

    group("config.valid");
    {
        NSMutableArray *errors = [NSMutableArray array];
        MTPConfig c = mtp_config_from_plist(@{
            @"trackpoint": @{@"sensitivity": @3},
            @"scroll": @{@"enabled": @NO, @"speed": @2.5, @"horizontal": @NO, @"threshold": @10},
            @"middle_button": @{@"click_if_no_scroll": @NO},
            @"logging": @{@"level": @"debug"},
        }, errors);
        CHECK(errors.count == 0, "all-valid config produced errors: %s", joined(errors));
        CHECK(c.sensitivity == 3, "sensitivity = %d", c.sensitivity);
        CHECK(c.scrollEnabled == false, "scroll.enabled");
        CHECK(c.speed == 2.5, "speed = %g", c.speed);
        CHECK(c.horizontal == false, "horizontal");
        CHECK(c.threshold == 10, "threshold = %d", c.threshold);
        CHECK(c.clickIfNoScroll == false, "click_if_no_scroll");
        CHECK(c.logLevel == MTP_LOG_DEBUG, "level = %d", c.logLevel);

        /* Booleans set to true explicitly on a config whose defaults are true. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"scroll": @{@"enabled": @YES, @"horizontal": @YES},
                                    @"middle_button": @{@"click_if_no_scroll": @YES}}, errors);
        CHECK(errors.count == 0 && c.scrollEnabled && c.horizontal && c.clickIfNoScroll,
              "explicit <true/> accepted (%s)", joined(errors));

        /* An integer is a valid number for speed. */
        c = cfg_one(@"scroll", @"speed", @2, &errors);
        CHECK(errors.count == 0 && c.speed == 2.0, "integer speed 2 accepted (%s, %g)",
              joined(errors), c.speed);
        /* A real with an integral value is accepted for integer keys. */
        c = cfg_one(@"scroll", @"threshold", @4.0, &errors);
        CHECK(errors.count == 0 && c.threshold == 4, "real 4.0 for threshold accepted as 4 "
              "(%s, %d)", joined(errors), c.threshold);
        c = cfg_one(@"scroll", @"threshold", @(-0.0), &errors);
        CHECK(errors.count == 0 && c.threshold == 0, "-0.0 threshold -> 0 (%s)", joined(errors));
    }

    group("config.logging");
    {
        NSArray *names = @[@"error", @"info", @"debug"];
        for (NSUInteger i = 0; i < names.count; i++) {
            NSMutableArray *errors;
            MTPConfig c = cfg_one(@"logging", @"level", names[i], &errors);
            CHECK(errors.count == 0 && c.logLevel == (MTPLogLevel)i,
                  "level '%s' -> %lu (got %d, %s)", [names[i] UTF8String], (unsigned long)i,
                  c.logLevel, joined(errors));
        }
        for (id bad in @[@"DEBUG", @"Info", @"warn", @"", @" debug", @1, @0, @YES, @[@"debug"],
                         @{}]) {
            NSMutableArray *errors;
            MTPConfig c = cfg_one(@"logging", @"level", bad, &errors);
            CHECK(c.logLevel == MTP_LOG_ERROR && errors.count == 1 &&
                  errors_contain(errors, @"logging.level"),
                  "bad level %s rejected with default (got %d, %s)",
                  [[bad description] UTF8String], c.logLevel, joined(errors));
        }
    }

    group("config.boundaries");
    {
        NSMutableArray *errors;
        MTPConfig c;
        c = cfg_one(@"trackpoint", @"sensitivity", @1, &errors);
        CHECK(errors.count == 0 && c.sensitivity == 1, "sensitivity 1 (%s)", joined(errors));
        c = cfg_one(@"trackpoint", @"sensitivity", @9, &errors);
        CHECK(errors.count == 0 && c.sensitivity == 9, "sensitivity 9 (%s)", joined(errors));
        REJECT(@"trackpoint", @"sensitivity", @0);
        REJECT(@"trackpoint", @"sensitivity", @10);
        REJECT(@"trackpoint", @"sensitivity", @(-1));
        REJECT(@"trackpoint", @"sensitivity", @(4294967303LL));   /* 7 + 2^32: no truncation */
        REJECT(@"trackpoint", @"sensitivity", @(LLONG_MAX));
        REJECT(@"trackpoint", @"sensitivity", @(ULLONG_MAX));
        REJECT(@"trackpoint", @"sensitivity", @(1e300));
        REJECT(@"trackpoint", @"sensitivity", @(8.9999999));

        c = cfg_one(@"scroll", @"speed", @0.1, &errors);
        CHECK(errors.count == 0 && c.speed == 0.1, "speed 0.1 (%s)", joined(errors));
        c = cfg_one(@"scroll", @"speed", @10, &errors);
        CHECK(errors.count == 0 && c.speed == 10.0, "speed 10 (%s)", joined(errors));
        c = cfg_one(@"scroll", @"speed", @10.0, &errors);
        CHECK(errors.count == 0 && c.speed == 10.0, "speed 10.0 (%s)", joined(errors));
        REJECT(@"scroll", @"speed", @0.09);
        REJECT(@"scroll", @"speed", @0.0999999);
        REJECT(@"scroll", @"speed", @10.01);
        REJECT(@"scroll", @"speed", @0);
        REJECT(@"scroll", @"speed", @(-1));
        REJECT(@"scroll", @"speed", @(-0.0));

        c = cfg_one(@"scroll", @"threshold", @0, &errors);
        CHECK(errors.count == 0 && c.threshold == 0, "threshold 0 (%s)", joined(errors));
        c = cfg_one(@"scroll", @"threshold", @50, &errors);
        CHECK(errors.count == 0 && c.threshold == 50, "threshold 50 (%s)", joined(errors));
        REJECT(@"scroll", @"threshold", @51);
        REJECT(@"scroll", @"threshold", @(-1));
    }

    group("config.types");
    {
        /* Integer keys. */
        REJECT(@"trackpoint", @"sensitivity", @"5");
        REJECT(@"trackpoint", @"sensitivity", @YES);
        REJECT(@"trackpoint", @"sensitivity", @NO);
        REJECT(@"trackpoint", @"sensitivity", @5.5);
        REJECT(@"trackpoint", @"sensitivity", @(NAN));
        REJECT(@"trackpoint", @"sensitivity", @(INFINITY));
        REJECT(@"trackpoint", @"sensitivity", @(-INFINITY));
        REJECT(@"trackpoint", @"sensitivity", @[@5]);
        REJECT(@"trackpoint", @"sensitivity", @{@"v": @5});
        REJECT(@"trackpoint", @"sensitivity", [NSData dataWithBytes:"\x05" length:1]);
        REJECT(@"trackpoint", @"sensitivity", [NSDate date]);
        REJECT(@"scroll", @"threshold", @3.5);
        REJECT(@"scroll", @"threshold", @"3");
        REJECT(@"scroll", @"threshold", @YES);
        REJECT(@"scroll", @"threshold", @(NAN));
        REJECT(@"scroll", @"threshold", @(INFINITY));
        /* Real key. */
        REJECT(@"scroll", @"speed", @"1.0");
        REJECT(@"scroll", @"speed", @YES);
        REJECT(@"scroll", @"speed", @(NAN));
        REJECT(@"scroll", @"speed", @(INFINITY));
        REJECT(@"scroll", @"speed", @(-INFINITY));
        /* Boolean keys: numbers 1/0 and strings are not booleans. */
        for (NSString *key in @[@"enabled", @"horizontal"]) {
            REJECT(@"scroll", key, @1);
            REJECT(@"scroll", key, @0);
            REJECT(@"scroll", key, @1.0);
            REJECT(@"scroll", key, @"true");
            REJECT(@"scroll", key, @"YES");
        }
        REJECT(@"middle_button", @"click_if_no_scroll", @1);
        REJECT(@"middle_button", @"click_if_no_scroll", @0);
        REJECT(@"middle_button", @"click_if_no_scroll", @"false");
    }

    group("config.structure");
    {
        NSMutableArray *errors = [NSMutableArray array];
        MTPConfig c = mtp_config_from_plist(@[@1, @2], errors);
        CHECK(cfg_equal(c, mtp_failed_config()) && errors.count == 1 &&
              errors_contain(errors, @"top level must be a dictionary"),
              "array top level (%s)", joined(errors));
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@"trackpoint", errors);
        CHECK(cfg_equal(c, mtp_failed_config()) && errors.count == 1 &&
              errors_contain(errors, @"top level"), "string top level (%s)", joined(errors));
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@42, errors);
        CHECK(cfg_equal(c, mtp_failed_config()) && errors.count == 1, "number top level (%s)",
              joined(errors));

        /* Unknown section: reported, other sections still applied. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"foo": @{@"x": @1},
                                    @"trackpoint": @{@"sensitivity": @4}}, errors);
        CHECK(errors.count == 1 && errors_contain(errors, @"unknown section 'foo'") &&
              c.sensitivity == 4, "unknown section reported, rest applied (%s, sens %d)",
              joined(errors), c.sensitivity);
        /* Section names are case-sensitive. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"Scroll": @{@"speed": @2}}, errors);
        CHECK(errors.count == 1 && errors_contain(errors, @"unknown section 'Scroll'") &&
              c.speed == 1.0, "'Scroll' is unknown (%s)", joined(errors));
        /* Non-string top-level key (possible in memory, not from a file). */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@1: @{}}, errors);
        CHECK(errors.count == 1 && errors_contain(errors, @"unknown section"),
              "non-string section key (%s)", joined(errors));

        /* Unknown key: reported, valid sibling keys still applied. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"scroll": @{@"bogus": @1, @"speed": @3}}, errors);
        CHECK(errors.count == 1 && errors_contain(errors, @"unknown key 'scroll.bogus'") &&
              c.speed == 3.0, "unknown key reported, sibling applied (%s, speed %g)",
              joined(errors), c.speed);
        /* A key valid in another section is unknown here. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"trackpoint": @{@"speed": @3}}, errors);
        CHECK(errors.count == 1 && errors_contain(errors, @"unknown key 'trackpoint.speed'") &&
              c.speed == 1.0, "misplaced key (%s)", joined(errors));

        /* Section that is not a dictionary: one error, no cascade, defaults. */
        for (NSString *sec in @[@"trackpoint", @"scroll", @"middle_button", @"logging"]) {
            for (id val in @[@[], @"x", @7, @YES]) {
                errors = [NSMutableArray array];
                c = mtp_config_from_plist(@{sec: val}, errors);
                NSString *want = [NSString stringWithFormat:@"%@ must be a dictionary", sec];
                /* scroll unreadable: scrolling stays off (fail closed). */
                MTPConfig expect = [sec isEqualToString:@"scroll"] ? mtp_failed_config()
                                                                   : mtp_default_config();
                CHECK(errors.count == 1 && errors_contain(errors, want) &&
                      cfg_equal(c, expect),
                      "section %s = %s (%s)", sec.UTF8String,
                      [[val description] UTF8String], joined(errors));
            }
        }

        /* One bad key does not affect the others; each bad key reported once. */
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{
            @"trackpoint": @{@"sensitivity": @12},
            @"scroll": @{@"enabled": @NO, @"speed": @"fast", @"horizontal": @1, @"threshold": @5},
            @"middle_button": @{@"click_if_no_scroll": @NO},
            @"logging": @{@"level": @"loud"},
            @"extra": @{},
        }, errors);
        CHECK(errors.count == 5, "5 errors expected, got %lu: %s", (unsigned long)errors.count,
              joined(errors));
        CHECK(c.sensitivity == 7 && !c.scrollEnabled && c.speed == 1.0 && c.horizontal &&
              c.threshold == 5 && !c.clickIfNoScroll && c.logLevel == MTP_LOG_ERROR,
              "valid keys applied, invalid kept default");
        CHECK(errors_contain(errors, @"trackpoint.sensitivity") &&
              errors_contain(errors, @"scroll.speed") && errors_contain(errors, @"scroll.horizontal") &&
              errors_contain(errors, @"logging.level") && errors_contain(errors, @"'extra'"),
              "each invalid entry named (%s)", joined(errors));
    }
}

/* ── 2. Configuration: mtp_config_load ───────────────────────────────────── */
static NSDictionary *sample_plist(void) {
    return @{
        @"trackpoint": @{@"sensitivity": @5},
        @"scroll": @{@"enabled": @YES, @"speed": @1.5, @"horizontal": @NO, @"threshold": @0},
        @"middle_button": @{@"click_if_no_scroll": @NO},
        @"logging": @{@"level": @"info"},
    };
}

static bool is_sample(MTPConfig c) {
    return c.sensitivity == 5 && c.scrollEnabled && c.speed == 1.5 && !c.horizontal &&
        c.threshold == 0 && !c.clickIfNoScroll && c.logLevel == MTP_LOG_INFO;
}

/* A valid XML plist of exactly `size` bytes (padding inside an XML comment). */
static NSData *xml_plist_of_size(NSUInteger size) {
    NSString *head = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<!--";
    NSString *tail = @"-->\n<dict><key>trackpoint</key><dict><key>sensitivity</key>"
        "<integer>2</integer></dict></dict>\n</plist>\n";
    NSUInteger fixed = head.length + tail.length;
    if (size < fixed) return nil;
    NSString *pad = [@"" stringByPaddingToLength:size - fixed withString:@" " startingAtIndex:0];
    return [[NSString stringWithFormat:@"%@%@%@", head, pad, tail]
            dataUsingEncoding:NSUTF8StringEncoding];
}

static void test_config_load(void) {
    group("config.load");
    NSMutableArray *errors;
    bool exists;
    MTPConfig c;

    /* Missing file. */
    errors = [NSMutableArray array]; exists = true;
    c = mtp_config_load(tmp_path(@"absent.plist"), errors, &exists);
    CHECK(!exists && errors.count == 0 && cfg_equal(c, mtp_default_config()),
          "missing file: exists=%d errors=%s", exists, joined(errors));
    errors = [NSMutableArray array]; exists = true;
    c = mtp_config_load(tmp_path(@"no/such/dir/config.plist"), errors, &exists);
    CHECK(!exists && errors.count == 0, "missing parent dir: exists=%d (%s)", exists,
          joined(errors));
    errors = [NSMutableArray array]; exists = true;
    c = mtp_config_load(@"", errors, &exists);
    CHECK(!exists && errors.count == 0 && cfg_equal(c, mtp_default_config()),
          "empty path: exists=%d (%s)", exists, joined(errors));

    /* Directory. */
    NSString *dir = tmp_path(@"adir.plist");
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:NO
                                             attributes:nil error:nil];
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(dir, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"regular file") &&
          cfg_equal(c, mtp_failed_config()), "directory: exists=%d (%s)", exists, joined(errors));

    /* Valid XML plist. */
    NSString *xml = tmp_path(@"valid.xml.plist");
    write_data(xml, plist_data(sample_plist(), NSPropertyListXMLFormat_v1_0));
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(xml, errors, &exists);
    CHECK(exists && errors.count == 0 && is_sample(c), "valid XML plist: exists=%d (%s)",
          exists, joined(errors));

    /* Valid binary plist. */
    NSString *bin = tmp_path(@"valid.bin.plist");
    NSData *binData = plist_data(sample_plist(), NSPropertyListBinaryFormat_v1_0);
    CHECK(binData.length >= 8 && memcmp(binData.bytes, "bplist00", 8) == 0,
          "binary plist fixture really is binary");
    write_data(bin, binData);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(bin, errors, &exists);
    CHECK(exists && errors.count == 0 && is_sample(c), "valid binary plist: exists=%d (%s)",
          exists, joined(errors));

    /* Valid file with invalid content: errors propagate from validation. */
    NSString *badvals = tmp_path(@"badvals.plist");
    write_data(badvals, plist_data(@{@"scroll": @{@"speed": @99, @"threshold": @2}},
                                   NSPropertyListXMLFormat_v1_0));
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(badvals, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"scroll.speed") &&
          c.speed == 1.0 && c.threshold == 2, "invalid values in file (%s)", joined(errors));

    /* Top-level array in a file. */
    NSString *arr = tmp_path(@"array.plist");
    write_data(arr, plist_data(@[@1], NSPropertyListXMLFormat_v1_0));
    errors = [NSMutableArray array];
    c = mtp_config_load(arr, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"top level"),
          "array file (%s)", joined(errors));

    /* Garbage bytes. */
    NSString *garbage = tmp_path(@"garbage.plist");
    uint8_t junk[512];
    for (size_t i = 0; i < sizeof junk; i++) junk[i] = (uint8_t)(i * 151u + 7u);
    write_data(garbage, [NSData dataWithBytes:junk length:sizeof junk]);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(garbage, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"unreadable property list") &&
          cfg_equal(c, mtp_failed_config()), "garbage: (%s)", joined(errors));

    /* Truncated XML. */
    NSString *trunc_ = tmp_path(@"truncated.plist");
    NSData *full = plist_data(sample_plist(), NSPropertyListXMLFormat_v1_0);
    write_data(trunc_, [full subdataWithRange:NSMakeRange(0, full.length / 2)]);
    errors = [NSMutableArray array];
    c = mtp_config_load(trunc_, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"unreadable property list") &&
          cfg_equal(c, mtp_failed_config()), "truncated XML: (%s)", joined(errors));

    /* Empty file. */
    NSString *empty = tmp_path(@"empty.plist");
    write_data(empty, [NSData data]);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(empty, errors, &exists);
    CHECK(exists && errors.count == 1 && cfg_equal(c, mtp_failed_config()),
          "empty file: exists=%d (%s)", exists, joined(errors));

    /* Size limit: exactly 64 KiB accepted, one byte more rejected. */
    NSString *at = tmp_path(@"at-limit.plist");
    NSData *atData = xml_plist_of_size(MTP_CONFIG_MAX_BYTES);
    CHECK(atData.length == MTP_CONFIG_MAX_BYTES, "fixture size %lu", (unsigned long)atData.length);
    write_data(at, atData);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(at, errors, &exists);
    CHECK(exists && errors.count == 0 && c.sensitivity == 2,
          "65536-byte plist accepted (%s, sens %d)", joined(errors), c.sensitivity);
    NSString *over = tmp_path(@"over-limit.plist");
    write_data(over, xml_plist_of_size(MTP_CONFIG_MAX_BYTES + 1));
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(over, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"64 KiB") &&
          cfg_equal(c, mtp_failed_config()), "65537-byte plist rejected (%s, sens %d)",
          joined(errors), c.sensitivity);
    NSString *big = tmp_path(@"big.plist");
    write_data(big, [NSMutableData dataWithLength:1 << 20]);
    errors = [NSMutableArray array];
    c = mtp_config_load(big, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"64 KiB"),
          "1 MiB file rejected (%s)", joined(errors));

    /* FIFO: must be rejected without blocking on open/read. */
    NSString *fifo = tmp_path(@"fifo.plist");
    if (mkfifo(fifo.fileSystemRepresentation, 0600) == 0) {
        errors = [NSMutableArray array]; exists = false;
        c = mtp_config_load(fifo, errors, &exists);
        CHECK(exists && errors.count == 1 && errors_contain(errors, @"regular file"),
              "FIFO rejected (%s)", joined(errors));
    } else {
        CHECK(false, "test setup: mkfifo failed");
    }

    /* Character device. */
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(@"/dev/null", errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"regular file"),
          "/dev/null rejected (%s)", joined(errors));

    /* Unreadable regular file. */
    NSString *noread = tmp_path(@"noread.plist");
    write_data(noread, plist_data(sample_plist(), NSPropertyListXMLFormat_v1_0));
    chmod(noread.fileSystemRepresentation, 0000);
    if (geteuid() != 0) {
        errors = [NSMutableArray array]; exists = false;
        c = mtp_config_load(noread, errors, &exists);
        CHECK(exists && errors.count == 1 && errors_contain(errors, @"cannot open") &&
              cfg_equal(c, mtp_failed_config()), "mode 000 file (%s)", joined(errors));
    }
    chmod(noread.fileSystemRepresentation, 0600);

    /* Symlink to a valid config (common with dotfile managers): record behaviour. */
    NSString *link = tmp_path(@"link.plist");
    symlink(xml.fileSystemRepresentation, link.fileSystemRepresentation);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(link, errors, &exists);
    CHECK(exists && errors.count == 0 && is_sample(c),
          "symlinked config (stow/chezmoi style) loads its target (%s)", joined(errors));
    /* Symlink to a directory is still rejected. */
    NSString *dirlink = tmp_path(@"dirlink.plist");
    symlink(dir.fileSystemRepresentation, dirlink.fileSystemRepresentation);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(dirlink, errors, &exists);
    CHECK(exists && errors.count == 1 && errors_contain(errors, @"regular file"),
          "symlink to a directory rejected (%s)", joined(errors));
    /* Dangling symlink. */
    NSString *dangling = tmp_path(@"dangling.plist");
    symlink(tmp_path(@"nowhere").fileSystemRepresentation, dangling.fileSystemRepresentation);
    errors = [NSMutableArray array]; exists = false;
    c = mtp_config_load(dangling, errors, &exists);
    CHECK(cfg_equal(c, mtp_default_config()), "dangling symlink -> defaults (%s)",
          joined(errors));
}

/* ── 3. Report building ──────────────────────────────────────────────────── */
static void test_reports(void) {
    group("report.build");
    MTPConfigReport r;
    for (int v = 0; v <= 255; v += 1) {
        memset(&r, 0xAA, sizeof r);
        bool ok = mtp_build_config_report(MTP_USB_PID, MTP_CMD_SENSITIVITY, (uint8_t)v, &r);
        static const uint8_t zero[5];
        if (!(ok && r.feature && r.reportID == 0x13 && r.length == 8 && r.bytes[0] == 0x13 &&
              r.bytes[1] == MTP_CMD_SENSITIVITY && r.bytes[2] == v &&
              memcmp(r.bytes + 3, zero, 5) == 0)) {
            CHECK(false, "USB report for value %d: ok=%d feature=%d id=0x%02x len=%ld "
                  "bytes=%02x %02x %02x %02x %02x %02x %02x %02x", v, ok, r.feature, r.reportID,
                  r.length, r.bytes[0], r.bytes[1], r.bytes[2], r.bytes[3], r.bytes[4],
                  r.bytes[5], r.bytes[6], r.bytes[7]);
            break;
        }
    }

    memset(&r, 0xAA, sizeof r);
    bool ok = mtp_build_config_report(MTP_USB_PID, MTP_CMD_PREFERRED_SCROLL, 1, &r);
    const uint8_t usb[8] = {0x13, 0x09, 0x01, 0, 0, 0, 0, 0};
    CHECK(ok && r.feature && r.length == 8 && memcmp(r.bytes, usb, 8) == 0,
          "USB preferred scrolling = 13 09 01 00 00 00 00 00");

    memset(&r, 0xAA, sizeof r);
    ok = mtp_build_config_report(MTP_BLE_PID, MTP_CMD_SENSITIVITY, 7, &r);
    const uint8_t ble[8] = {0x18, 0x02, 0x07, 0, 0, 0, 0, 0};
    CHECK(ok && !r.feature && r.reportID == 0x18 && r.length == 3 &&
          memcmp(r.bytes, ble, 8) == 0, "BLE sensitivity 7 = Output 0x18, 18 02 07 (len %ld)",
          r.length);
    memset(&r, 0xAA, sizeof r);
    ok = mtp_build_config_report(MTP_BLE_PID, MTP_CMD_PREFERRED_SCROLL, 0, &r);
    CHECK(ok && !r.feature && r.length == 3 && r.bytes[0] == 0x18 && r.bytes[1] == 0x09 &&
          r.bytes[2] == 0x00, "BLE preferred scrolling off = 18 09 00");

    const int badPIDs[] = {0x6048 /* Compact USB */, 0x6047 /* Compact BT */, 0x60EF, 0x60E0,
                           0, -1, MTP_LENOVO_VID, 0x160EE};
    for (size_t i = 0; i < sizeof badPIDs / sizeof *badPIDs; i++) {
        memset(&r, 0xAA, sizeof r);
        ok = mtp_build_config_report(badPIDs[i], MTP_CMD_SENSITIVITY, 7, &r);
        CHECK(!ok, "PID 0x%x must be rejected", badPIDs[i]);
        CHECK(r.length == 0, "rejected PID 0x%x leaves length 0 (got %ld)", badPIDs[i], r.length);
    }
}

/* ── 4. Decoding ─────────────────────────────────────────────────────────── */
static void test_decoding(void) {
    group("decode.wheel");
    uint8_t h = 0xEE, v = 0xEE;
    const uint8_t good[4] = {0x16, 0x01, 0xFF, 0x00};
    CHECK(mtp_decode_wheel(0x16, good, 3, &h, &v) && h == 0x01 && v == 0xFF,
          "16 01 FF -> h=01 v=FF (got %02x %02x)", h, v);
    const uint8_t zero[3] = {0x16, 0x00, 0x00};
    CHECK(mtp_decode_wheel(0x16, zero, 3, &h, &v) && h == 0 && v == 0, "16 00 00");

    h = v = 0xEE;
    CHECK(!mtp_decode_wheel(0x15, good, 3, &h, &v), "wrong report ID 0x15");
    CHECK(!mtp_decode_wheel(0x02, good, 3, &h, &v), "wrong report ID 0x02");
    CHECK(!mtp_decode_wheel(0x116, good, 3, &h, &v), "report ID 0x116 (truncation)");
    CHECK(!mtp_decode_wheel(0x16, good, 2, &h, &v), "length 2");
    CHECK(!mtp_decode_wheel(0x16, good, 4, &h, &v), "length 4");
    CHECK(!mtp_decode_wheel(0x16, good, 0, &h, &v), "length 0");
    CHECK(!mtp_decode_wheel(0x16, good, -1, &h, &v), "length -1");
    const uint8_t mismatch[3] = {0x15, 0x01, 0x00};
    CHECK(!mtp_decode_wheel(0x16, mismatch, 3, &h, &v), "embedded ID 0x15 with reportID 0x16");
    CHECK(!mtp_decode_wheel(0x16, NULL, 3, &h, &v), "NULL report");
    CHECK(h == 0xEE && v == 0xEE, "outputs untouched on rejection (h=%02x v=%02x)", h, v);

    group("decode.ble_middle");
    uint8_t rep[10] = {0x15, 0x00, 0x04, 0, 0, 0, 0, 0, 0, 0};
    bool down = false;
    CHECK(mtp_decode_ble_middle(0x15, rep, 9, &down) && down, "byte2 0x04 -> down");
    rep[2] = 0x00; down = true;
    CHECK(mtp_decode_ble_middle(0x15, rep, 9, &down) && !down, "byte2 0x00 -> up");
    rep[2] = 0xFB; down = true;
    CHECK(mtp_decode_ble_middle(0x15, rep, 9, &down) && !down, "byte2 0xFB (all but 0x04) -> up");
    rep[2] = 0xFF; down = false;
    CHECK(mtp_decode_ble_middle(0x15, rep, 9, &down) && down, "byte2 0xFF -> down");
    for (int bit = 0; bit < 8; bit++) {
        rep[2] = (uint8_t)(1u << bit);
        down = !down;
        bool ok = mtp_decode_ble_middle(0x15, rep, 9, &down);
        CHECK(ok && down == (bit == 2), "byte2 bit %d -> down=%d", bit, down);
    }
    rep[2] = 0x00; rep[1] = 0x04; rep[3] = 0x04; rep[8] = 0xFF; down = true;
    CHECK(mtp_decode_ble_middle(0x15, rep, 9, &down) && !down, "0x04 in other bytes ignored");
    memset(rep, 0, sizeof rep); rep[0] = 0x15; rep[2] = 0x04;
    down = false;
    CHECK(!mtp_decode_ble_middle(0x15, rep, 8, &down), "length 8");
    CHECK(!mtp_decode_ble_middle(0x15, rep, 10, &down), "length 10");
    CHECK(!mtp_decode_ble_middle(0x15, rep, 3, &down), "length 3");
    CHECK(!mtp_decode_ble_middle(0x16, rep, 9, &down), "reportID 0x16");
    rep[0] = 0x16;
    CHECK(!mtp_decode_ble_middle(0x15, rep, 9, &down), "embedded ID mismatch");
    CHECK(!mtp_decode_ble_middle(0x15, NULL, 9, &down), "NULL");
    CHECK(!down, "output untouched on rejection");
}

/* ── 5. Byte → units ─────────────────────────────────────────────────────── */
static int documented_units(int raw) {
    /* 01…07 → +1…+7; FF…F9 → −1…−7 (signed byte); else 0 (explicit table). */
    static const struct { int raw, units; } table[] = {
        {0x01, 1}, {0x02, 2}, {0x03, 3}, {0x04, 4}, {0x05, 5}, {0x06, 6}, {0x07, 7},
        {0xFF, -1}, {0xFE, -2}, {0xFD, -3}, {0xFC, -4}, {0xFB, -5}, {0xFA, -6}, {0xF9, -7},
    };
    for (size_t i = 0; i < sizeof table / sizeof *table; i++)
        if (table[i].raw == raw) return table[i].units;
    return 0;
}

static void test_wheel_units(void) {
    group("wheel_units");
    int mismatches = 0, nonzero = 0;
    for (int raw = 0; raw <= 255; raw++) {
        int got = mtp_wheel_units((uint8_t)raw), want = documented_units(raw);
        if (got != want) {
            mismatches++;
            CHECK(got == want, "raw 0x%02x -> %d, documented %d", raw, got, want);
        }
        if (got) nonzero++;
        CHECK(got >= -7 && got <= 7, "raw 0x%02x out of range: %d", raw, got);
    }
    CHECK(mismatches == 0, "%d mismatches against the documented table", mismatches);
    CHECK(nonzero == 14, "exactly 14 raw values move (got %d)", nonzero);
    for (int k = 1; k <= 7; k++)
        CHECK(mtp_wheel_units((uint8_t)k) == -mtp_wheel_units((uint8_t)(0x100 - k)),
              "symmetry: units(0x%02x)=%d vs units(0x%02x)=%d", k, mtp_wheel_units((uint8_t)k),
              0x100 - k, mtp_wheel_units((uint8_t)(0x100 - k)));
    CHECK(mtp_wheel_units(0xFF) == -mtp_wheel_units(0x01), "FF mirrors 01");
    const int neutral[] = {0x00, 0x08, 0x10, 0x7F, 0x80, 0x81, 0xF0, 0xF7, 0xF8};
    for (size_t i = 0; i < sizeof neutral / sizeof *neutral; i++)
        CHECK(mtp_wheel_units((uint8_t)neutral[i]) == 0, "raw 0x%02x is neutral", neutral[i]);
    /* Ramp measured on the keyboard: FF/FE/FD mirror 01/02/03. */
    CHECK(mtp_wheel_units(0xFE) == -2 && mtp_wheel_units(0xFD) == -3,
          "FE and FD mirror 02 and 03 (measured ramp)");
}

/* ── 6. Gesture state machine ────────────────────────────────────────────── */
typedef struct {
    int clicks, emits, reports;
    long sumX, sumY;
    int32_t lastX, lastY;
    bool lastEmit;
} Tally;

static MTPGestureResult edge(MTPGesture *g, MTPMiddleSource s, bool down, const MTPConfig *c,
                             Tally *t) {
    MTPGestureResult r = mtp_gesture_middle(g, s, down, c);
    if (r == MTP_CLICK) t->clicks++;
    return r;
}

static bool wheel(MTPGesture *g, uint8_t h, uint8_t v, const MTPConfig *c, bool natural,
                  Tally *t) {
    int32_t x = 0x5A5A5A5A, y = 0x5A5A5A5A;
    bool e = mtp_gesture_wheel(g, h, v, c, natural, &x, &y);
    t->reports++;
    t->lastX = x; t->lastY = y; t->lastEmit = e;
    if (e) { t->emits++; t->sumX += x; t->sumY += y; }
    /* Invariant: emit iff a non-zero delta is written; outputs always written. */
    CHECK(x != 0x5A5A5A5A && y != 0x5A5A5A5A, "outputs not written");
    CHECK(e == (x != 0 || y != 0), "return value %d inconsistent with deltas %d,%d", e, x, y);
    return e;
}

/* Linear (acceleration 0): the scaling tests below check exact linear totals;
 * the force curve has its own group (gesture.H.acceleration). */
static MTPConfig cfg_t(int threshold) {
    MTPConfig c = mtp_default_config();
    c.threshold = threshold;
    c.acceleration = 0;
    return c;
}

static void test_gesture(void) {
    const uint8_t UP1 = 0x01, DN1 = 0xFF;

    group("gesture.A.click");
    {
        MTPConfig c = mtp_default_config();
        for (int s = 0; s < 2; s++) {
            MTPGesture g = {0}; Tally t = {0};
            CHECK(edge(&g, (MTPMiddleSource)s, true, &c, &t) == MTP_NOTHING, "press: nothing");
            CHECK(g.active, "active after press");
            CHECK(edge(&g, (MTPMiddleSource)s, false, &c, &t) == MTP_CLICK, "release: click");
            CHECK(t.clicks == 1 && !g.active, "exactly one click, source %d", s);
            CHECK(edge(&g, (MTPMiddleSource)s, false, &c, &t) == MTP_NOTHING && t.clicks == 1,
                  "second release: nothing");
        }
        c.clickIfNoScroll = false;
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t);
        CHECK(t.clicks == 0 && !g.active, "clickIfNoScroll=false: no click");
        /* Release without press. */
        MTPGesture g2 = {0}; Tally t2 = {0};
        c = mtp_default_config();
        edge(&g2, MTP_SRC_STANDARD, false, &c, &t2);
        edge(&g2, MTP_SRC_VENDOR, false, &c, &t2);
        CHECK(t2.clicks == 0 && !g2.active, "release without press: nothing");
        /* Several gestures in a row: one click each. */
        Tally t3 = {0};
        for (int i = 0; i < 5; i++) {
            edge(&g2, MTP_SRC_STANDARD, true, &c, &t3);
            edge(&g2, MTP_SRC_STANDARD, false, &c, &t3);
        }
        CHECK(t3.clicks == 5, "5 gestures -> 5 clicks (got %d)", t3.clicks);
    }

    group("gesture.B.scroll_no_click");
    {
        MTPConfig c = cfg_t(3);
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        for (int i = 0; i < 10; i++) wheel(&g, 0, UP1, &c, false, &t);
        CHECK(t.emits == 8 && t.sumY == 80 && t.sumX == 0, "10 reports, threshold 3 -> 8 emits / "
              "80 px (got %d / %ld)", t.emits, t.sumY);
        CHECK(g.scrolling, "scrolling");
        CHECK(edge(&g, MTP_SRC_STANDARD, false, &c, &t) == MTP_NOTHING && t.clicks == 0,
              "no click after scrolling");
        CHECK(!g.active && !g.scrolling, "state reset on release");

        /* Scroll deltas that round to 0 px still suppress the click. */
        MTPConfig tiny = cfg_t(0); tiny.speed = 0.01;   /* below the config range on purpose */
        MTPGesture g2 = {0}; Tally t2 = {0};
        edge(&g2, MTP_SRC_STANDARD, true, &tiny, &t2);
        wheel(&g2, 0, UP1, &tiny, true, &t2);
        CHECK(t2.emits == 0 && g2.scrolling, "0.1 px: nothing emitted but scrolling");
        CHECK(edge(&g2, MTP_SRC_STANDARD, false, &tiny, &t2) == MTP_NOTHING && t2.clicks == 0,
              "no click when the scroll rounded to 0 px");
        /* Same with the minimum configurable speed and threshold > 0. */
        MTPConfig slow = cfg_t(2); slow.speed = 0.1;
        MTPGesture g3 = {0}; Tally t3 = {0};
        edge(&g3, MTP_SRC_STANDARD, true, &slow, &t3);
        wheel(&g3, 0, UP1, &slow, false, &t3);
        wheel(&g3, 0, UP1, &slow, false, &t3);
        CHECK(t3.emits == 1 && t3.sumY == 1, "speed 0.1: 1 unit = 1 px (got %ld)", t3.sumY);
        edge(&g3, MTP_SRC_STANDARD, false, &slow, &t3);
        CHECK(t3.clicks == 0, "no click at minimum speed");
    }

    group("gesture.C.threshold");
    {
        MTPConfig c = cfg_t(3);
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        wheel(&g, 0, UP1, &c, false, &t);
        wheel(&g, 0, DN1, &c, false, &t);
        CHECK(t.emits == 0 && g.travel == 2 && !g.scrolling, "sub-threshold: nothing, travel 2 "
              "(got %u)", g.travel);
        CHECK(edge(&g, MTP_SRC_STANDARD, false, &c, &t) == MTP_CLICK && t.clicks == 1,
              "sub-threshold release -> one click");

        /* Exact crossing report emitted in full; earlier ones never. */
        MTPConfig c5 = cfg_t(5);
        MTPGesture g2 = {0}; Tally t2 = {0};
        edge(&g2, MTP_SRC_STANDARD, true, &c5, &t2);
        CHECK(!wheel(&g2, 0, 0x02, &c5, false, &t2), "travel 2 < 5");
        CHECK(!wheel(&g2, 0, 0x02, &c5, false, &t2), "travel 4 < 5");
        CHECK(wheel(&g2, 0, 0x03, &c5, false, &t2) && t2.lastY == 30 && t2.lastX == 0,
              "crossing report (3 units) emitted in full: 30 px (got %d)", t2.lastY);
        CHECK(wheel(&g2, 0, UP1, &c5, false, &t2) && t2.lastY == 10, "next report 10 px");
        CHECK(t2.sumY == 40 && t2.emits == 2, "earlier reports never emitted (sum %ld)", t2.sumY);
        CHECK(g2.travel == 8, "travel 8 (got %u)", g2.travel);

        /* Crossing exactly at the threshold (travel == threshold). */
        MTPGesture g3 = {0}; Tally t3 = {0};
        edge(&g3, MTP_SRC_STANDARD, true, &c, &t3);
        wheel(&g3, 0, 0x02, &c, false, &t3);
        CHECK(wheel(&g3, 0, UP1, &c, false, &t3) && t3.lastY == 10, "travel == threshold scrolls");

        /* Horizontal counts towards the same threshold. */
        MTPGesture g3b = {0}; Tally t3b = {0};
        edge(&g3b, MTP_SRC_STANDARD, true, &c, &t3b);
        wheel(&g3b, 0x02, 0, &c, false, &t3b);
        CHECK(wheel(&g3b, 0, UP1, &c, false, &t3b) && t3b.lastY == 10,
              "mixed-axis travel crosses the threshold");

        /* Threshold 0: first non-zero report scrolls. */
        MTPConfig c0 = cfg_t(0);
        MTPGesture g4 = {0}; Tally t4 = {0};
        edge(&g4, MTP_SRC_STANDARD, true, &c0, &t4);
        CHECK(!wheel(&g4, 0, 0, &c0, false, &t4) && !g4.scrolling,
              "threshold 0: zero report does not scroll");
        CHECK(wheel(&g4, 0, UP1, &c0, false, &t4) && t4.lastY == 10,
              "threshold 0: first non-zero report scrolls");
        edge(&g4, MTP_SRC_STANDARD, false, &c0, &t4);
        CHECK(t4.clicks == 0, "threshold 0: no click after scroll");
        MTPGesture g5 = {0}; Tally t5 = {0};
        edge(&g5, MTP_SRC_STANDARD, true, &c0, &t5);
        wheel(&g5, 0, 0, &c0, false, &t5);
        edge(&g5, MTP_SRC_STANDARD, false, &c0, &t5);
        CHECK(t5.clicks == 1, "threshold 0, only zero reports -> click");

        /* Threshold 50 (maximum). */
        MTPConfig c50 = cfg_t(50);
        MTPGesture g6 = {0}; Tally t6 = {0};
        edge(&g6, MTP_SRC_STANDARD, true, &c50, &t6);
        for (int i = 0; i < 49; i++) wheel(&g6, 0, UP1, &c50, false, &t6);
        CHECK(t6.emits == 0, "49 < 50: nothing");
        CHECK(wheel(&g6, 0, UP1, &c50, false, &t6), "50th unit scrolls");
        MTPGesture g7 = {0}; Tally t7 = {0};
        edge(&g7, MTP_SRC_STANDARD, true, &c50, &t7);
        for (int i = 0; i < 7; i++) wheel(&g7, 0, 0x07, &c50, false, &t7);   /* 49 */
        CHECK(t7.emits == 0, "49 units in 7 reports: nothing");
        edge(&g7, MTP_SRC_STANDARD, false, &c50, &t7);
        CHECK(t7.clicks == 1, "49 units < 50 -> click");
    }

    group("gesture.D.not_held");
    {
        MTPConfig c = cfg_t(0);
        MTPGesture g = {0}; Tally t = {0};
        for (int i = 0; i < 5; i++)
            CHECK(!wheel(&g, 0, 0x07, &c, false, &t), "not held: no emission");
        CHECK(g.ignored == 5 && g.travel == 0 && !g.scrolling && !g.active,
              "ignored=5 travel=0 (got %u, %u)", g.ignored, g.travel);
        CHECK(t.clicks == 0, "never a click");
        /* Reports before the press do not count towards the gesture. */
        MTPConfig c3 = cfg_t(3);
        edge(&g, MTP_SRC_STANDARD, true, &c3, &t);
        CHECK(g.ignored == 5 && g.travel == 0, "ignored kept, travel reset at press");
        edge(&g, MTP_SRC_STANDARD, false, &c3, &t);
        CHECK(t.clicks == 1, "click after press/release despite earlier stray reports");
        /* Reports after the release are ignored as well. */
        CHECK(!wheel(&g, 0, UP1, &c3, false, &t) && g.ignored == 6, "after release: ignored");
        /* Zero reports while not held also count as ignored (diagnostic). */
        wheel(&g, 0, 0, &c3, false, &t);
        CHECK(g.ignored == 7, "zero report while not held counted (got %u)", g.ignored);
        /* Saturation. */
        g.ignored = UINT32_MAX - 1;
        wheel(&g, 0, UP1, &c3, false, &t);
        wheel(&g, 0, UP1, &c3, false, &t);
        CHECK(g.ignored == UINT32_MAX, "ignored saturates (got %u)", g.ignored);
    }

    group("gesture.E.two_sources");
    {
        MTPConfig c = mtp_default_config();
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        edge(&g, MTP_SRC_VENDOR, true, &c, &t);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t);
        CHECK(g.active && t.clicks == 0, "std released, vendor held: still active");
        edge(&g, MTP_SRC_VENDOR, false, &c, &t);
        CHECK(!g.active && t.clicks == 1, "both released: ends with one click (got %d)", t.clicks);

        /* Vendor first, standard second; release in the same order. */
        Tally t2 = {0};
        edge(&g, MTP_SRC_VENDOR, true, &c, &t2);
        edge(&g, MTP_SRC_STANDARD, true, &c, &t2);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t2);
        CHECK(g.active && t2.clicks == 0, "vendor released, std held: still active");
        edge(&g, MTP_SRC_STANDARD, false, &c, &t2);
        CHECK(!g.active && t2.clicks == 1, "one click (got %d)", t2.clicks);

        /* Scrolling across the two sources: one gesture, no click. */
        MTPConfig c0 = cfg_t(0);
        Tally t3 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c0, &t3);
        edge(&g, MTP_SRC_VENDOR, true, &c0, &t3);
        wheel(&g, 0, UP1, &c0, false, &t3);
        edge(&g, MTP_SRC_STANDARD, false, &c0, &t3);
        CHECK(wheel(&g, 0, UP1, &c0, false, &t3), "still scrolling while vendor held");
        edge(&g, MTP_SRC_VENDOR, false, &c0, &t3);
        CHECK(t3.clicks == 0 && t3.emits == 2, "scroll over two sources: no click");

        /* Duplicate edges. */
        Tally t4 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t4);
        wheel(&g, 0, UP1, &c, false, &t4);   /* travel 1 */
        edge(&g, MTP_SRC_STANDARD, true, &c, &t4);
        CHECK(g.travel == 1, "duplicate down does not restart the gesture (travel %u)", g.travel);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t4);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t4);
        CHECK(t4.clicks == 1, "down,down,up,up -> one click (got %d)", t4.clicks);
        Tally t5 = {0};
        edge(&g, MTP_SRC_VENDOR, true, &c, &t5);
        edge(&g, MTP_SRC_VENDOR, true, &c, &t5);
        edge(&g, MTP_SRC_STANDARD, true, &c, &t5);
        edge(&g, MTP_SRC_STANDARD, true, &c, &t5);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t5);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t5);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t5);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t5);
        CHECK(t5.clicks == 1, "duplicated edges on both sources -> one click (got %d)", t5.clicks);
        /* An up from the other source while only one is held does not end it. */
        Tally t6 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t6);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t6);
        CHECK(g.active && t6.clicks == 0, "stray vendor up does not end a std gesture");
        edge(&g, MTP_SRC_STANDARD, false, &c, &t6);
        CHECK(t6.clicks == 1, "then std up clicks once");
    }

    group("gesture.F.axes");
    {
        MTPConfig c = cfg_t(0);
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        const uint8_t both[][2] = {{0x01, 0x01}, {0xFF, 0x02}, {0x07, 0xF9}, {0xFE, 0xFE}};
        for (size_t i = 0; i < 4; i++)
            CHECK(!wheel(&g, both[i][0], both[i][1], &c, false, &t),
                  "both axes %02x/%02x rejected", both[i][0], both[i][1]);
        CHECK(g.travel == 0 && !g.scrolling, "rejected reports add no travel (got %u)", g.travel);
        const uint8_t neutral[] = {0x00, 0x08, 0x80, 0xF8};
        for (size_t i = 0; i < 4; i++) {
            CHECK(!wheel(&g, 0, neutral[i], &c, false, &t), "V neutral %02x", neutral[i]);
            CHECK(!wheel(&g, neutral[i], 0, &c, false, &t), "H neutral %02x", neutral[i]);
        }
        CHECK(g.travel == 0 && !g.scrolling, "neutral bytes add no travel (got %u)", g.travel);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t);
        CHECK(t.clicks == 1 && t.emits == 0, "only rejected/neutral reports -> click");
    }

    group("gesture.G.direction");
    {
        MTPConfig c = cfg_t(0);
        const uint8_t raws[] = {0x01, 0x03, 0x07, 0xFF, 0xFD, 0xF9};
        for (size_t i = 0; i < sizeof raws; i++) {
            int u = mtp_wheel_units(raws[i]);
            for (int axis = 0; axis < 2; axis++) {
                int32_t out[2];
                for (int nat = 0; nat < 2; nat++) {
                    MTPGesture g = {0}; Tally t = {0};
                    edge(&g, MTP_SRC_STANDARD, true, &c, &t);
                    wheel(&g, axis ? raws[i] : 0, axis ? 0 : raws[i], &c, nat, &t);
                    out[nat] = axis ? t.lastX : t.lastY;
                    int32_t other = axis ? t.lastY : t.lastX;
                    CHECK(other == 0, "no cross-axis leak");
                }
                CHECK(out[0] == u * 10, "%s raw %02x natural=false -> %d px (got %d)",
                      axis ? "H" : "V", raws[i], u * 10, out[0]);
                CHECK(out[1] == -out[0], "%s raw %02x natural inverts (%d vs %d)",
                      axis ? "H" : "V", raws[i], out[1], out[0]);
            }
        }
        /* horizontal=false: no X, but travel counts -> no click. */
        MTPConfig nh = cfg_t(3); nh.horizontal = false;
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &nh, &t);
        for (int i = 0; i < 6; i++) wheel(&g, 0x02, 0, &nh, false, &t);
        CHECK(t.emits == 0 && t.sumX == 0, "horizontal off: nothing emitted");
        CHECK(g.travel == 12 && g.scrolling, "horizontal off: travel counted (%u)", g.travel);
        CHECK(wheel(&g, 0, UP1, &nh, false, &t) && t.lastY == 10 && t.lastX == 0,
              "horizontal off: vertical still scrolls");
        edge(&g, MTP_SRC_STANDARD, false, &nh, &t);
        CHECK(t.clicks == 0, "no click after a horizontal gesture with horizontal off");
        MTPGesture g2 = {0}; Tally t2 = {0};
        edge(&g2, MTP_SRC_STANDARD, true, &nh, &t2);
        for (int i = 0; i < 3; i++) wheel(&g2, 0xFF, 0, &nh, true, &t2);
        edge(&g2, MTP_SRC_STANDARD, false, &nh, &t2);
        CHECK(t2.clicks == 0 && t2.emits == 0, "horizontal-only gesture, horizontal off: no "
              "click, no scroll");
        CHECK(g2.restX == 0, "no horizontal remainder accumulates when off");
    }

    group("gesture.H.speed");
    {
        /* speed 0.05 (below config range, exercises accumulation): 0.5 px per unit. */
        MTPConfig half = cfg_t(0); half.speed = 0.05;
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &half, &t);
        CHECK(!wheel(&g, 0, UP1, &half, false, &t), "0.5 px: nothing yet");
        CHECK(wheel(&g, 0, UP1, &half, false, &t) && t.lastY == 1, "second report: 1 px");
        /* Remainders reset at a new gesture. */
        wheel(&g, 0, UP1, &half, false, &t);                 /* rest 0.5 */
        edge(&g, MTP_SRC_STANDARD, false, &half, &t);
        edge(&g, MTP_SRC_STANDARD, true, &half, &t);
        CHECK(g.restX == 0 && g.restY == 0, "remainders cleared at press");
        CHECK(!wheel(&g, 0, UP1, &half, false, &t), "carried remainder would have emitted 1 px");
        edge(&g, MTP_SRC_STANDARD, false, &half, &t);
        /* Remainder cleared by cancel too. */
        edge(&g, MTP_SRC_STANDARD, true, &half, &t);
        wheel(&g, UP1, 0, &half, false, &t);
        mtp_gesture_cancel(&g);
        CHECK(g.restX == 0 && g.restY == 0, "remainders cleared by cancel");

        /* Totals over N reports. */
        const double speeds[] = {0.1, 0.13, 0.25, 0.37, 0.5, 1.0, 1.7, 2.5, 3.33, 9.99, 10.0};
        const uint8_t raws[] = {0x01, 0x02, 0x03, 0x07, 0xFF, 0xFD, 0xF9};
        const int N = 97;
        int bad = 0;
        for (size_t si = 0; si < sizeof speeds / sizeof *speeds; si++)
        for (size_t ri = 0; ri < sizeof raws; ri++)
        for (int axis = 0; axis < 2; axis++)
        for (int nat = 0; nat < 2; nat++) {
            MTPConfig c = cfg_t(0); c.speed = speeds[si];
            MTPGesture gg = {0}; Tally tt = {0};
            edge(&gg, MTP_SRC_STANDARD, true, &c, &tt);
            for (int i = 0; i < N; i++)
                wheel(&gg, axis ? raws[ri] : 0, axis ? 0 : raws[ri], &c, nat, &tt);
            int u = mtp_wheel_units(raws[ri]);
            double exact = N * u * speeds[si] * MTP_PIXELS_PER_UNIT * (nat ? -1 : 1);
            long want = (long)trunc(exact);
            long got = axis ? tt.sumX : tt.sumY;
            long other = axis ? tt.sumY : tt.sumX;
            if (labs(got - want) > 1 || other != 0) {
                bad++;
                CHECK(false, "speed %g raw %02x axis %s natural %d: %ld px, expected %ld±1",
                      speeds[si], raws[ri], axis ? "H" : "V", nat, got, want);
            }
            /* Never more than one report's worth plus 1 px per emission. */
            double per = fabs(u * speeds[si] * MTP_PIXELS_PER_UNIT);
            if (tt.emits && (labs(tt.lastX) > per + 1 || labs(tt.lastY) > per + 1)) {
                bad++;
                CHECK(false, "single emission too large at speed %g", speeds[si]);
            }
            edge(&gg, MTP_SRC_STANDARD, false, &c, &tt);
            if (tt.clicks) { bad++; CHECK(false, "click after scrolling at speed %g", speeds[si]); }
        }
        CHECK(bad == 0, "%d speed/accumulation combinations wrong", bad);

        /* Slowest config speed with ±1 alternating: net 0, no drift. */
        MTPConfig slow = cfg_t(0); slow.speed = 0.13;
        MTPGesture g3 = {0}; Tally t3 = {0};
        edge(&g3, MTP_SRC_STANDARD, true, &slow, &t3);
        for (int i = 0; i < 200; i++) wheel(&g3, 0, (i & 1) ? DN1 : UP1, &slow, false, &t3);
        CHECK(labs(t3.sumY) <= 1, "alternating ±1 nets ~0 px (got %ld)", t3.sumY);
        CHECK(fabs(g3.restY) < 1.0, "remainder stays below 1 px (%g)", g3.restY);
        /* Speed 0.1 + repeated -1 eventually emits. */
        MTPConfig s01 = cfg_t(0); s01.speed = 0.1;
        MTPGesture g4 = {0}; Tally t4 = {0};
        edge(&g4, MTP_SRC_STANDARD, true, &s01, &t4);
        for (int i = 0; i < 50; i++) wheel(&g4, 0, DN1, &s01, true, &t4);
        CHECK(t4.emits > 0 && labs(t4.sumY - 50) <= 1, "speed 0.1, 50 x -1 natural -> +50 px "
              "(got %ld)", t4.sumY);
    }

    group("gesture.H.acceleration");
    {
        /* Exact per-report values: units^(1+a) x 10 px x speed, both signs. */
        const struct { double a, speed; int units; double px; } cases[] = {
            {0.0, 1.0, 1, 10}, {0.0, 1.0, 3, 30}, {0.0, 1.0, -3, -30},
            {1.0, 1.0, 1, 10}, {1.0, 1.0, 2, 40}, {1.0, 1.0, 3, 90}, {1.0, 1.0, 4, 160},
            {1.0, 1.0, -1, -10}, {1.0, 1.0, -2, -40}, {1.0, 1.0, -3, -90}, {1.0, 1.0, -7, -490},
            {1.0, 0.5, 3, 45}, {1.0, 2.0, -2, -80},
            {2.0, 1.0, 2, 80}, {2.0, 1.0, 3, 270}, {2.0, 1.0, -3, -270},
            {0.5, 1.0, 4, 80}, {0.5, 1.0, -4, -80},
        };
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            MTPConfig c = cfg_t(0); c.acceleration = cases[i].a; c.speed = cases[i].speed;
            double got = mtp_scroll_pixels(cases[i].units, &c);
            CHECK(fabs(got - cases[i].px) < 1e-9, "a=%g speed=%g units=%d -> %g px (got %g)",
                  cases[i].a, cases[i].speed, cases[i].units, cases[i].px, got);
        }
        /* Symmetry and monotonicity over the whole range of a and units. */
        int bad = 0;
        for (int ai = 0; ai <= 20; ai++) {
            MTPConfig c = cfg_t(0); c.acceleration = ai / 10.0;
            CHECK(mtp_scroll_pixels(0, &c) == 0, "0 units -> 0 px (a=%g)", c.acceleration);
            for (int u = 1; u <= 7; u++) {
                double p = mtp_scroll_pixels(u, &c), n = mtp_scroll_pixels(-u, &c);
                if (p != -n || p <= 0) { bad++; CHECK(false, "a=%g u=%d: %g vs %g", c.acceleration, u, p, n); }
                if (u > 1 && p <= mtp_scroll_pixels(u - 1, &c)) { bad++; CHECK(false, "a=%g u=%d not increasing", c.acceleration, u); }
                if (fabs(mtp_scroll_pixels(1, &c) - 10) > 1e-9) { bad++; CHECK(false, "a=%g: 1 unit must stay 10 px", c.acceleration); }
            }
        }
        CHECK(bad == 0, "%d symmetry/monotonicity failures", bad);
        /* Through the gesture, with the measured ramp FF FE FD vs 01 02 03:
         * same total magnitude both ways, opposite signs. */
        MTPConfig c = mtp_default_config(); c.threshold = 0;
        const uint8_t up[] = {0x01, 0x02, 0x03, 0x03, 0x02, 0x01};
        const uint8_t dn[] = {0xFF, 0xFE, 0xFD, 0xFD, 0xFE, 0xFF};
        for (int axis = 0; axis < 2; axis++) {
            MTPGesture g1 = {0}, g2 = {0}; Tally t1 = {0}, t2 = {0};
            edge(&g1, MTP_SRC_STANDARD, true, &c, &t1);
            edge(&g2, MTP_SRC_STANDARD, true, &c, &t2);
            for (size_t i = 0; i < sizeof up; i++) {
                wheel(&g1, axis ? up[i] : 0, axis ? 0 : up[i], &c, false, &t1);
                wheel(&g2, axis ? dn[i] : 0, axis ? 0 : dn[i], &c, false, &t2);
            }
            long s1 = axis ? t1.sumX : t1.sumY, s2 = axis ? t2.sumX : t2.sumY;
            CHECK(s1 == 280 && s2 == -280, "%s ramp 1,2,3,3,2,1 at a=1: +280 / -280 px (got %ld / %ld)",
                  axis ? "H" : "V", s1, s2);
            CHECK(g1.travel == 12 && g2.travel == 12, "travel counts units, not pixels (%u / %u)",
                  g1.travel, g2.travel);
        }
    }

    group("gesture.I.cancel");
    {
        MTPConfig c = mtp_default_config();
        MTPGesture g = {0}; Tally t = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t);
        wheel(&g, 0, UP1, &c, false, &t);
        g.ignored = 42;
        mtp_gesture_cancel(&g);
        CHECK(!g.active && !g.scrolling && g.travel == 0 && !g.down[0] && !g.down[1],
              "cancel clears the gesture");
        CHECK(g.ignored == 42, "cancel keeps the ignored counter");
        CHECK(edge(&g, MTP_SRC_STANDARD, false, &c, &t) == MTP_NOTHING && t.clicks == 0,
              "release after cancel: no click");
        CHECK(!wheel(&g, 0, UP1, &c, false, &t) && g.ignored == 43,
              "wheel after cancel ignored");

        /* Cancel with both sources held. */
        Tally t2 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t2);
        edge(&g, MTP_SRC_VENDOR, true, &c, &t2);
        mtp_gesture_cancel(&g);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t2);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t2);
        CHECK(t2.clicks == 0 && !g.active, "both sources, cancel: no click on either release");

        /* Cancel while scrolling: following wheel reports do not scroll. */
        MTPConfig c0 = cfg_t(0);
        Tally t3 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c0, &t3);
        wheel(&g, 0, UP1, &c0, false, &t3);
        mtp_gesture_cancel(&g);
        CHECK(!wheel(&g, 0, UP1, &c0, false, &t3) && t3.emits == 1, "no scroll after cancel");
        edge(&g, MTP_SRC_STANDARD, false, &c0, &t3);
        CHECK(t3.clicks == 0, "no click");

        /* Cancel on an idle gesture is harmless; next gesture works. */
        mtp_gesture_cancel(&g);
        Tally t4 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t4);
        edge(&g, MTP_SRC_STANDARD, false, &c, &t4);
        CHECK(t4.clicks == 1, "gesture after cancel clicks normally");

        /* Recorded: cancel between the two sources' edges of one physical press. */
        Tally t5 = {0};
        edge(&g, MTP_SRC_STANDARD, true, &c, &t5);
        mtp_gesture_cancel(&g);
        edge(&g, MTP_SRC_VENDOR, true, &c, &t5);       /* same physical press, later edge */
        edge(&g, MTP_SRC_STANDARD, false, &c, &t5);
        edge(&g, MTP_SRC_VENDOR, false, &c, &t5);
        if (t5.clicks)
            NOTE("cancel landing between the standard and vendor down edges of one physical "
                 "press: the vendor edge starts a new gesture and the release clicks (%d click)",
                 t5.clicks);

        /* Travel saturation. */
        MTPGesture gs = {0}; Tally ts = {0};
        MTPConfig c50 = cfg_t(50);
        edge(&gs, MTP_SRC_STANDARD, true, &c50, &ts);
        gs.travel = UINT32_MAX - 3;
        CHECK(wheel(&gs, 0, 0x07, &c50, false, &ts) && gs.travel == UINT32_MAX,
              "travel saturates at UINT32_MAX (got %u)", gs.travel);
        CHECK(wheel(&gs, 0xF9, 0, &c50, false, &ts) && gs.travel == UINT32_MAX,
              "stays saturated (got %u)", gs.travel);
        gs.travel = UINT32_MAX - 7;
        wheel(&gs, 0, 0x07, &c50, false, &ts);
        CHECK(gs.travel == UINT32_MAX, "exact fit to UINT32_MAX (got %u)", gs.travel);
        edge(&gs, MTP_SRC_STANDARD, false, &c50, &ts);
        CHECK(ts.clicks == 0, "no click after saturated travel");
        /* Many real reports: no overflow, monotonic. */
        MTPGesture gm = {0}; Tally tm = {0};
        edge(&gm, MTP_SRC_STANDARD, true, &c, &tm);
        uint32_t prev = 0;
        bool mono = true;
        for (int i = 0; i < 100000; i++) {
            wheel(&gm, 0, (i & 1) ? 0x07 : 0xF9, &c, false, &tm);
            if (gm.travel < prev) mono = false;
            prev = gm.travel;
        }
        CHECK(mono && gm.travel == 700000u, "travel monotonic and exact (07 and F9 = 7 each) (got %u)", gm.travel);
    }
}

/* ── 7. Event-tap decision ───────────────────────────────────────────────── */
static void test_tap(void) {
    group("tap");
    MTPTapState s = {0};
    /* Synthetic events always pass, whatever the state. */
    for (int k = MTP_EV_OTHER_DOWN; k <= MTP_EV_IGNORED; k++)
        for (int held = 0; held < 2; held++)
            for (int sw = 0; sw < 2; sw++) {
                s.swallowing = sw;
                CHECK(!mtp_tap_should_drop(&s, (MTPEventKind)k, 2, true, false, held),
                      "synthetic kind %d held %d swallowing %d passes", k, held, sw);
                CHECK(s.swallowing == (bool)sw, "synthetic event does not change state");
            }

    /* Middle down while held: dropped, drags dropped, up dropped exactly once. */
    s = (MTPTapState){0};
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, true), "held down dropped");
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, 2, false, false, true), "drag dropped");
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, 2, false, false, false),
          "drag dropped even after the TrackPoint reports release");
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, false), "up dropped");
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, true), "second up passes");
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, 2, false, false, true),
          "drag after the pair passes");

    /* Down while not held passes, its up passes even if held in between. */
    s = (MTPTapState){0};
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, false), "down passes");
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, 2, false, false, true), "drag passes");
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, true),
          "up passes although TrackPoint now held (no stuck button)");

    /* A second down re-decides. */
    s = (MTPTapState){0};
    mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, true);
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, false),
          "second down (not held) passes");
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, true),
          "and its up passes");
    s = (MTPTapState){0};
    mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, false);
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, true),
          "second down (held) dropped");
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, false), "and its up dropped");

    /* Buttons other than 2 untouched: down/up. */
    for (long b = 0; b < 32; b++) {
        if (b == 2) continue;
        for (int sw = 0; sw < 2; sw++) {
            s.swallowing = sw;
            CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, b, false, false, true),
                  "button %ld down passes", b);
            CHECK(s.swallowing == (bool)sw, "button %ld down leaves state", b);
            CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, b, false, false, true),
                  "button %ld up passes", b);
            CHECK(s.swallowing == (bool)sw, "button %ld up leaves state", b);
        }
    }
    /* Middle pair swallowed, another button's up in between does not end it. */
    s = (MTPTapState){0};
    mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, true);
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 3, false, false, true), "button 3 up passes");
    CHECK(mtp_tap_should_drop(&s, MTP_EV_OTHER_UP, 2, false, false, true),
          "middle up still dropped");

    /* Buttons other than 2 untouched: drags. */
    s = (MTPTapState){0};
    mtp_tap_should_drop(&s, MTP_EV_OTHER_DOWN, 2, false, false, true);   /* swallowing */
    for (long b = 3; b <= 4; b++)
        CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, b, false, false, true),
              "OtherMouseDragged for button %ld must pass while a button-2 press is "
              "swallowed", b);
    s = (MTPTapState){0};
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_OTHER_DRAGGED, 3, false, false, true),
          "button 3 drag passes when nothing is swallowed");

    /* Scroll: dropped only when held AND non-continuous. */
    for (int sw = 0; sw < 2; sw++) {
        s.swallowing = sw;
        CHECK(mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, true),
              "wheel scroll while held dropped");
        CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, true, true),
              "continuous (trackpad) scroll while held passes");
        CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, false),
              "wheel scroll not held passes");
        CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, true, false),
              "continuous scroll not held passes");
        CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 2, true, false, true),
              "synthetic scroll passes");
        CHECK(s.swallowing == (bool)sw, "scroll leaves state");
    }

    /* Ignored kinds pass. */
    for (int held = 0; held < 2; held++)
        for (int sw = 0; sw < 2; sw++) {
            s.swallowing = sw;
            CHECK(!mtp_tap_should_drop(&s, MTP_EV_IGNORED, 2, false, false, held),
                  "IGNORED passes (held %d, swallowing %d)", held, sw);
            CHECK(s.swallowing == (bool)sw, "IGNORED leaves state");
        }
}

/* ── Main ────────────────────────────────────────────────────────────────── */
/* Native Bluetooth wheel events are paired with the HID reports that caused
 * them: each owed event is dropped exactly once, even after the release. */
static void test_tap_owed_wheel(void) {
    g_group = "tap.owed";
    MTPTapState s = {0};
    /* Held, two native wheel reports seen: both native events dropped. */
    mtp_tap_native_wheel(&s); mtp_tap_native_wheel(&s);
    CHECK(s.owedWheel == 2, "owed=%u", s.owedWheel);
    CHECK(mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, true), "held, owed 2");
    CHECK(s.owedWheel == 1, "owed=%u", s.owedWheel);
    /* Released before the last native event arrives: still dropped (owed). */
    CHECK(mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, false), "released, owed 1");
    CHECK(s.owedWheel == 0, "owed=%u", s.owedWheel);
    /* Nothing owed, not held: an external mouse wheel passes. */
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, false), "external wheel");
    /* Held with nothing owed (native event ahead of its report): dropped. */
    CHECK(mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, false, true), "held, owed 0");
    CHECK(s.owedWheel == 0, "never negative: %u", s.owedWheel);
    /* Trackpad (continuous) never consumes nor is dropped. */
    mtp_tap_native_wheel(&s);
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, false, true, true), "trackpad");
    CHECK(s.owedWheel == 1, "trackpad consumed owed: %u", s.owedWheel);
    /* Synthetic events neither. */
    CHECK(!mtp_tap_should_drop(&s, MTP_EV_SCROLL, 0, true, false, true), "synthetic");
    CHECK(s.owedWheel == 1, "synthetic consumed owed: %u", s.owedWheel);
    /* Saturation. */
    for (int i = 0; i < 1000; i++) mtp_tap_native_wheel(&s);
    CHECK(s.owedWheel == MTP_MAX_OWED_WHEEL, "cap: %u", s.owedWheel);
    /* Button pairing is independent of the wheel counter. */
    MTPTapState b = {0};
    mtp_tap_native_wheel(&b);
    CHECK(!mtp_tap_should_drop(&b, MTP_EV_OTHER_DOWN, 2, false, false, false), "down passes");
    CHECK(!mtp_tap_should_drop(&b, MTP_EV_OTHER_UP, 2, false, false, false), "up passes");
    CHECK(b.owedWheel == 1, "buttons consumed owed: %u", b.owedWheel);
}

/* Fixes from the 2026-11-22 audits (docs/audits/2026-11-22-synthese.md). */
static void test_audit_fixes(void) {
    g_group = "audit.fail_closed";
    {
        NSMutableArray *errors = [NSMutableArray array];
        MTPConfig c = mtp_config_from_plist(@{@"scroll": @{@"enabled": @"no"}}, errors);
        CHECK(!c.scrollEnabled && errors.count == 1, "invalid enabled -> off (%s)", joined(errors));
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"scroll": @{@"enabled": @YES, @"speed": @"x"}}, errors);
        CHECK(c.scrollEnabled && errors.count == 1, "valid enabled kept despite another error");
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"scroll": @{@"enabled": @NO}, @"bogus": @1}, errors);
        CHECK(!c.scrollEnabled && errors.count == 1, "explicit off kept");
        errors = [NSMutableArray array];
        c = mtp_config_from_plist(@{@"trackpoint": @{@"sensitivity": @99}}, errors);
        CHECK(c.scrollEnabled, "an unrelated error does not switch scrolling off");
        bool exists = true;
        errors = [NSMutableArray array];
        c = mtp_config_load(tmp_path(@"does-not-exist.plist"), errors, &exists);
        CHECK(!exists && errors.count == 0 && c.scrollEnabled, "missing file: defaults, on");
        MTPConfig f = mtp_failed_config(), d = mtp_default_config();
        f.scrollEnabled = d.scrollEnabled;
        CHECK(cfg_equal(f, d), "failed config differs from defaults only by scrolling");
    }

    g_group = "audit.ble_pointer";
    {
        MTPBlePointer ptr;
        uint8_t r[5] = {0x02, 0x04, 0x00, 0x00, 0x00};
        CHECK(mtp_decode_ble_pointer(0x02, r, 5, &ptr) && ptr.middle && !ptr.motion && !ptr.wheel,
              "middle only");
        uint8_t m[5] = {0x02, 0x00, 0xFF, 0x00, 0x00};
        CHECK(mtp_decode_ble_pointer(0x02, m, 5, &ptr) && !ptr.middle && ptr.motion, "x motion");
        uint8_t y[5] = {0x02, 0x03, 0x00, 0x01, 0x00};
        CHECK(mtp_decode_ble_pointer(0x02, y, 5, &ptr) && !ptr.middle && ptr.motion,
              "y motion, buttons 1+2 are not the middle");
        uint8_t w[5] = {0x02, 0x00, 0x00, 0x00, 0xFF};
        CHECK(mtp_decode_ble_pointer(0x02, w, 5, &ptr) && ptr.wheel && !ptr.motion, "wheel");
        CHECK(!mtp_decode_ble_pointer(0x01, r, 5, &ptr), "other report id");
        CHECK(!mtp_decode_ble_pointer(0x02, r, 4, &ptr), "short");
        CHECK(!mtp_decode_ble_pointer(0x02, r, 6, &ptr), "long");
        uint8_t bad[5] = {0x16, 0x04, 0, 0, 0};
        CHECK(!mtp_decode_ble_pointer(0x02, bad, 5, &ptr), "first byte not the id");
        CHECK(!mtp_decode_ble_pointer(0x02, NULL, 5, &ptr), "null report");
    }

    g_group = "audit.lost_release";
    {
        MTPConfig cfg = mtp_default_config();
        MTPGesture g = {0};
        MTPBlePointer moveUp = { .middle = false, .motion = true };
        MTPBlePointer moveDown = { .middle = true, .motion = true };
        MTPBlePointer stillUp = { .middle = false, .motion = false };
        CHECK(!mtp_gesture_motion_proves_release(&g, &moveUp), "no gesture: nothing to end");
        /* Gesture held by the vendor source (as measured), release lost. */
        mtp_gesture_middle(&g, MTP_SRC_VENDOR, true, &cfg);
        CHECK(g.active, "vendor press starts");
        CHECK(!mtp_gesture_motion_proves_release(&g, &stillUp), "no motion: no proof");
        CHECK(!mtp_gesture_motion_proves_release(&g, &moveDown), "button 3 still down");
        CHECK(g.active, "still held");
        CHECK(mtp_gesture_motion_proves_release(&g, &moveUp), "motion with button up ends it");
        CHECK(!g.active && !g.down[MTP_SRC_VENDOR] && !g.down[MTP_SRC_STANDARD], "all clear");
        /* The late (or duplicate) vendor release is then harmless: no click. */
        CHECK(mtp_gesture_middle(&g, MTP_SRC_VENDOR, false, &cfg) == MTP_NOTHING,
              "late release does not click");
        /* A new press after that works normally and clicks. */
        mtp_gesture_middle(&g, MTP_SRC_VENDOR, true, &cfg);
        CHECK(g.active, "next press starts");
        CHECK(mtp_gesture_middle(&g, MTP_SRC_VENDOR, false, &cfg) == MTP_CLICK, "next click");
        /* Scrolled gesture ended by proof: no click either. */
        mtp_gesture_middle(&g, MTP_SRC_VENDOR, true, &cfg);
        int32_t px, py;
        for (int i = 0; i < 10; i++) mtp_gesture_wheel(&g, 0, 0x02, &cfg, true, &px, &py);
        CHECK(g.scrolling, "scrolling");
        CHECK(mtp_gesture_motion_proves_release(&g, &moveUp) && !g.active, "ended");
        CHECK(MTP_OWED_GRACE_MS > 0 && MTP_OWED_GRACE_MS < 1000, "grace %d ms",
              MTP_OWED_GRACE_MS);
    }
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        NSString *tmpl = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mtp-core.XXXXXX"];
        char buf[PATH_MAX];
        strlcpy(buf, tmpl.fileSystemRepresentation, sizeof buf);
        if (!mkdtemp(buf)) { perror("mkdtemp"); return 3; }
        tmp_dir = @(buf);

        test_config_from_plist();
        test_config_load();
        test_reports();
        test_decoding();
        test_wheel_units();
        test_gesture();
        test_tap();
        test_tap_owed_wheel();
        test_audit_fixes();

        [NSFileManager.defaultManager removeItemAtPath:tmp_dir error:nil];
        if ([NSFileManager.defaultManager fileExistsAtPath:tmp_dir]) {
            fprintf(stderr, "FAIL cleanup: %s left behind\n", buf);
            g_fails++;
        }
        printf("core_test: %d checks, %d failed, %d note(s)\n", g_checks, g_fails, g_notes);
        return g_fails ? 1 : 0;
    }
}
