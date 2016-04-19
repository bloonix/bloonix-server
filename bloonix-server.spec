Summary: Bloonix server daemon
Name: bloonix-server
Version: 0.57
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
Requires: bloonix-core >= 0.28
Requires: bloonix-dbi >= 0.13
Requires: openssl
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
install -d -m 0755 ${RPM_BUILD_ROOT}%{rundir}
install -c -m 0444 LICENSE ${RPM_BUILD_ROOT}%{docdir}/
install -c -m 0444 ChangeLog ${RPM_BUILD_ROOT}%{docdir}/

%if 0%{?with_systemd}
install -p -D -m 0644 %{buildroot}%{blxdir}/etc/systemd/bloonix-server.service %{buildroot}%{_unitdir}/bloonix-server.service
install -p -D -m 0644 %{buildroot}%{blxdir}/etc/systemd/bloonix-srvchk.service %{buildroot}%{_unitdir}/bloonix-srvchk.service
%else
install -p -D -m 0755 %{buildroot}%{blxdir}/etc/init.d/bloonix-server %{buildroot}%{initdir}/bloonix-server
install -p -D -m 0755 %{buildroot}%{blxdir}/etc/init.d/bloonix-srvchk %{buildroot}%{initdir}/bloonix-srvchk
%endif

cd perl;
%{__perl} Build install destdir=%{buildroot} create_packlist=0
find %{buildroot} -name .packlist -exec %{__rm} {} \;

%post
/usr/bin/bloonix-init-server
%if 0%{?with_systemd}
%systemd_post bloonix-server.service
%systemd_post bloonix-srvchk.service
systemctl condrestart bloonix-srvchk.service
systemctl condrestart bloonix-server.service
%else
/sbin/chkconfig --add bloonix-server
/sbin/chkconfig --add bloonix-srvchk
/sbin/service bloonix-srvchk condrestart &>/dev/null
/sbin/service bloonix-server condrestart &>/dev/null
%endif

%preun
%if 0%{?with_systemd}
%systemd_preun bloonix-srvchk.service
%systemd_preun bloonix-server.service
%else
if [ $1 -eq 0 ]; then
    /sbin/service bloonix-srvchk stop &>/dev/null || :
    /sbin/service bloonix-server stop &>/dev/null || :
    /sbin/chkconfig --del bloonix-srvchk
    /sbin/chkconfig --del bloonix-server
fi
%endif

%postun
%if 0%{?with_systemd}
%systemd_postun
%endif

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)

%dir %attr(0755, root, root) %{blxdir}
%dir %attr(0755, root, root) %{blxdir}/etc
%dir %attr(0755, root, root) %{blxdir}/etc/server
%{blxdir}/etc/server/main.conf
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
%dir %attr(0750, bloonix, root) %{logdir}
%dir %attr(0755, bloonix, root) %{rundir}

%{_bindir}/bloonix-server
%{_bindir}/bloonix-srvchk
%{_bindir}/bloonix-check-for-maintenance
%{_bindir}/bloonix-count-es-service-documents
%{_bindir}/bloonix-delete-es-host-data
%{_bindir}/bloonix-get-sms-count
%{_bindir}/bloonix-init-server
%{_bindir}/bloonix-roll-forward-log
%{_bindir}/bloonix-update-agent-host-config

%if 0%{?with_systemd}
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
* Tue Apr 19 2016 Jonny Schulz <js@bloonix.de> - 0.57-1
- Fixed redirect mail notifications.
* Mon Apr 18 2016 Jonny Schulz <js@bloonix.de> - 0.56-1
- Fixed next_timeout setting.
* Sun Apr 17 2016 Jonny Schulz <js@bloonix.de> - 0.55-1
- Fixed some issues with scheduled services and srvchk.
* Fri Apr 08 2016 Jonny Schulz <js@bloonix.de> - 0.54-1
- Fixed last_check setting for checks that have a scheduled
  downtime.
- Now only services are pushed to the agents if the host or
  service has no scheduled downtime configured.
* Wed Apr 06 2016 Jonny Schulz <js@bloonix.de> - 0.53-1
- Implement global var %RND(num)% for command options.
* Mon Apr 04 2016 Jonny Schulz <js@bloonix.de> - 0.52-1
- Check /bin/systemctl instead of /usr/lib/systemd to
  determine if systemd is used.
* Thu Mar 31 2016 Jonny Schulz <js@bloonix.de> - 0.51-1
- Implemented support for Elasticsearch index aliases.
* Tue Mar 29 2016 Jonny Schulz <js@bloonix.de> - 0.50-1
- Fixed systemctl errors.
* Mon Mar 28 2016 Jonny Schulz <js@bloonix.de> - 0.49-1
- bloonix-update-agent-host-config: added options 'test' and 'when'.
- Fixed systemd/sysvinit/upstart installation routines.
* Sun Mar 20 2016 Jonny Schulz <js@bloonix.de> - 0.48-1
- Fixed: update the service status if the agent was dead
  and the service is a volatile check.
