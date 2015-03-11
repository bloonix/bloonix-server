Summary: Bloonix server daemon
Name: bloonix-server
Version: 0.23
Release: 1%{dist}
License: Commercial
Group: Utilities/System
Distribution: RHEL and CentOS

Packager: Jonny Schulz <js@bloonix.de>
Vendor: Bloonix

BuildArch: noarch
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

Source0: http://download.bloonix.de/sources/%{name}-%{version}.tar.gz
Requires: bloonix-agent
Requires: bloonix-core
Requires: bloonix-dbi
Requires: bloonix-fcgi
Requires: perl-JSON-XS
Requires: perl(DBI)
Requires: perl(DBD::Pg)
Requires: perl(Getopt::Long)
Requires: perl(JSON)
Requires: perl(Log::Handler)
Requires: perl(Math::BigFloat)
Requires: perl(Math::BigInt)
Requires: perl(MIME::Lite)
Requires: perl(Net::OpenSSH)
Requires: perl(Params::Validate)
Requires: perl(Sys::Hostname)
Requires: perl(Time::HiRes)
Requires: perl(Time::ParseDate)
Requires: perl(URI::Escape)
AutoReqProv: no

%description
bloonix-server provides the bloonix server.

%define with_systemd 0
%define initdir %{_sysconfdir}/init.d
%define mandir8 %{_mandir}/man8
%define docdir %{_docdir}/%{name}-%{version}
%define blxdir /usr/lib/bloonix
%define confdir /usr/lib/bloonix/etc/bloonix
%define logdir /var/log/bloonix
%define rundir /var/run/bloonix
%define pod2man /usr/bin/pod2man

%prep
%setup -q -n %{name}-%{version}

%build
%{__perl} Configure.PL --prefix /usr --without-perl --build-package
%{__make}
cd perl;
%{__perl} Build.PL installdirs=vendor
%{__perl} Build

%install
rm -rf %{buildroot}
%{__make} install DESTDIR=%{buildroot}
mkdir -p ${RPM_BUILD_ROOT}%{docdir}
install -d -m 0750 ${RPM_BUILD_ROOT}%{logdir}
install -d -m 0750 ${RPM_BUILD_ROOT}%{rundir}
install -c -m 0444 LICENSE ${RPM_BUILD_ROOT}%{docdir}/
install -c -m 0444 ChangeLog ${RPM_BUILD_ROOT}%{docdir}/

%if %{?with_systemd}
install -p -D -m 0644 %{buildroot}%{blxdir}/etc/systemd/bloonix-server.service %{buildroot}%{_unitdir}/bloonix-server.service
install -p -D -m 0644 %{buildroot}%{blxdir}/etc/systemd/bloonix-srvchk.service %{buildroot}%{_unitdir}/bloonix-srvchk.service
%else
install -p -D -m 0755 %{buildroot}%{blxdir}/etc/init.d/bloonix-server %{buildroot}%{initdir}/bloonix-server
install -p -D -m 0755 %{buildroot}%{blxdir}/etc/init.d/bloonix-srvchk %{buildroot}%{initdir}/bloonix-srvchk
%endif

cd perl;
%{__perl} Build install destdir=%{buildroot} create_packlist=0
find %{buildroot} -name .packlist -exec %{__rm} {} \;

%pre
getent group bloonix >/dev/null || /usr/sbin/groupadd bloonix
getent passwd bloonix >/dev/null || /usr/sbin/useradd \
    bloonix -g bloonix -s /sbin/nologin -d /var/run/bloonix -r

%post
%if %{?with_systemd}
systemctl preset bloonix-server.service
systemctl preset bloonix-srvchk.service
systemctl condrestart bloonix-srvchk.service
systemctl condrestart bloonix-server.service
%else
/sbin/chkconfig --add bloonix-server
/sbin/chkconfig --add bloonix-srvchk
/sbin/service bloonix-srvchk condrestart &>/dev/null
/sbin/service bloonix-server condrestart &>/dev/null
%endif

if [ ! -e "/etc/bloonix/server/main.conf" ] ; then
    mkdir -p /etc/bloonix/server
    chown root:root /etc/bloonix /etc/bloonix/server
    chmod 755 /etc/bloonix /etc/bloonix/server
    cp -a /usr/lib/bloonix/etc/server/main.conf /etc/bloonix/server/main.conf
    chown root:bloonix /etc/bloonix/server/main.conf
    chmod 640 /etc/bloonix/server/main.conf
