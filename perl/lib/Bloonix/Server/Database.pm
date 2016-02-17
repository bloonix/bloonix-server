package Bloonix::Server::Database;

use strict;
use warnings;
use Bloonix::DBI;
use Bloonix::NetAddr;
use Bloonix::SQL::Creator;
use NetAddr::IP;
use Time::ParseDate;
use Sys::Hostname;

use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/sql dbi log/);

our $VERSION = "0.1";
our $UNISTR  = 0;

sub new {
    my ($class, $config) = @_;

    my $dbi = Bloonix::DBI->new($config);
    my $log = $dbi->log;
    my $sql = $dbi->sql;
    my $self = bless { dbi => $dbi, log => $log, sql => $sql }, $class;

    return $self;
}

sub disconnect {
    my $self = shift;

    return $self->dbi->disconnect;
}

sub connect {
    my $self = shift;

    return $self->dbi->connect;
}

sub reconnect {
    my $self = shift;

    return $self->dbi->reconnect;
}

sub check_host {
    my ($self, $host_id, $password) = @_;

    return $self->dbi->unique(
        $self->sql->select(
            table => "host_secret",
            column => "host_id",
            condition => [
                host_id => $host_id,
                password => $password
            ]
        )
    );
}

sub get_company {
    my ($self, $company_id) = @_;

    return $self->dbi->unique(
        $self->sql->select(
            table => "company",
            column => "*",
            condition => [ "company.id" => $company_id ]
        )
    );
}

sub get_services {
    my ($self, $host_id) = @_;

    my $data = $self->dbi->fetch(
        $self->sql->select(
            table => [
                service => "*",
                service_parameter => "*",
                plugin => "command"
            ],
            join => [
                inner => {
                    table => "service_parameter",
                    left => "service.service_parameter_id",
                    right => "service_parameter.ref_id"
                },
                inner => {
                    table => "plugin",
                    left => "service_parameter.plugin_id",
                    right => "plugin.id"
                }
            ],
            condition => [
                where => {
                    table => "service",
                    column => "host_id",
                    value => $host_id
                }
            ]
        )
    );

    if ($data && @$data) {
        my %services;

        foreach my $row (@$data) {
            $services{$row->{id}} = $row;
        }

        return \%services;
    }

    return 0;
}

sub get_services_by_ids {
    my ($self, @services) = @_;
    my %services;

    my $rows = $self->dbi->fetch(
        $self->sql->select(
            table => [
                service => [qw(id status)],
                service_parameter => "service_name"
            ],
            join => [
                inner => {
                    table => "service_parameter",
                    left => "service.service_parameter_id",
                    right => "service_parameter.ref_id"
                }
            ],
            condition => [
                where => {
                    table => "service",
                    column => "id",
                    op => "in",
                    value => \@services
                }
            ]
        )
    );

    if ($rows && @$rows) {
        foreach my $row (@$rows) {
            $services{$row->{id}} = $row;
        }
    }

    return \%services;
}

sub get_service_contacts {
    my ($self, $host_id, $service_id) = @_;

    my $s_contact = $self->dbi->fetch(
        $self->sql->select(
            table => [
                contact => "*",
            ],
            join => [
                inner => {
                    table => "contact_contactgroup",
                    left  => "contact.id",
                    right => "contact_contactgroup.contact_id",
                },
                inner => {
                    table => "service_contactgroup",
                    left  => "contact_contactgroup.contactgroup_id",
                    right => "service_contactgroup.contactgroup_id",
                },
            ],
            condition => [
                "service_contactgroup.service_id" => $service_id,
            ],
        )
    );

    my $h_contact = $self->dbi->fetch(
        $self->sql->select(
            table => [
                contact => "*",
            ],
            join => [
                inner => {
                    table => "contact_contactgroup",
                    left  => "contact.id",
                    right => "contact_contactgroup.contact_id",
                },
                inner => {
                    table => "host_contactgroup",
                    left  => "contact_contactgroup.contactgroup_id",
                    right => "host_contactgroup.contactgroup_id",
                },
            ],
            condition => [
                "host_contactgroup.host_id" => $host_id,
            ],
        )
    );

    my @contact = ();
    my %seen = ();

    if ($s_contact) {
        foreach my $c (@$s_contact) {
            if (!$seen{$c->{id}}) {
                push @contact, $c;
                $seen{$c->{id}} = 1;
            }
        }
    }

    if ($h_contact) {
        foreach my $c (@$h_contact) {
            if (!$seen{$c->{id}}) {
                push @contact, $c;
                $seen{$c->{id}} = 1;
            }
        }
    }

    return \@contact;
}

