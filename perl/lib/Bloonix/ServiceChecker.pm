=head1 NAME

Bloonix::ServiceChecker - The bloonix service checker.

=head1 SYNOPSIS

    Bloonix::ServiceChecker->run(
        config_file => $mainconf,
        pid_file    => $pid_file,
    );

=head1 DESCRIPTION

This is the bloonix daemon, the parent process and forking machine.

The bloonix daemon loads the configuration file, initiate all
necessary components and handles all bloonix server. Bloonix servers
will be forked, reaped and a lot more. The section C<prefork> of the
configuration controls how the daemon handles the bloonix servers.

=head1 METHODS

=head2 C<run>

C<run> is the constructor and the only function that should
be called from outside. It expects the parameter C<config_file>
and C<pid_file>.

    Bloonix::ServiceChecker->run(
        config_file => $mainconf,
        pid_file    => $pid_file,
    );

The daemon can be reloaded with a HUP signal.

=head2 C<init>

Initiate the daemon.

    - load the configuration
    - load the logger
    - create the listen socket
    - connect to the database
    - and so on

=head2 C<daemonize>

C<daemonize> just run C<manage_children> in a endless loop
until someone tells the daemon to reload the configuration.

=head2 C<manage_children>

C<manage_children> is the main logic of the daemon. It check
if it's necessary to fork new or to reap died servers.

=head2 C<spawn_child>

=head2 C<kill_children>

=head2 C<start_servers>

This method is just called if the daemon will be initiated
and it pre-forkes the number of servers that are configured
with C<start_servers> in the configuration file from the
section C<prefork>.

=head2 C<sig_child_handler>

This method is called on each CHLD signal to reap children.

=head2 C<validate>

This method loads the configuration file and pass the
configuration as a hash reference to further validate_*
methods.

=head2 C<validate_main>

Validate main parameter.

=head2 C<validate_prefork>

Validate parameter for section C<prefork>.

=head2 C<validate_args>

Validate parameter that are passed to C<run()>.

=head1 PREREQUISITES

    Log::Handler
    Params::Validate
    POSIX
    Sys::Hostname

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2009-2014 by Jonny Schulz. All rights reserved.

=cut

package Bloonix::ServiceChecker;

use strict;
use warnings;
use Bloonix::Config;
use Bloonix::DBI;
use Bloonix::HangUp;
use Bloonix::IO::SIPC;
use Bloonix::SQL::Creator;
use Params::Validate qw();
use POSIX qw(:sys_wait_h getgid getuid setgid setuid);
use Sys::Hostname qw();
use Log::Handler;

# Some accessors
use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/children config dbi dbi_lock done io log sql stmt/);
__PACKAGE__->mk_counters(qw/update/);

# Some constants
use constant DAEMON_PID => $$;
use constant SERVER_START => time;

our $VERSION = "0.4";

sub run {
    my $class = shift;
    my $opts = $class->validate_args(@_);
    my $self = bless $opts, $class;

    $self->init;
    $self->daemonize;
}

sub init {
    my $self = shift;
    my $config = $self->validate;

    $self->done(0);
    $self->config($config);

    Bloonix::HangUp->now(
        user => $self->config->{user},
        group => $self->config->{group},
        pid_file => $self->{pid_file}
    );

    $self->log(Log::Handler->new);
    $self->log->set_default_param(die_on_errors => 0);
    $self->log->config(config => $config->{logger});
    $self->set_sigs;
    $self->dbi(Bloonix::DBI->new($config->{database}));
    $self->dbi_lock(Bloonix::DBI->new($config->{database}));
    $self->sql($self->dbi->sql);
    $self->children({});
    $self->io(Bloonix::IO::SIPC->new($config->{server}));
}

sub set_sigs {
    my $self = shift;

    # Intercept warn() messages
    $SIG{__WARN__} = sub {
        # Checking if log() is true because it is undefined
        # after global destruction:
        #   ... (in cleanup) Can't call method "log" on an
        #   undefined value at ...
        if (ref($self->{log}) eq "Log::Handler") {
            $self->{log}->warning(@_);
        }
    };

    $SIG{__DIE__} = sub {
        $self->log->error(@_);
    };

    # Handle signal CHLD to reap all died children.
    $SIG{CHLD} = sub {
        $self->sig_child_handler(@_);
    };

    # Stop the daemon if the signal HUP, INT or TERM comes in.
    $SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub {
        $self->log->notice("signal HUB/TERM/INT received");
        $self->done(1);
    };
}

