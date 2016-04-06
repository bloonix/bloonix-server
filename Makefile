CONFIG=Makefile.config

include $(CONFIG)

default: build

build:

	for file in \
		bin/bloonix-check-for-maintenance \
		bin/bloonix-count-es-service-documents \
		bin/bloonix-create-test-hosts \
		bin/bloonix-delete-es-host-data \
		bin/bloonix-get-sms-count \
		bin/bloonix-roll-forward-log \
		bin/bloonix-server \
		bin/bloonix-update-agent-host-config \
		bin/bloonix-srvchk \
		etc/init/bloonix-server \
		etc/init/bloonix-srvchk \
		etc/init/bloonix-server.service \
		etc/init/bloonix-srvchk.service \
	; do \
		cp $$file.in $$file; \
		sed -i "s!@@PERL@@!$(PERL)!g" $$file; \
		sed -i "s!@@PREFIX@@!$(PREFIX)!g" $$file; \
		sed -i "s!@@CACHEDIR@@!$(CACHEDIR)!g" $$file; \
		sed -i "s!@@CONFDIR@@!$(CONFDIR)!g" $$file; \
		sed -i "s!@@RUNDIR@@!$(RUNDIR)!g" $$file; \
		sed -i "s!@@USRLIBDIR@@!$(USRLIBDIR)!" $$file; \
		sed -i "s!@@SRVDIR@@!$(SRVDIR)!g" $$file; \
		sed -i "s!@@LIBDIR@@!$(LIBDIR)!g" $$file; \
		sed -i "s!@@LOGDIR@@!$(LOGDIR)!g" $$file; \
	done;

	if test "$(BUILDPKG)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build.PL installdirs=$(PERL_INSTALLDIRS); \
		$(PERL) Build; \
	fi;

test:

	if test "$(BUILDPKG)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build test; \
	fi;

install:

	for d in $(LOGDIR) $(RUNDIR) ; do \
		./install-sh -d -m 0750 $$d/bloonix; \
	done;

	./install-sh -d -m 0755 $(PREFIX)/bin;
	./install-sh -d -m 0755 -o root -g root $(CONFDIR)/bloonix;
	./install-sh -d -m 0755 -o root -g root $(CONFDIR)/bloonix/server;

	for file in \
		bloonix-server \
		bloonix-srvchk \
		bloonix-check-for-maintenance \
		bloonix-count-es-service-documents \
		bloonix-create-test-hosts \
		bloonix-delete-es-host-data \
		bloonix-get-sms-count \
		bloonix-roll-forward-log  \
		bloonix-update-agent-host-config \
		bloonix-init-server \
	; do \
		./install-sh -c -m 0755 bin/$$file $(PREFIX)/bin/$$file; \
	done;

	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/server;
	./install-sh -c -m 0644 etc/bloonix/server/main.conf $(USRLIBDIR)/bloonix/etc/server/main.conf;

	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/srvchk;
	./install-sh -c -m 0644 etc/bloonix/srvchk/main.conf $(USRLIBDIR)/bloonix/etc/srvchk/main.conf;

	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/database;
	./install-sh -c -m 0644 etc/bloonix/database/main.conf $(USRLIBDIR)/bloonix/etc/database/server-main.conf;

	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/init.d;
	./install-sh -c -m 0755 etc/init/bloonix-server $(USRLIBDIR)/bloonix/etc/init.d/bloonix-server;
	./install-sh -c -m 0755 etc/init/bloonix-srvchk $(USRLIBDIR)/bloonix/etc/init.d/bloonix-srvchk;

	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/systemd;
	./install-sh -c -m 0755 etc/init/bloonix-server.service $(USRLIBDIR)/bloonix/etc/systemd/bloonix-server.service;
	./install-sh -c -m 0755 etc/init/bloonix-srvchk.service $(USRLIBDIR)/bloonix/etc/systemd/bloonix-srvchk.service;

	if test "$(BUILDPKG)" = "0" ; then \
		if test -e /bin/systemctl || test -e /usr/bin/systemctl ; then \
			./install-sh -d -m 0755 $(DESTDIR)/usr/lib/systemd/system/; \
			./install-sh -c -m 0644 etc/init/bloonix-server.service $(DESTDIR)/usr/lib/systemd/system/; \
			./install-sh -c -m 0644 etc/init/bloonix-srvchk.service $(DESTDIR)/usr/lib/systemd/system/; \
			systemctl daemon-reload; \
		elif test -d /etc/init.d ; then \
			./install-sh -c -m 0755 etc/init/bloonix-server $(INITDIR)/bloonix-server; \
			./install-sh -c -m 0755 etc/init/bloonix-srvchk $(INITDIR)/bloonix-srvchk; \
		fi; \
		set -e; cd perl; $(PERL) Build install; $(PERL) Build realclean; \
	fi;

clean:

	if test "$(BUILDPKG)" = "0" ; then \
		cd perl; \
		if test -e "Makefile" ; then \
			$(PERL) Build clean; \
		fi; \
	fi;