sub get_contact_message_services {
    my ($self, $contact_id) = @_;

    my ($stmt, @bind) = $self->sql->select(
        table => "contact_message_services",
        column => "*",
        condition => [ contact_id => $contact_id ]
    );

    return $self->dbi->fetch($stmt, @bind);
}

sub get_active_host_services {
    my ($self, $host_id, $agent_id) = @_;

    my @condition = (
        where => {
            table  => "service",
            column => "host_id",
            op     => "=",
            value  => $host_id
        },
        and => {
            table  => "service",
            column => "active",
            op     => "=",
            value  => 1
        },
        and => {
            table  => "host",
            column => "active",
            op     => "=",
            value  => 1
        }
    );

    if (defined $agent_id && length $agent_id && $agent_id ne "all") {
        if (ref $agent_id ne "ARRAY") {
            my @ids;
            foreach my $id (split /,/, $agent_id) {
                $id =~ s/^\s+//;
                $id =~ s/\s+\z//;
                push @ids, $id;
            }
            $agent_id = \@ids;
        }
        push @condition, and => {    
            table  => "service_parameter",
            column => "agent_id", 
            op     => "in",    
            value  => $agent_id
        };
    }

    my $services = $self->dbi->fetch(
        $self->sql->select(
            table => [
                service => [ "id AS service_id", qw(
                    agent_version last_status last_check status
                    updated force_check attempt_counter
                    next_check next_timeout
                )],
                service_parameter => [qw(
                    agent_id command_options location_options
                    agent_options host_alive_check retry_interval
                    interval timeout host_template_id attempt_max
                )],
                plugin => [qw(command) ]
            ],
            join => [
                inner => {
                    table => "service_parameter",
                    left => "service.service_parameter_id",
                    right => "service_parameter.ref_id"
                },
                inner => {
                    table => "plugin",
                    left => "service_parameter.plugin_id",
                    right => "plugin.id"
                },
                inner => {
                    table => "host",
                    left  => "service.host_id",
                    right => "host.id"
                }
            ],
            condition => \@condition
        )
    );

    my %templates;
    foreach my $service (@$services) {
        if ($service->{host_template_id}) {
            my $host_template_id = $service->{host_template_id};

            if (!exists $templates{$host_template_id}) {
                $templates{$host_template_id} = $self->dbi->unique(
                    $self->sql->select(
                        table => "host_template",
                        column => "*",
                        condition => [ id => $host_template_id ]
                    )
                );
            }

            $service->{variables} = $templates{$host_template_id}{variables};
        }
    }

    return $services;
}

sub get_sms_count {
    my ($self, $type, $id, $year, $month) = @_;

    if (!$year) {
        my @time = (localtime(time))[reverse 0..5];
        $year = $time[0] + 1900;
        $month = $time[1] + 1;
    }

    my $from = sprintf("%04d-%02d-%02d", $year, $month, 1);
    my $to = sprintf("%04d-%02d-%02d", $year, $month == 12 ? 1 : $month + 1, 1);
    $from = Time::ParseDate::parsedate($from);
    $to = Time::ParseDate::parsedate($to);

    if ($type eq "host") {
        return $self->dbi->unique(
            $self->sql->select(
                count => "*",
                table => "notification",
                condition => [
                    where => {
                        column => "host_id",
                        op => "=",
                        value => $id
                    },
                    and => {
                        column => "time",
                        op => ">=",
                        value => $from
                    },
                    and => {
                        column => "time",
                        op => "<",
                        value => $to
                    },
                    and => {
                        column => "message_service",
                        op => "=",
                        value => "sms"
                    }
                ]
            )
        );
    }

    return $self->dbi->unique(
        $self->sql->select(
            count => "*",
            table => "notification",
            condition => [
                where => {
                    column => "company_id",
                    op => "=",
                    value => $id
                },
                and => {
                    column => "time",
                    op => ">=",
                    value => $from
                },
                and => {
                    column => "time",
                    op => "<",
                    value => $to
                },
                and => {
                    column => "message_service",
                    op => "=",
                    value => "sms"
                }
            ]
        )
    );
}