sub daemonize {
    my $self = shift;

    # Wait after a fresh start.
    $self->log->notice(
        "service checker freshly startet,",
        "giving the agents", $self->config->{srvchkwait},
        "seconds time to re-connect"
    );

    while (SERVER_START + $self->config->{srvchkwait} > time && $self->done == 0) {
        $self->log->notice(SERVER_START + $self->config->{srvchkwait} - time, "seconds left");
        sleep 5;
    }

    # Daemonize
    $self->log->notice("service checker started");

    while (!$self->done) {
        eval { $self->manage_workers };

        if (!$self->done) {
            sleep 15;
        }
    }

    # Kill all children.
    $self->kill_children;
    # The daemon stopped now.
    $self->log->notice("service checker stopped");
}

sub manage_workers {
    my $self = shift;
    my $cur  = scalar keys %{$self->children};
    my $max  = $self->config->{workers};

    if ($cur < $max) {
        $self->spawn_child($max - $cur);
    }
}

sub spawn_child {
    my ($self, $num) = @_;

    for (1..$num) {
        my $pid = fork;

        if ($pid) {
            $self->children->{$pid} = time;
            $self->log->notice("forked child with pid $pid");
        } elsif (!defined $pid) {
            $self->log->error("unable to fork server: $!");
        } else {
            # Take care that the process doesn't jump out.
            eval { $self->run_service_checker };
            # Exit the server immediate.
            exit($@ ? 9 : 0);
        }
    }
}

sub kill_children {
    my $self = shift;

    # Don't TERM the daemon. At first we reap all childs.
    local $SIG{TERM} = "IGNORE";

    # Send TERM to all childs. The childs will be stopped
    # immediate if their don't process a request. If a child
    # process a request then its stopped after the reuqest
    # is finished.
    $self->log->notice("sending TERM to all children");
    my @chld = keys %{ $self->children };

    if (@chld) {
        kill 15, @chld;
    }

    # Give the children some time to exit.
    # 10 seconds should be more than enough.
    my $waited = 0;

    while (@chld) {
        $self->log->notice("waiting for children", @chld);
        sleep 1;
        @chld = keys %{ $self->children };
        $waited++;
        if ($waited == 10) {
            last;
        }
    }

    # If there are some children still alive then
    # they are killed hard - no absolution :-)
    @chld = keys %{ $self->children };

    if (@chld) {
        $self->log->notice("kill 9", @chld);
        kill 9, @chld;
    }
}

sub sig_child_handler {
    my $self = shift;

    # Reap children.
    while ((my $child = waitpid(-1, WNOHANG)) > 0) {
        if ($? > 0) {
            $self->log->error("child $child died: $?");
        } else {
            $self->log->notice("child $child died: $?");
        }

        # for kill_children
        delete $self->children->{$child};
    }

    $SIG{CHLD} = sub { $self->sig_child_handler(@_) };
}

sub run_service_checker {
    my $self = shift;

    # NOTIC: be careful to set CHLD to ignore because MIME::Lite
    # returns every time a error because it's "close $SENDMAIL"
    # doesn't work correctly. See RT#64963.
    $SIG{CHLD} = "DEFAULT";

    $self->log->notice("service checker started");

    while (!$self->done) {
        eval {
            $self->log->notice("checking services");
            $self->dbi->reconnect;
            $self->dbi_lock->reconnect;

            while (my $services = $self->get_timed_out_host_services) {
                my (%data, $host);

                foreach my $service (@$services) {
                    if (!$host) {
                        $host = $self->get_host_by_id($service->{host_id});
                        $self->log->info("***", scalar @$services, "expired services found");
                        %data = (
                            action => "post-service-data",
                            whoami => "srvchk",
                            version => $VERSION,
                            host_id => $host->{id},
                            password => $host->{password}
                        );
                    }

                    $data{data}{$service->{id}} = {
                        status  => "CRITICAL",
                        message => "Next service check is overdue! Is the host or Bloonix agent dead?"
                    };
                }

                if (scalar keys %data && !$self->done) {
                    $self->log->notice("reporting", scalar keys %data, "expired services");
                    $self->log->dump(info => \%data);
                    $self->io->connect or die $self->io->errstr;
                    $self->io->send(\%data) or die $self->io->errstr;
                }

                last if $self->done;
            }
        };

        if (!$self->done) {
            sleep 15;
        }
    }

    $self->log->notice("service checker stopped");
}

