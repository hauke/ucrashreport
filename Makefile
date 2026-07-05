# SPDX-License-Identifier: GPL-2.0-only

DESTDIR ?=

MODULES := meta.uc spool.uc kmsg.uc pstore.uc keys.uc upload.uc

INSTALL := install -m0644
INSTALL_BIN := install -m0755
INSTALL_DIR := install -d -m0755

all:
	@echo "Nothing to build; run 'make install' or 'make check'."

install:
	$(INSTALL_DIR) $(DESTDIR)/usr/share/ucode/ucrashreport
	$(INSTALL) $(MODULES) $(DESTDIR)/usr/share/ucode/ucrashreport/
	$(INSTALL_DIR) $(DESTDIR)/usr/sbin
	$(INSTALL_BIN) ucrashreportd.uc $(DESTDIR)/usr/sbin/ucrashreportd
	$(INSTALL_BIN) ucrashreport.uc $(DESTDIR)/usr/sbin/ucrashreport
	$(INSTALL_DIR) $(DESTDIR)/etc/init.d
	$(INSTALL_BIN) initd/ucrashreport $(DESTDIR)/etc/init.d/ucrashreport
	$(INSTALL_DIR) $(DESTDIR)/etc/config
	$(INSTALL) config/ucrashreport $(DESTDIR)/etc/config/ucrashreport

check:
	./tests/run.sh

.PHONY: all install check