sub get_host_by_auth {
    my ($self, $host_id, $password, $peeraddr, $allow_from) = @_;

    my @select = (
        table => [
            host => "*",
            host_secret => "password",
        ],
        join => [
            inner => {
                table => "host_secret",
                left  => "host.id",
                right => "host_secret.host_id",
            }
        ]
    );

    if ($host_id =~ /^\d+\z/) {
        push @select, (
            condition => [
                "host.id" => $host_id,
                "host_secret.password" => $password,
                "host.register" => 0
            ]
        );
    } else {
        push @select, (
            condition => [
                "host.hostname" => $host_id,
                "host_secret.password" => $password,
                "host.register" => 0
            ]
        );
    }

    my $host = $self->dbi->unique(
        $self->sql->select(@select)
    );

    if ($host) {
        if (
            ($allow_from && Bloonix::NetAddr->ip_in_range($peeraddr, $allow_from))
            || ($host->{allow_from} && Bloonix::NetAddr->ip_in_range($peeraddr, $host->{allow_from}))
        ) {
            return $host;
        }
    }

    return undef;
}

sub update_service_status {
    my ($self, $id, $status) = @_;

    return $self->dbi->do(
        $self->sql->update(
            table  => "service",
            column => $status,
            condition => [ id => $id ],
        )
    );
}

sub get_plugin_stats {
    my $self = shift;
    my %data = ();

    my $plugins = $self->dbi->fetch(
        $self->sql->select(
            table  => "plugin_stats",
            column => [qw(plugin_id statkey stattype datatype regex substr default)],
        )
    );

    foreach my $row (@$plugins) {
        my $plugin_id = delete $row->{plugin_id};
        my $statkey = delete $row->{statkey};
        $data{$plugin_id}{$statkey} = $row;
    }

    return \%data;
}

sub get_plugin {
    my $self = shift;
    my %data = ();

    my $plugins = $self->dbi->fetch(
        $self->sql->select(
            table  => "plugin",
            column => [qw(id plugin category subkey datatype)],
        )
    );

    foreach my $row (@$plugins) {
        my $id = delete $row->{id};
        $data{$id} = $row;
    }

    return \%data;
}

sub get_host_by_id {
    my ($self, $host_id) = @_;

    return $self->dbi->unique(
        $self->sql->select(
            table  => "host",
            column => "*",
            condition => [ id => $host_id ],
        )
    );
}

sub get_service_by_id {
    my ($self, $service_id) = @_;

    return $self->dbi->unique(
        $self->sql->select(
            table => [
                service => "*",
                service_parameter => "*"
            ],
            join => [
                inner => {
                    table => "service_parameter",
                    left => "service.service_parameter_id",
                    right => "service_parameter.ref_id"
                }
            ],
            condition => [ "service.id" => $service_id ],
        )
    );
}

sub get_service_states {
    my ($self, $host_id) = @_;

    return $self->dbi->fetch(
        $self->sql->select(
            distinct  => 1,
            table     => "service",
            column    => "status",
            condition => [ host_id => $host_id ],
        )
    );
}

sub update_force_check {
    my ($self, $service_id, $value) = @_;

    return $self->dbi->do(
        $self->sql->update(
            table  => "service",
            column => { force_check => $value },
            condition => [ id => $service_id ],
        )
    );
}

sub update_host_status {
    my ($self, $host_id, $data) = @_;

    return $self->dbi->do(
        $self->sql->update(
            table  => "host",
            column => $data,
            condition => [ id => $host_id ],
        )
    );
}

sub create_send_sms {
    my ($self, $time, $host_id, $company_id, $send_to, $message) = @_;

    return $self->dbi->do(
        $self->sql->insert(
            table  => "notification",
            column => {
                time => $time,
                host_id => $host_id,
                company_id => $company_id,
                message_service => "sms",
                send_to => $send_to,
                subject => "",
                message => $message
            },
        )
    );
}

sub create_send_mail {
    my ($self, $time, $host_id, $company_id, $send_to, $subject, $message) = @_;

    return $self->dbi->do(
        $self->sql->insert(
            table  => "notification",
            column => {
                time => $time,
                host_id => $host_id,
                company_id => $company_id,
                message_service => "mail",
                send_to => $send_to,
                subject => $subject,
                message => $message
            },
        )
    );
}