fi

if [ ! -e "/etc/bloonix/srvchk/main.conf" ] ; then
    mkdir -p /etc/bloonix/srvchk
    chown root:root /etc/bloonix /etc/bloonix/srvchk
    chmod 755 /etc/bloonix /etc/bloonix/srvchk
    cp -a /usr/lib/bloonix/etc/srvchk/main.conf /etc/bloonix/srvchk/main.conf
    chown root:bloonix /etc/bloonix/srvchk/main.conf
    chmod 640 /etc/bloonix/srvchk/main.conf
fi

if [ ! -e "/etc/bloonix/database/main.conf" ] ; then
    mkdir -p /etc/bloonix/database
    chown root:root /etc/bloonix /etc/bloonix/database
    chmod 755 /etc/bloonix /etc/bloonix/database
    cp -a /usr/lib/bloonix/etc/database/server-main.conf /etc/bloonix/database/main.conf
    chown root:bloonix /etc/bloonix/database/main.conf
    chmod 640 /etc/bloonix/database/main.conf
fi

if [ -e "/etc/nginx/conf.d" ] && [ ! -e "/etc/nginx/conf.d/bloonix-server.conf" ] ; then
    install -c -m 0644 /usr/lib/bloonix/etc/server/nginx.conf /etc/nginx/conf.d/bloonix-server.conf
fi

%preun
if [ $1 -eq 0 ]; then
%if %{?with_systemd}
systemctl --no-reload disable bloonix-srvchk.service
systemctl stop bloonix-srvchk.service
systemctl --no-reload disable bloonix-server.service
systemctl stop bloonix-server.service
systemctl daemon-reload
%else
/sbin/service bloonix-srvchk stop &>/dev/null || :
/sbin/service bloonix-server stop &>/dev/null || :
/sbin/chkconfig --del bloonix-srvchk
/sbin/chkconfig --del bloonix-server
%endif
fi

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)

%dir %attr(0755, root, root) %{blxdir}
%dir %attr(0755, root, root) %{blxdir}/etc
%dir %attr(0755, root, root) %{blxdir}/etc/server
%{blxdir}/etc/server/main.conf
%{blxdir}/etc/server/nginx.conf
%dir %attr(0755, root, root) %{blxdir}/etc/srvchk
%{blxdir}/etc/srvchk/main.conf
%dir %attr(0755, root, root) %{blxdir}/etc/database
%{blxdir}/etc/database/server-main.conf
%dir %attr(0755, root, root) %{blxdir}/etc/systemd
%{blxdir}/etc/systemd/bloonix-server.service
%{blxdir}/etc/systemd/bloonix-srvchk.service
%dir %attr(0755, root, root) %{blxdir}/etc/init.d
%{blxdir}/etc/init.d/bloonix-server
%{blxdir}/etc/init.d/bloonix-srvchk
%dir %attr(0750, bloonix, bloonix) %{logdir}
%dir %attr(0750, bloonix, bloonix) %{rundir}

%{_bindir}/bloonix-server
%{_bindir}/bloonix-srvchk
%{_bindir}/bloonix-check-for-maintenance
%{_bindir}/bloonix-count-es-service-documents
%{_bindir}/bloonix-delete-es-host-data
%{_bindir}/bloonix-get-sms-count
%{_bindir}/bloonix-roll-forward-log
%{_bindir}/bloonix-update-agent-host-config

%if %{?with_systemd} == 1
%{_unitdir}/bloonix-server.service
%{_unitdir}/bloonix-srvchk.service
%else
%{initdir}/bloonix-server
%{initdir}/bloonix-srvchk
%endif

%dir %attr(0755, root, root) %{docdir}
%doc %attr(0444, root, root) %{docdir}/ChangeLog
%doc %attr(0444, root, root) %{docdir}/LICENSE