sub get_timed_out_host_services {
    my $self = shift;
    my $time = time;
    my $services;

    # This string should be unique.
    my $unistr = join(".", $$, $self->update(1), Sys::Hostname::hostname);
    $unistr = substr($unistr, 0, 50);

    eval {
        $self->dbi_lock->begin;
        $self->dbi_lock->lock("lock_srvchk");

        my $service = $self->dbi->unique(qq{
            select host_id
            from service
            where next_timeout <= ?
            and next_timeout != '0'
            order by next_timeout asc
            limit 1
        }, $time);

        if ($service) {
            $services = $self->dbi->fetch(qq{
                select id, host_id
                from service
                where host_id = ?
                and next_timeout <= ?
                and next_timeout != '0'
            }, $service->{host_id}, $time);

            if (@$services) {
                my $service_ids = [ map { $_->{id} } @$services ];

                $self->dbi->do(
                    $self->sql->update(
                        table => "service",
                        # Force next timeout to time + 60 seconds and try
                        # again after 60 seconds if the bloonix server is
                        # dead. The bloonix server will set the next timeout
                        # to time + 300 seconds.
                        data => { next_timeout => $time + 60 },
                        condition => [ id => $service_ids ]
                    )
                );
            }
        }

        $self->dbi_lock->commit;
        $self->dbi_lock->unlock;
    };

    if ($@) {
        eval { $self->dbi_lock->rollback };
        eval { $self->dbi_lock->unlock };
        $self->dbi_lock->disconnect;
        return undef;
    }

    return $services && @$services ? $services : undef;
}

sub get_host_by_id {
    my ($self, $host_id) = @_;

    return $self->dbi->unique(
        $self->dbi->sql->select(
            table => [
                host => [qw(id timeout)],
                host_secret => "password"
            ],
            join => [
                inner => {
                    table => "host_secret",
                    left  => "host.id",
                    right => "host_secret.host_id"
                }
            ],
            condition => [
                "host.id" => $host_id
            ]
        )
    );
}

sub validate_args {
    my $class = shift;

    my %opts = Params::Validate::validate(@_, {
        config_file => {
            type => Params::Validate::SCALAR,
            default => "/etc/bloonix/srvchk/main.conf"
        },
        pid_file => {
            type => Params::Validate::SCALAR,
            default => "/var/run/bloonix/blxchk.pid"
        }
    });

    return \%opts;
}

sub validate {
    my $self = shift;
    my $config = Bloonix::Config->parse($self->{config_file});
    return $self->validate_main($config);
}

sub validate_main {
    my $self = shift;

    my %opts = Params::Validate::validate(@_, {
        workers => {
            type => Params::Validate::SCALAR,
            default => 3,
            regex => qr/^\d+\z/
        },
        user => {
            type => Params::Validate::SCALAR,
            default => "bloonix"
        },
        group => {
            type => Params::Validate::SCALAR,
            default => "bloonix"
        },
        server => {
            type => Params::Validate::HASHREF
        },
        database => {
            type => Params::Validate::HASHREF
        },
        logger => {
            type => Params::Validate::HASHREF,
            optional => 1
        },
        srvchkwait => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 90
        }
    });

    my $server = $opts{server};
    if ($server->{port}) {
        $server->{peerport} = delete $server->{port};
    }
    if ($server->{host}) {
        $server->{peeraddr} = delete $server->{host};
    }

    return \%opts;
}

1;