sub get_host_downtime {
    my ($self, $host_id, $begin, $end) = @_;

    return $self->dbi->fetch(
        $self->sql->select(
            table => [
                host_downtime => "*",
            ],
            condition => [
                where => {
                    table  => "host_downtime",
                    column => "host_id",
                    op     => "=",
                    value  => $host_id,
                },
                pre => [
                    pre => [
                        and => {
                            table  => "host_downtime",
                            column => "begin",
                            op     => "<=",
                            value  => $begin,
                        },
                        and => {
                            table  => "host_downtime",
                            column => "end",
                            op     => ">=",
                            value  => $end,
                        },
                    ],
                    or => {
                        table  => "host_downtime",
                        column => "timeslice",
                        op     => "is not null",
                    },
                    or => {
                        table  => "host_downtime",
                        column => "timeslice",
                        op     => "!=",
                        value  => ""
                    }
                ]
            ]
        )
    );
}

sub get_service_downtime {
    my ($self, $host_id, $begin, $end) = @_;

    return $self->dbi->fetch(
        $self->sql->select(
            table => [
                service_downtime => "*",
            ],
            condition => [
                where => {
                    table  => "service_downtime",
                    column => "host_id",
                    op     => "=",
                    value  => $host_id,
                },
                pre => [
                    pre => [
                        and => {
                            table  => "service_downtime",
                            column => "begin",
                            op     => "<=",
                            value  => $begin,
                        },
                        and => {
                            table  => "service_downtime",
                            column => "end",
                            op     => ">=",
                            value  => $end,
                        },
                    ],
                    or => {
                        table  => "service_downtime",
                        column => "timeslice",
                        op     => "is not null",
                    },
                    or => {
                        table  => "service_downtime",
                        column => "timeslice",
                        op     => "!=",
                        value  => ""
                    }
                ]
            ]
        )
    );
}

sub get_timeslices_by_contact_id {
    my ($self, $contact_id) = @_;

    return $self->dbi->fetch(
        $self->sql->select(
            table => [
                timeslice => "*",
                contact_timeperiod => [qw(message_service exclude timezone)],
            ],
            join => [
                inner => {
                    table => "contact_timeperiod",
                    left  => "timeslice.timeperiod_id",
                    right => "contact_timeperiod.timeperiod_id",
                }
            ],
            condition => [
                "contact_timeperiod.contact_id" => $contact_id,
            ]
        )
    );
}

sub get_timeslices_by_timeperiod_id {
    my ($self, $timeperiod_id) = @_;

    return $self->dbi->fetch(
        $self->sql->select(
            table => "timeslice",
            column => "*",
            condition => [ timeperiod_id => $timeperiod_id ],
        )
    );
}

sub get_dependencies {
    my ($self, $host_id, $service_id) = @_;
    $host_id //= 0;
    $service_id //= 0;

    return $self->dbi->fetch(
        $self->sql->select(
            distinct => 1,
            table => "dependency",
            column => "*",
            condition => [
                where => {
                    column => "host_id",
                    value  => $host_id,
                },
                or => {
                    column => "service_id",
                    value  => $service_id,
                },
            ],
        )
    );
}

sub get_maintenance {
    my $self = shift;

    my $maintenance = $self->dbi->unique(
        $self->sql->select(
            table => "maintenance",
            column => "*"
        )
    );

    if (defined $maintenance->{version}) {
        if (!defined $self->{maintenance_version}) {
            $self->{maintenance_version} = $maintenance->{version};
        } elsif ($self->{maintenance_version} ne $maintenance->{version}) {
            $self->{maintenance_version} = $maintenance->{version};
            $self->log->warning("db schema version changed, disconnect");
            $self->dbi->disconnect;
        }
    }

    return $maintenance->{active};
}

sub get_locations {
    my $self = shift;
    my %locations;

    my $locations = $self->dbi->fetch(
        $self->sql->select(
            table => "location",
            column => "*"
        )
    );

    foreach my $location (@$locations) {
        $locations{$location->{id}} = $location;
    }

    return \%locations;
}

sub update_agent_version {
    my ($self, $version, $ids) = @_;
    push @$ids, 0;

    $self->dbi->do(
        $self->sql->update(
            table  => "service",
            column => { agent_version => $version },
            condition => [ id => $ids ],
        )
    );
}

1;
