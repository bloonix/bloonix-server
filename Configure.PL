#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);

if (!-e "Makefile") {
    print "Execute me from the source directory!\n";
    exit 1;
}

my $o_prefix           = "/usr/local";
my $o_cachedir         = "/var/cache";
my $o_confdir          = "/etc";
my $o_build_package    = 0;
my $o_initdir          = "/etc/init.d";
my $o_logdir           = "/var/log";
my $o_rundir           = "/var/run";
my $o_srvdir           = "/srv";
my $o_perl             = "/usr/bin/perl";
my $o_perl_prefix      = "/usr/local";
my $o_perl_installdirs = "site";
my $o_without_perl     = 0;
my $o_user             = "bloonix";
my $o_group            = "bloonix";
my $o_ssl_ca_path      = "/etc/ssl/certs";
my $o_ssl_ca_file      = "";
my $o_help             = 0;

GetOptions(
    "prefix=s"           => \$o_prefix,
    "cachedir=s"         => \$o_cachedir,
    "confdir=s"          => \$o_confdir,
    "initdir=s"          => \$o_initdir,
    "logdir=s"           => \$o_logdir,
    "rundir=s"           => \$o_rundir,
    "srvdir=s"           => \$o_srvdir,
    "perl=s"             => \$o_perl,
    "perl-prefix=s"      => \$o_perl_prefix,
    "perl-installdirs=s" => \$o_perl_installdirs,
    "without-perl"       => \$o_without_perl,
    "build-package"      => \$o_build_package,
    "user=s"             => \$o_user,
    "group=s"            => \$o_group,
    "ssl-ca-path=s"      => \$o_ssl_ca_path,
    "ssl-ca-file=s"      => \$o_ssl_ca_file,
    "h|help"             => \$o_help,
);

if ($o_help) {
    print "\nUsage: perl Configure.PL [ OPTIONS ]\n\n";
    print "Configure options:\n\n";
    print "  --prefix DIR (default: $o_prefix)\n";
    print "  --cachedir DIR (default: $o_cachedir)\n";
    print "  --confdir DIR (default: $o_confdir)\n";
    print "  --initdir DIR (default: $o_initdir)\n";
    print "  --logdir DIR (default: $o_logdir)\n";
    print "  --rundir DIR (default: $o_rundir)\n";
    print "  --srvdir DIR (default: $o_srvdir)\n";
    print "  --perl PERL EXECUTABLE (default: $o_perl)\n";
    print "  --perl-prefix DIR (default: $o_perl_prefix)\n";
    print "  --perl-installdirs INSTALLDIRS (default: $o_perl_installdirs)\n";
    print "  --without-perl (default: $o_without_perl)\n";
    print "  --user user (default: $o_user)\n";
    print "  --group group (default: $o_group)\n";
    print "  --ssl-ca-path (default: $o_ssl_ca_path)\n";
    print "  --ssl-ca-file (default: not set)\n";
    print "  --help (print the help)\n\n";
    exit 0;
}

my ($ssl_param, $ssl_value);
if ($o_ssl_ca_file) {
    $ssl_param = "ssl_ca_file";
    $ssl_value = $o_ssl_ca_file;
} else {
    $ssl_param = "ssl_ca_path";
    $ssl_value = $o_ssl_ca_path;
}

open my $fh, ">", "Makefile.config" or die "Unable to overwrite Makefile - $!";

print "Writing Makefile.config ...\n";

print $fh <<EOF;
PREFIX=\$(DESTDIR)$o_prefix
CACHEDIR=\$(DESTDIR)$o_cachedir
CONFDIR=\$(DESTDIR)$o_confdir
INITDIR=\$(DESTDIR)$o_initdir
LOGDIR=\$(DESTDIR)$o_logdir
RUNDIR=\$(DESTDIR)$o_rundir
SRVDIR=\$(DESTDIR)$o_srvdir
USRLIBDIR=\$(DESTDIR)$o_prefix/lib
BUILDPKG=$o_build_package
PERL=$o_perl
PERL_PREFIX=\$(DESTDIR)$o_perl_prefix
PERL_INSTALLDIRS=$o_perl_installdirs
WITHOUT_PERL=$o_without_perl
USERNAME=$o_user
GROUPNAME=$o_group
SSL_CA_PARAM=$ssl_param
SSL_CA_VALUE=$ssl_value
EOF

close $fh;

print "Done.\n";
