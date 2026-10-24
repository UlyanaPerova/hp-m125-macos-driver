# m125-pclms - open PCLm-S driver for HP LaserJet Pro MFP M125r and relatives
# SPDX-License-Identifier: MIT

CC      ?= cc
CFLAGS  ?= -O2
CFLAGS  += -std=c99 -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE -Wall -Wextra -Wno-deprecated-declarations
LIBS    = -lcups -lpthread
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
# Apple Silicon first; add x86_64 for a universal binary (Intel Macs).
ARCHS   ?= -arch arm64 -arch x86_64
CFLAGS  += $(ARCHS) -mmacosx-version-min=11.0
LIBS    = -lcups
PREFIX_FILTER ?= /Library/Printers/m125-pclms/Filters
PREFIX_PPD    ?= /Library/Printers/PPDs/Contents/Resources
else
PREFIX_FILTER ?= $(shell pkg-config --variable=cups_serverbin cups 2>/dev/null || echo /usr/lib/cups)/filter
PREFIX_PPD    ?= /usr/share/ppd/m125-pclms
endif

all: rastertopclms ppd/m125-pclms.installed.ppd

rastertopclms: src/rastertopclms.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

ppd/m125-pclms.installed.ppd: ppd/m125-pclms.ppd
	@if [ "$(UNAME_S)" = "Darwin" ]; then f="$(PREFIX_FILTER)/rastertopclms"; else f=rastertopclms; fi; \
	  sed "s#@FILTER@#$$f#" $< > $@

install: rastertopclms ppd/m125-pclms.installed.ppd
	install -d -m 755 $(DESTDIR)$(PREFIX_FILTER) $(DESTDIR)$(PREFIX_PPD)
	install -m 755 rastertopclms $(DESTDIR)$(PREFIX_FILTER)/rastertopclms
	gzip -9nc ppd/m125-pclms.installed.ppd > "$(DESTDIR)$(PREFIX_PPD)/HP LaserJet Pro MFP M125r PCLmS.gz"
	chmod 644 "$(DESTDIR)$(PREFIX_PPD)/HP LaserJet Pro MFP M125r PCLmS.gz"

uninstall:
	rm -f $(DESTDIR)$(PREFIX_FILTER)/rastertopclms "$(DESTDIR)$(PREFIX_PPD)/HP LaserJet Pro MFP M125r PCLmS.gz"

clean:
	rm -f rastertopclms ppd/m125-pclms.installed.ppd

.PHONY: all install uninstall clean