* Sat Mar 19 2016 Jonny Schulz <js@bloonix.de> - 0.47-1
- Fixed: retry_interval of services were ignored.
- Fixed: update the service status if the agent was dead
  and the service is a volatile check.
* Wed Feb 17 2016 Jonny Schulz <js@bloonix.de> - 0.47-1
- Fixed: retry_interval of services were ignored.
* Sat Feb 13 2016 Jonny Schulz <js@bloonix.de> - 0.46-1
- Fixed: check maintenance version after the first
  database connection.
* Fri Feb 12 2016 Jonny Schulz <js@bloonix.de> - 0.45-1
- Improved check of the database schema version.
* Mon Feb 01 2016 Jonny Schulz <js@bloonix.de> - 0.44-1
- Fixed: max_sms were ignored of hosts and companies.
* Sun Jan 10 2016 Jonny Schulz <js@bloonix.de> - 0.43-1
- Fixed bloonix-get-sms-count.
* Mon Nov 16 2015 Jonny Schulz <js@bloonix.de> - 0.42-1
- Kicked deprecated fcgi support.
- Fixed paths in systemd files if the server
  is installed manually.
- Implemented Bloonix::NetAddr to parse IP ranges.
* Fri Sep 18 2015 Jonny Schulz <js@bloonix.de> - 0.41-1
- Fixed uninitialized variable IPADDR6.
* Thu Sep 17 2015 Jonny Schulz <js@bloonix.de> - 0.40-1
- Fixed tags that were not added to events.
- Added variable IPADDR6.
* Mon Sep 14 2015 Jonny Schulz <js@bloonix.de> - 0.39-1
- Enabled IPv6 support.
- Fixed tags that were not added to events.
* Sun Sep 06 2015 Jonny Schulz <js@bloonix.de> - 0.38-1
- status_nok_since is now updated correctly in table host.
* Tue Sep 01 2015 Jonny Schulz <js@bloonix.de> - 0.37-1
- Fixed: force_timed_event is now resetted.
* Tue Sep 01 2015 Jonny Schulz <js@bloonix.de> - 0.36-1
- Added field force_event to table service.
- The server disconnects now if the db schema version changed.
* Mon Aug 31 2015 Jonny Schulz <js@bloonix.de> - 0.35-1
- Fixed: try to prevent ntp issues by calculating the next service check.
- If attempt_max is set to 0 then notifications are disabled.
* Tue Aug 18 2015 Jonny Schulz <js@bloonix.de> - 0.34-1
- Fixed: Can't modify non-lvalue subroutine call at Server.pm line 1379.
* Tue Aug 18 2015 Jonny Schulz <js@bloonix.de> - 0.33-1
- Fixed %preun section in spec file.
- Moved the creation of user bloonix into the core package.
* Sat Aug 15 2015 Jonny Schulz <js@bloonix.de> - 0.32-1
- Bloonix::Server dies now if no /usr/sbin/sendmail is found.
* Thu Aug 06 2015 Jonny Schulz <js@bloonix.de> - 0.31-1
- Heavy changes and code improvements.
- Kicked sms* and mail* parameter.
- Re-designed the notification handling.
* Tue Jun 16 2015 Jonny Schulz <js@bloonix.de> - 0.30-1
- bloonix-update-agent-host-config now checks on a very simple
  way if sysvinit or systemctl must be used to restart the agent.
* Tue Jun 16 2015 Jonny Schulz <js@bloonix.de> - 0.29-1
- Fixed @@LIBDIR@@ and clean up the wrong directory.
* Wed Jun 10 2015 Jonny Schulz <js@bloonix.de> - 0.28-1
- Prevent to log FATAL messages with a stack trace if the
  request structure of the agent was invalid.
- Implemented company.data_retention in bloonix-delete-es-host-data.
* Fri May 08 2015 Jonny Schulz <js@bloonix.de> - 0.27-1
- Improved rest debugging.
- Fixed uninitialized warnings messages.
* Sun May 03 2015 Jonny Schulz <js@bloonix.de> - 0.26-1
- Removed location caching.
* Wed Apr 15 2015 Jonny Schulz <js@bloonix.de> - 0.25-1
- Kicked default_locations.
* Sat Mar 21 2015 Jonny Schulz <js@bloonix.de> - 0.24-1
- ProcManager and FCGI were splittet into 2 modules.
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