%{_mandir}/man3/*
%dir %{perl_vendorlib}/Bloonix
%dir %{perl_vendorlib}/Bloonix/Server
%{perl_vendorlib}/Bloonix/*.pm
%{perl_vendorlib}/Bloonix/Server/*.pm

%changelog
* Wed Mar 11 2015 Jonny Schulz <js@bloonix.de> - 0.23-1
- Fixed missing function call for Bloonix::SwitchUser in
  bloonix-roll-forward-log.
* Tue Mar 10 2015 Jonny Schulz <js@bloonix.de> - 0.22-1
- "INACIVE" typo fixed.
* Tue Mar 10 2015 Jonny Schulz <js@bloonix.de> - 0.21-1
- Service and host actions (active, notification, acknowlegded)
  will now all reported.
* Mon Mar 09 2015 Jonny Schulz <js@bloonix.de> - 0.20-1
- Nagios stats can now be parsed and stored.
- ServiceChecker now except __DIE__.
- Level of message 'no postdata received' changed to warning.
- Path /srv/bloonix/server removed.
- bloonix-roll-forward-log can now be executed as user bloonix
  and user root.
- Force the status INFO for all services which are not OK
  if maintenance mode is active.
* Mon Feb 16 2015 Jonny Schulz <js@bloonix.de> - 0.19-1
- Kicked sth_cache_enabled from database config.
* Mon Feb 16 2015 Jonny Schulz <js@bloonix.de> - 0.18-1
- Add parameter sth_cache_enabled to the database config.
* Sat Feb 14 2015 Jonny Schulz <js@bloonix.de> - 0.17-1
- Removed typecasting in bloonix-roll-forward-log.
- Transfer the database configuration to /etc/bloonix/database/main.conf.
* Thu Jan 29 2015 Jonny Schulz <js@bloonix.de> - 0.16-1
- Fixed redirect section and kicked sms_to.
* Thu Jan 29 2015 Jonny Schulz <js@bloonix.de> - 0.15-2
- Fixed %preun.
* Mon Jan 26 2015 Jonny Schulz <js@bloonix.de> - 0.15-1
- Fixed permissions of hosts.conf that is generated
  by bloonix-update-agent-host-config.
* Tue Jan 13 2015 Jonny Schulz <js@bloonix.de> - 0.14-1
- Kicked dependency postfix.
* Fri Jan 02 2015 Jonny Schulz <js@bloonix.de> - 0.13-1
- Fixed volatile handling if max attempt is higher than 1.
* Tue Dec 23 2014 Jonny Schulz <js@bloonix.de> - 0.12-1
- Fixed status switches from warning to critical if attempt max
  is reached.
* Sun Dec 14 2014 Jonny Schulz <js@bloonix.de> - 0.11-1
- Improved the script to count elasticsearch documents for each
  service.
- Improved script bloonix-delete-es-host-data.
- Fixed message formatting for redirected messages.
- Improved the interval handling for services in status
  WARNING, CRITICAL, UNKNOWN and INFO.
* Fri Dec 05 2014 Jonny Schulz <js@bloonix.de> - 0.10-1
- Plugin results are now stored each time and not only
  by status switches.
* Tue Dec 02 2014 Jonny Schulz <js@bloonix.de> - 0.9-1
- Changed the boot facility.
- Allow multiple locations within the host id.
* Mon Nov 17 2014 Jonny Schulz <js@bloonix.de> - 0.8-1
- bloonix-update-agent-host-config adds now the agent id
  as postfix to each host id.
* Sun Nov 16 2014 Jonny Schulz <js@bloonix.de> - 0.7-1
- Added the prefix RAD (remote agent dead) to the mail subject
  for mails that are redirected to an admin if a remote
  agent seems to be dead.
- Fix permissions of /etc/bloonix*.
* Sat Nov 08 2014 Jonny Schulz <js@bloonix.de> - 0.6-1
- Fixed that volatile states will be hold until an administrator
  marks the status as viewed.
* Thu Nov 06 2014 Jonny Schulz <js@bloonix.de> - 0.5-1
- Moved bloonix-plugin-loader and Plugin/Loader.pm
  to package bloonix-plugin-config.
* Tue Nov 04 2014 Jonny Schulz <js@bloonix.de> - 0.4-1
- Fixed: rename the host id from id to host_id.
* Mon Nov 03 2014 Jonny Schulz <js@bloonix.de> - 0.3-1
- Feature force_check for services implemented.
- Skipping inactive companies in script
  bloonix-update-agent-host-config.
- Updated the license information.
* Fri Oct 24 2014 Jonny Schulz <js@bloonix.de> - 0.2-1
- Disable die_on_errors by default so that the logger
  does not die on errors.
* Mon Aug 25 2014 Jonny Schulz <js@bloonix.de> - 0.1-1
- Initial release.
