# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste

# MagicTrackpoint: build, sign, test, install, package.
# Requirements: macOS 12+ and the Xcode Command Line Tools. Nothing else.
# Run "make help" for the list of targets.
#
# Reproducible: fixed flags (CC/CFLAGS are not taken from the environment),
# no date/time macros injected, no debug info, ZERO_AR_DATE for the linker,
# signatures made with --timestamp=none.

LABEL         := com.jcbaptiste.magictrackpoint
VERSION       := $(shell cat VERSION 2>/dev/null)
SIGN_IDENTITY ?= -

CC         := clang
CFLAGS     := -O2 -fobjc-arc -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 -Wall -Wextra
FRAMEWORKS := -framework Foundation -framework IOKit -framework ApplicationServices

SRC   := src/magictrackpointd.m
HDRS  := src/mtp_core.h
PLIST := src/Info.plist
BIN   := build/magictrackpointd

ifeq ($(strip $(VERSION)),)
$(error VERSION file is missing or empty)
endif

.PHONY: all help sign test install uninstall dmg release clean
.DELETE_ON_ERROR:

all: $(BIN)

help:
	@echo "MagicTrackpoint $(VERSION)"
	@echo ""
	@echo "Install on this Mac:"
	@echo "  make install     build, test, sign with your best certificate, install, start"
	@echo "  make uninstall   stop and remove it (keeps ~/.config/magictrackpoint)"
	@echo ""
	@echo "Develop:"
	@echo "  make             universal build -> build/magictrackpointd"
	@echo "  make test        unit, build and packaging tests"
	@echo "  make sign        sign build/ (SIGN_IDENTITY=<SHA-1|name>, default ad hoc)"
	@echo "  make clean       remove build/ and dist/"
	@echo ""
	@echo "Release (needs a Developer ID Application certificate):"
	@echo "  make dmg         dist/MagicTrackpoint-$(VERSION).dmg, signed, not notarized"
	@echo "  make release     same, then notarized by Apple and stapled"
	@echo "                   (NOTARY_PROFILE=<notarytool profile>, default magictrackpoint)"

$(BIN): $(SRC) $(HDRS) $(PLIST) VERSION Makefile
	@mkdir -p build
	ZERO_AR_DATE=1 $(CC) $(CFLAGS) -DMTP_VERSION="\"$(VERSION)\"" \
		-sectcreate __TEXT __info_plist $(PLIST) \
		-o $@ $(SRC) $(FRAMEWORKS)
	@archs=" $$(lipo -archs $@) "; for a in arm64 x86_64; do \
		case "$$archs" in *" $$a "*) ;; \
		*) echo "error: $@ lacks $$a (archs:$$archs)" >&2; exit 1 ;; esac; \
	done

sign: $(BIN)
	codesign --force --options runtime --identifier $(LABEL) --timestamp=none \
		--sign "$(SIGN_IDENTITY)" $(BIN)
	codesign --verify --strict --verbose=2 $(BIN)

test:
	bash tests/run.sh

install:
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

dmg:
	bash scripts/make-dmg.sh

NOTARY_PROFILE ?= magictrackpoint
release:
	MTP_NOTARY_PROFILE="$(NOTARY_PROFILE)" bash scripts/make-dmg.sh --notarize

clean:
	rm -rf build dist
