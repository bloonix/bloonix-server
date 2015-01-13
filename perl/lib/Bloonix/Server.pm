package Bloonix::Server;

use strict;
use warnings;
use Params::Validate qw//;
use Fcntl qw(:flock);
use JSON;
use Math::BigInt;
use Math::BigFloat;
use MIME::Lite;
use POSIX qw(getgid getuid setgid setuid);
use Time::HiRes;
use URI::Escape;

use Log::Handler;
use Log::Handler::Output::File;
Log::Handler->create_logger("bloonix")->set_pattern("%X", "X", "n/a"); # client ip
Log::Handler->get_logger("bloonix")->set_pattern("%Y", "Y", "n/a"); # host id

use Bloonix::HangUp;
use Bloonix::FCGI;
use Bloonix::Server::Validate;
use Bloonix::Server::Database;
use Bloonix::Timeperiod;
use Bloonix::REST;

use base qw/Bloonix::Accessor/;
__PACKAGE__->mk_accessors(qw/config log tlog ipc db done mail rest statbyprio json fcgi cgi peerhost/);
__PACKAGE__->mk_accessors(qw/host_services host_downtime service_downtime dependencies whoami/);
__PACKAGE__->mk_accessors(qw/host plugin plugin_stats stime etime mtime roster company request host_alive_status/);
__PACKAGE__->mk_accessors(qw/force_timed_event_entry es_index maintenance locations default_location attempt_max_reached/);
__PACKAGE__->mk_accessors(qw/service_status_duration service_id c_service n_service service_interval service_timeout/);
__PACKAGE__->mk_accessors(qw/min_smallint max_smallint min_int max_int min_bigint max_bigint/);
__PACKAGE__->mk_accessors(qw/min_m_float max_m_float min_p_float max_p_float/);

our $VERSION = "0.14";

sub run {
    my $class = shift;


    $self->init;
    $self->fcgi(Bloonix::FCGI->new($self->config->{proc_manager}));
    $self->log->notice("bloonix server started");

    while (my $cgi = $self->fcgi->accept) {
        next unless $cgi;
        $self->cgi($cgi);

        eval {
            my $time = Time::HiRes::gettimeofday();
            $ENV{TZ} = $self->config->{timezone};
            $self->log->set_pattern("%X", "X", $self->cgi->remote_addr);
            $self->log->set_pattern("%Y", "Y", "n/a");
            $self->log->notice("request started (${time}s)");
            $self->peerhost($self->cgi->remote_addr);
            $self->db->reconnect;
            $self->set_time;

            if ($cgi->path_info eq "/ping") {
                $self->response({ status => "ok", message => "pong" });
            } elsif ($cgi->path_info =~ m!^/hostcheck/([1-9]\d*?)\.([^\s]+)\z!) {
                $self->process_host_check($1, $2);
            } else {
                $self->process_request;
            }

            $time = sprintf("%.3f", Time::HiRes::gettimeofday() - $time);
            $self->log->notice("request finished (${time}s)");
        };

        if ($@) {
            $self->log->trace(error => $@);
        }
    }
}

sub init {
    my $self = shift;

    $self->init_config;
    $self->hang_up;
    $self->init_logger;
    $self->init_math_objects;
    $self->statbyprio({qw(OK 0 INFO 5 WARNING 10 CRITICAL 20 UNKNOWN 30)});
    $self->rest(Bloonix::REST->new($self->config->{elasticsearch}));
    $self->rest->utf8(1);
    $self->db(Bloonix::Server::Database->new($self->config->{database}));
    $self->tlog(Log::Handler::Output::File->new($self->config->{elasticsearch_roll_forward}));
    $self->json(JSON->new);
    $self->maintenance(0);
}

sub init_config {
    my $self = shift;

    # Configuration
    $self->config(
        Bloonix::Server::Validate->config(
            $self->{config_file}
        )
    );
}

sub hang_up {
    my $self = shift;

    Bloonix::HangUp->now(
        user => $self->config->{user},
        group => $self->config->{group},
        pid_file => $self->{pid_file}
    );
}

sub init_logger {
    my $self = shift;

    # Logger
    $self->log(Log::Handler->get_logger("bloonix"));
    $self->log->set_default_param(die_on_errors => 0);
    $self->log->set_pattern("%X", "X", "server");
    $self->log->config(config => $self->config->{logger});
    $self->log->notice("new bloonix server started");
}

sub init_math_objects {
    my $self = shift;

    $self->min_smallint("-32768");
    $self->max_smallint("32767");
    $self->min_int("-2147483648");
    $self->max_int(2147483647);
    $self->min_bigint("-9223372036854775808");
    $self->max_bigint("9223372036854775807");
    $self->min_m_float(Math::BigFloat->new("-3.402823466E+38"));
    $self->max_m_float(Math::BigFloat->new("-1.175494351E-38"));
    $self->min_p_float(Math::BigFloat->new("1.175494351E-38"));
    $self->max_p_float(Math::BigFloat->new("3.402823466E+38"));
}

sub process_host_check {
    my ($self, $host_id, $password) = @_;

    my $host = $self->db->check_host($host_id, $password);

    if ($host) {
        $self->log->warning("hostcheck from", $self->cgi->remote_addr, "for host $host_id was successful");
        $self->response({ status => "ok", message => "host $host_id exists" });
    } else {
        $self->log->error("hostcheck from", $self->cgi->remote_addr, "for host $host_id was not successful");
        $self->response({ status => "err", message => "host $host_id does not exists" });
    }
}

sub check_request {
    my $self = shift;

    $self->log->notice("check authorization");

    if (!$self->cgi->postdata) {
        $self->log->error("no post data received");
        $self->response({ status => "err", message => "no post data received" });
        return undef;
    }

    # jsondata returnes utf8 decoded data if the decoding was successful
    my $decoded = $self->cgi->jsondata // $self->json->decode($self->cgi->postdata);
    my $request = Bloonix::Server::Validate->request($decoded);

    $self->whoami($request->{whoami});
    $self->log->set_pattern("%Y", "Y", "host id $request->{host_id}");
    $self->log->notice("processing request");

    my $host = $self->db->get_host_by_auth(
        $request->{host_id},
        $request->{password},
        $self->peerhost,
        $self->config->{allow_from}
    );

    if (!$host) {
        $self->log->warning("access denied");
        $self->log->dump(warning => $request);
        $self->response({ status => "err", message => "access denied" });
        return undef;
    }

    # If the host_id is a hostname instead a host id...
    $request->{host_id} = $host->{id};

    my $company = $self->db->get_company($host->{company_id});

    if ($company->{active} != 1) {
        $self->log->warning("company is not active");
        $self->response({ status => "err", message => "access denied" });
        return undef;
    }

    $self->host($host);
    $self->company($company);
    $self->request($request);
    $self->debug_data;

    return 1;
}

sub check_locations {
    my $self = shift;

    if (!$self->locations) {
        my ($locations, $default_location) = $self->db->get_locations;
        $self->locations($locations);
        $self->default_location($default_location);
    }
}

sub get_services {
    my $self = shift;
    my @services;

    $self->log->notice(
        "request config for host id", $self->request->{host_id},
        "agent id", $self->request->{agent_id}
    );

    my $services = $self->db->get_active_host_services(
        $self->request->{host_id},
        $self->request->{agent_id}
    );

    $self->update_agent_version($services);

    foreach my $service (@$services) {
        $service->{interval} ||= $self->host->{interval};
        $service->{timeout} ||= $self->host->{timeout};

        # When a check is forced:
        #
        #   - if the interval is exceeded
        #   - if a check is forced over the webgui
        #   - if the status is WARNING|CRITICAL|UNKNOWN
        #
        # If the status is WARNING|CRITICAL|UNKNOWN and if the interval is between
        # 60 and 43200 seconds, then a interval of 60 seconds is forced.
        #
        # If the status is WARNING|CRITICAL|UNKNOWN and if the interval is higher than
        # or equal 43200 seconds, then a interval of 300 seconds is forced.

        if ($service->{force_check}) {
            $self->log->info("service $service->{service_id} check forced");
            $self->db->disable_force_check($service->{service_id});
            push @services, $service;
        } elsif ($service->{last_check} + $service->{interval} <= $self->etime) {
            $self->log->info("service $service->{service_id} is ready");
            push @services, $service;
        } elsif ($service->{status} ne "OK" && $service->{interval} >= 60 && $service->{interval} < 43200 && $service->{last_check} + 60 <= $self->etime) {
            $self->log->info("service $service->{service_id} forced to be ready");
            push @services, $service;
        } elsif ($service->{status} ne "OK" && $service->{interval} >= 43200 && $service->{interval} < 86400 && $service->{last_check} + 300 <= $self->etime) {
            $self->log->info("service $service->{service_id} forced to be ready");
            push @services, $service;
        } elsif ($service->{status} ne "OK" && $service->{interval} >= 86400 && $service->{last_check} + 600 <= $self->etime) {
            $self->log->info("service $service->{service_id} forced to be ready");
            push @services, $service;
        } else {
            $self->log->info("service $service->{service_id} is not ready");
        }
    }

    return \@services;
}

sub process_request {
    my $self = shift;

    $self->check_request or return;
    $self->check_locations;

    if ($self->cgi->request_method eq "GET") {
        $self->process_get_request;
    } elsif ($self->cgi->request_method eq "POST") {
        $self->process_post_request;
    }
}

sub process_get_request {
    my $self = shift;

    my $services = $self->get_services;
    my $host = $self->host;
    my $host_variables = $self->json->decode($host->{variables});
    my $company_variables = $self->json->decode($self->company->{variables});

    if (!exists $host_variables->{HOSTNAME}) {
        $host_variables->{HOSTNAME} = $host->{hostname};
    }
    if (!exists $host_variables->{IPADDR}) {
        $host_variables->{IPADDR} = $host->{ipaddr};
    }

    foreach my $service (@$services) {
        # Remove all whitespaces and newlines so that we can
        # split the addresses as a comma separated list.
        $host->{ipaddr} =~ s/\s//g;

        if ($service->{command}) {
            my %variables;

            # The service variables are inherited from the template
            # and must be overwritten by the variables set by the host.
            if ($service->{variables}) {
                if (ref $service->{variables} ne "HASH") {
                    $service->{variables} = $self->json->decode($service->{variables});
                }
                %variables = (%$company_variables, %{$service->{variables}}, %$host_variables)
            } else {
                %variables = (%$company_variables, %$host_variables);
            }

            foreach my $key (keys %variables) {
                next if $key !~ /^[a-zA-Z_0-9\.\s]+\z/;
                next if $key =~ /^\s*\z/;
                $self->log->info("replace %$key% with $variables{$key}");
                $service->{command_options} =~ s/%$key%/$variables{$key}/g;
            }

            $service->{command_options} = $self->json->decode($service->{command_options});
            $service->{agent_options} = $self->json->decode($service->{agent_options});

            if ($service->{location_options}) {
                my $location_options = $self->json->decode($service->{location_options});

                if (scalar keys %$location_options) {
                    my $check_type = $location_options->{check_type};

                    $service->{location_options} = {
                        check_type => $check_type,
                        concurrency => $location_options->{concurrency} || 3,
                        locations => []
                    };

                    if ($check_type eq "default") {
                        push @{$service->{location_options}->{locations}}, $self->default_location;
                    } else {
                        foreach my $location (@{$location_options->{locations}}) {
                            if ($self->locations->{$location}) {
                                push @{$service->{location_options}->{locations}}, $self->locations->{$location};
                            }
                        }
                    }
                }
            }

            # Backward compability for older agents. simple-wrapper is available since 0.41.
            if ($service->{command} eq "check-simple-wrapper") {
                if ($self->request->{version} =~ /^0\.([0123]\d|40)\z/) {
                    $service->{command} = "check-nagios-wrapper";
                    my $opts = $service->{command_options};
                    if ($opts) {
                        foreach my $opt (@$opts) {
                            if ($opt->{option} eq "simple-command") {
                                $opt->{option} = "nagios-command";
                            }
                        }
                    }
                }
            }

            # Special cluster check
            if ($service->{command} eq "check-cluster") {
                my @services;

                foreach my $option (@{$service->{command_options}}) {
                    next unless $option->{option} eq "service";
                    push @services, do { $option->{value} =~ /^(\d+)/; $1 };
                }

                my $services = $self->db->get_services_by_ids(@services);

                foreach my $option (@{$service->{command_options}}) {
                    next unless $option->{option} eq "service";
                    if ($option->{value} =~ /^(\d+)/) {
                        my $service_id = $1;
                        $services->{$service_id}->{service_name} =~ s/'//g;
                        $option->{value} = join(":",
                            $option->{value},
                            $services->{$service_id}->{status},
                            $services->{$service_id}->{service_name}
                        );
                    }
                }
            }
        }
    }

    $self->log->notice("sending configuration");

    $self->response({
        status => "ok",
        data => {
            services => $services,
            # REMOVE
            # Deprecated... the interval setting can be removed
            # if all agents running with version 0.24.
            interval => $host->{interval}
        }
    });
}

sub process_post_request {
    my $self = shift;
    $self->log->notice("send data for host id", $self->request->{host_id});
    $self->response({ status => "ok", message => "processing data" });
    $self->{set_next_check} = $self->request->{whoami} eq "srvchk" ? 1 : 0;
    $self->process_data;
}

sub process_data {
    my $self = shift;

    my $data = $self->request->{data};
    my $host_id = $self->host->{id};
    my $host_services = $self->db->get_services($host_id);

    # If no services are configured... just return!
    if (!$host_services) {
        $self->log->info("no services configured");
        sleep 5;
        return 1;
    }

    # Clear the message buffer
    $self->{mails} = { };
    $self->{sms}   = { };

    # Clear and reuse the object buffers
    $self->host_downtime(undef);
    $self->service_downtime(undef);
    $self->roster(undef);
    $self->dependencies({});
    $self->attempt_max_reached({});
    $self->get_downtimes;
    $self->host_services($host_services);
    $self->host_alive_status("NULL");
    $self->maintenance($self->db->get_maintenance);

    # Search for a service that is defined as check-host-alive
    # and store the status of the check.
    if (exists $host_services->{host_alive_check}) {
        $self->host_alive_status($host_services->{host_alive_check}->{status});
    } else {
        $self->host_alive_status("NULL");
    }

    # Log the host alive status
    $self->log->notice("host alive status:", $self->host_alive_status);

    # Validate, check and store the service data
    $self->validate_data($data) or return undef;
    $self->check_services($data);
    $self->update_host_status;
    $self->store_stats($data);
    $self->send_sms;
    $self->send_mails;
}

sub debug_data {
    my ($self, $data) = @_;
    my $host_id = $self->host->{id};

    if (-e "/tmp/bloonix-server-debug-$host_id") {
        if (open my $fh, ">>", "/tmp/bloonix-server-debug-$host_id.out") {
            if ($data) {
                if (ref $data) {
                    $data = JSON->new->pretty->encode($data);
                }
                print $fh $data, "\n";
            } else {
                print $fh "#" x 40, "\n";
                print $fh scalar localtime, "\n";
                print $fh "#" x 40, "\n\n";
                print $fh "HTTP method: ", $self->cgi->request_method, "\n\n";
                print $fh JSON->new->pretty->encode($self->request), "\n";
            }
            close $fh;
        }
    }
}

sub get_roster {
    my $self = shift;

    if (!$self->roster) {
        my $host_id = $self->host->{id};
        my $roster = $self->db->get_roster_host($host_id, $self->stime);
        $self->roster($roster);
    }

    return $self->roster ? @{ $self->roster } : ();
}

sub get_downtimes {
    my $self = shift;

    my %srvcdt = ();
    my $host_id = $self->host->{id};
    my $host_downtime = $self->db->get_host_downtime($host_id, $self->stime, $self->stime);

    if (@$host_downtime) {
        $self->log->info("all host downtimes from database:");
        $self->log->dump(info => $host_downtime);

        foreach my $dt (@$host_downtime) {
            if ($dt->{begin} && $dt->{end}) {
                $self->host_downtime($host_downtime->[0]);
                last;
            } elsif ($dt->{timeslice}) {
                my $datetime = $dt->{timeslice};
                if (Bloonix::Timeperiod->check($datetime, $self->etime, $dt->{timezone})) {
                    $self->host_downtime($host_downtime->[0]);
                    last;
                }
            }
        }
    }

    if (!$self->host_downtime) {
        my $service_downtime = $self->db->get_service_downtime($host_id, $self->stime, $self->stime);

        if (@$service_downtime) {
            $self->log->info("all service downtimes from database:");
            $self->log->dump(info => $service_downtime);

            foreach my $dt (@$service_downtime) {
                if (!exists $srvcdt{ $dt->{service_id} }) {
                    if ($dt->{begin} && $dt->{end}) {
                        $srvcdt{ $dt->{service_id} } = $dt;
                    } elsif ($dt->{timeslice}) {
                        my $datetime = $dt->{timeslice};
                        if (Bloonix::Timeperiod->check($datetime, $self->etime, $dt->{timezone})) {
                            $srvcdt{ $dt->{service_id} } = $dt;
                        }
                    }
                }
            }
        }
    }

    $self->service_downtime(\%srvcdt);

    if ($self->host_downtime) {
        $self->log->info("active host downtimes:");
        $self->log->dump(info => $self->host_downtime);
    }
    if (scalar keys %srvcdt) {
        $self->log->info("active service downtimes:");
        $self->log->dump(info => $self->service_downtime);
    }
}

sub validate_data {
    my ($self, $data) = @_;
    my $host_id = $self->host->{id};
    my $services = $self->host_services;
    my (%checked, %stats);

    if (ref($data) ne "HASH") {
        $self->log->error("bad data structure received from agent");
        return undef;
    }

    CHECK:
    foreach my $service_id (keys %$data) {
        if ($service_id !~ /^\w+\z/ || !exists $services->{$service_id}) {
            $self->log->error("invalid service id '$service_id'");
            delete $data->{$service_id};
            next CHECK;
        }

        my $n_service = $data->{$service_id};
        my $c_service = $services->{$service_id};

        if (ref $n_service ne "HASH") {
            $self->log->error("invalid data structure received for service id $service_id");
            $self->log->dump(error => $n_service);
            $data->{$service_id} = {
                status => "UNKNOWN",
                message => "invalid data structure received for service id $service_id",
            };
            next CHECK;
        }

        foreach my $key (qw/status message/) {
            if (!defined $n_service->{$key}) {
                $self->log->error("missing mandatory key '$key' for service id $service_id");
                $data->{$service_id} = {
                    status => "UNKNOWN",
                    message => "missing mandatory key '$key' for service id $service_id",
                };
                next CHECK;
            }

            if (ref $n_service->{$key}) {
                $self->log->error("invalid data struct for key '$key' for service id $service_id");
                $data->{$service_id} = {
                    status => "UNKNOWN",
                    message => "invalid data struct for key '$key' for service id $service_id",
                };
                next CHECK;
            }
        }

        if ($n_service->{status} !~ /^(?:OK|WARNING|CRITICAL|UNKNOWN)\z/) {
            $n_service->{message} = "invalid status '$n_service->{status}'";
            $n_service->{status}  = "UNKNOWN";
            next CHECK;
        }

        if (length $n_service->{message} > 10000) {
            $n_service->{message} = substr($n_service->{message}, 0, 10000);
        }

        # If the service or host is not active then the data are destroyed!
        if ($c_service->{active} == 0 || $self->{host}->{active} == 0) {
            $self->log->notice(
                "service or host is inactive - deleting data for", 
                "service $c_service->{id}"
            );
            delete $n_service->{stats};
        }
    }

    return 1;
}

sub check_services {
    my ($self, $data) = @_;
    my $host = $self->host;
    my $host_id = $host->{id};
    my $services = $self->host_services;
    my %contacts = ();

    # Pre-check the host-alive-status if the check is found.
    # This is necessary because the %$data hash is looped
    # unsorted, so if the host-alive-status is checked at last
    # then each service that was checked before the host-alive-check
    # is marked without the HOST DOWN notification. It's better
    # to intercept this.
    if (exists $data->{host_alive_check}) {
        $self->host_alive_status($data->{host_alive_check}->{status});
    }

    $self->log->notice("check the status of services");

    my $today_date = $self->year_month_stamp;

    CHECK: # Bloonix-Notification-Workflow
    foreach my $service_id (keys %$data) {
        # n_service = new service data
        # c_service = current service data
        my $n_service  = $data->{$service_id};
        my $c_service  = $services->{$service_id};

        # Service informations
        my $n_status = $n_service->{status}; # new status
        my $c_status = $c_service->{status}; # current status
        my $a_status = $c_service->{highest_attempt_status};
        my $interval = $c_service->{interval} || $host->{interval};
        my $timeout = $c_service->{timeout} || $host->{timeout};

        # Force an event if the month switched and no event was stored
        # in the current month.
        my $last_event_date = $self->year_month_stamp($c_service->{last_event});

        # Save event tags
        my @event_tags;

        # Accessors
        $self->n_service($n_service);
        $self->c_service($c_service);
        $self->service_id($service_id);
        $self->service_interval($interval);
        $self->service_timeout($timeout);
        $self->service_status_duration($self->etime - $c_service->{status_since});
        $self->force_timed_event_entry($last_event_date ne $today_date);
        $self->attempt_max_reached->{$service_id} = 0;

        if ($n_service->{advanced_status}) {
            $n_service->{result} = delete $n_service->{advanced_status};
        }

        if ($n_service->{message} =~ /Bloonix.+agent\s+dead/) {
            push @event_tags, "agent dead";
        }

        if ($n_service->{message} =~ /timeout|timed out/) {
            push @event_tags, "timeout";
        }

        if ($self->etime - $c_service->{last_event} > 31_536_000) {
            my $num = $self->etime - $c_service->{last_event};
            $self->log->error("last event ($num) is higher than 31_536_000");
            $self->log->dump(error => $c_service);
        }

        # Let's go
        $self->log->notice("checking service $service_id command $c_service->{command} with status $n_status");

        if ($self->check_if_host_or_service_not_active) {
            next CHECK;
        }
        if ($self->check_if_downtime_is_active) {
            next CHECK;
        }
        if ($self->check_if_srvchk_remote_error) {
            next CHECK;
        }

        if ($c_service->{host_alive_check} && $self->host_alive_status =~ /CRITICAL|UNKNOWN/) {
            # Disable temporary the notifications if the host-alive-status is critical
            # or unknown. On this way the real service status and the statistics can be
            # stored without send a notfication. In addion the parameter highest_attempt_status
            # should control that a notification is not send after the service is OK again.
            $c_service->{notification} = 0;
            $n_service->{message} = "[HOST DOWN] $n_service->{message}";
        }

        if ($c_service->{host_alive_check} && $n_status =~ /CRITICAL|UNKNOWN/) {
            my $affected_services = scalar keys %$services;
            $n_service->{message} = "[HOST ALIVE STATUS IS $n_status WITH $affected_services AFFECTED SERVICES] $n_service->{message}";
        }

        # Store new status data
        my %status = (message => $n_service->{message});

        foreach my $key (qw/result debug/) {
            if ($n_service->{$key}) {
                $status{$key} = ref $n_service->{$key}
                    ? $self->json->encode($n_service->{$key})
                    : $n_service->{$key};
            } else {
                $status{$key} = "";
            }
        }

        if ($c_service->{scheduled} == 1) {
            $status{scheduled} = 0;
        }

        # status_nok_since:
        #     ok = OK | INFO
        #    nok = WARNING | CRITICAL | UNKNOWN
        # status_since
        #    The time in epoch since the service is in this status
        if ($c_status ne $n_status) {
            my $cs_is_ok = $c_status =~ /^(OK|INFO)\z/;
            my $ns_is_ok = $n_status =~ /^(OK|INFO)\z/;

            if (($cs_is_ok && !$ns_is_ok) || (!$cs_is_ok && $ns_is_ok)) {
                $status{status_nok_since} = $self->etime;
            }

            $status{status_since} = $self->etime;
        }

        # Just some short variables
        my $is_volatile = $c_service->{is_volatile}; # is this a volatile status?
        my $volatile_status = $c_service->{volatile_status}; # has become the service volatile?
        my $volatile_retain = $c_service->{volatile_retain};
        my $volatile_since = $c_service->{volatile_since};
        my $volatile_time = $volatile_retain + $volatile_since;

        # If the status is not OK and if the volatile_status flag is not set
        if ($n_status =~ /^(?:WARNING|CRITICAL|UNKNOWN)\z/) {
            if ($is_volatile && !$volatile_status) {
                $self->log->info("set service in volatile status since", $self->etime);
                $status{volatile_status} = 1;
                $status{volatile_since} = $self->etime;
            }
        }

        # If the volatile_status flag is set and the retain time is not expired
        if ($is_volatile && $volatile_status && ($volatile_retain == 0 || $volatile_time > $self->etime)) {
            $self->log->info("unable to set the status to OK because service is in volatile status");
            push @event_tags, "volatile";
            $status{volatile_status} = 1;
        }

        # Manipulate the volatile status because the status must be hold
        if ($status{volatile_status}) {
            if ($self->statbyprio->{$n_status} < $self->statbyprio->{$c_status}) {
                $self->log->info("overwrite service status from $n_status to volatile status $c_status");
                $status{status} = $n_service->{status} = $n_status = $c_status;
            }
            $status{message} = "[VOLATILE] $status{message}";
        }

        # Check if the status is OK and reset some parameter
        if ($n_status eq "OK") {
            if ($volatile_status) {
                $status{volatile_status} = 0;
            }

            if ($volatile_since) {
                $status{volatile_since}  = 0;
            }

            if ($c_service->{attempt_counter} > 1) {
                $status{attempt_counter} = 1;
            }

            if ($c_service->{last_mail} > 0) {
                $status{last_mail} = 0;
            }

            if ($c_service->{last_sms} > 0) {
                $status{last_sms}  = 0;
            }

            if ($c_service->{acknowledged} == 1) {
                $status{acknowledged} = 0;
            }

            if ($c_service->{status_dependency_matched} > 0) {
                $status{status_dependency_matched} = 0;
            }
        }

        # Check if the status is WARNING, CRITICAL or UNKNOWN
        if ($n_status =~ /^(?:WARNING|CRITICAL|UNKNOWN)\z/) {
            if ($c_service->{attempt_counter} == $c_service->{attempt_max}) {
                $self->attempt_max_reached->{$service_id} = 1;
            } elsif ($c_service->{attempt_counter} > $c_service->{attempt_max}) {
                $status{attempt_counter} = $c_service->{attempt_max};
                $c_service->{attempt_counter} = $c_service->{attempt_max};
            } elsif ($c_service->{attempt_counter} < $c_service->{attempt_max} && $c_status ne "OK") {
                $status{attempt_counter} = 1 + $c_service->{attempt_counter};
                $c_service->{attempt_counter} = 1 + $c_service->{attempt_counter};
            }

            if ($n_status eq "WARNING") {
                if ($c_service->{attempt_counter} == $c_service->{attempt_max}) {
                    if ($c_service->{attempt_warn2crit} == 1) {
                        $self->log->notice("attempt_max exceeded, status critical");
                        $n_service->{status} = $n_status = "CRITICAL";
                    }
                }
            }
        }

        # At first check if the service flaps between states.
        # fd_enabled fd_time_range fd_count_max
        my $flapping;
        if ($c_service->{fd_enabled} == 1) {
            my $flap_count = $self->get_service_flaps_by_time(
                $host_id,
                $c_service->{id},
                $self->etime - $c_service->{fd_time_range},
                $self->etime
            );

            $self->log->notice("FLAP COUNT $service_id $flap_count");
            if ($flap_count >= $c_service->{fd_flap_count}) {
                $self->log->notice("service $c_service->{id} is flapping - count $flap_count");
                $status{message} = "[SERVICE IS FLAPPING BETWEEN STATES] $status{message}";
                $flapping = 1;
            }
        }

        if ($flapping) {
            $status{flapping} = 1;
            push @event_tags, "flapping";
        } elsif ($c_service->{flapping}) {
            $status{flapping} = 0;
        }

        # Save the new status to the event table of the host and
        # to the global events table
        if (
            $n_status ne $c_status
            || $self->force_timed_event_entry
            || ($n_status !~ /^(OK|INFO)\z/ && !$self->attempt_max_reached->{$service_id})
        ) {
            $self->log->notice("EVENT STATUS $n_status SERVICE $service_id MESSAGE $n_service->{message}");
            $status{last_event} = $self->etime;

            $self->save_event(
                message => $status{message},
                tags => join(",", @event_tags),
                attempts => "$c_service->{attempt_counter}/$c_service->{attempt_max}"
            );
        }

        # The option highest_attempt_status is used to store the highest status
        # for the last notification that was send. That means if the status is
        # not OK and attempt_max is reached then the status will be saved to
        # "highest_attempt_status". Then, if the status fall back to OK again,
        # and a high status is saved to "highest_attempt_status", it's necessary
        # to send a OK notification because the admin wants to know if all is ok.
        if (
            $n_status eq "OK"
            || (
                $n_status ne "INFO"
                && $c_service->{attempt_counter} >= $c_service->{attempt_max}
                && $self->statbyprio->{$a_status} < $self->statbyprio->{$n_status}
               )
        ) {
            $status{highest_attempt_status} = $n_status;
        }

        $self->log->notice("save new service status - $n_status $n_service->{message}");
        $self->save_service_status(\%status);

        # Do nothing if the status doesn't changed
        if ($n_status eq "OK" && $c_status eq "OK") {
            next CHECK;
        }

        # If the new status is OK and highest_attempt_status is
        # OK too then it's not necessary to send a notification.
        if ($n_status eq "OK" && $a_status eq "OK") {
            next CHECK;
        }

        # No notification if notifications are disabled
        if ($host->{notification} == 0 || $c_service->{notification} == 0) {
            $self->log->notice("notifications disabled");
            next CHECK;
        }

        # No notification if the status isn't changed and
        # the status is acknowledged
        if ($n_status eq $c_status && $c_service->{acknowledged} == 1) {
            $self->log->notice("service status is acknowledged");
            next CHECK;
        }

        #if ($n_status ne "OK" && $c_service->{attempt_counter} < $c_service->{attempt_max}) {
        # In any case a notification will only be send if
        # attempt_counter reached attempt_max.
        if ($c_service->{attempt_counter} < $c_service->{attempt_max}) {
            if ($flapping) {
                $self->log->notice("attempt max not reached, but service is flapping between states");
            } else {
                $self->log->notice("attempt max not reached, just a soft state");
                next CHECK;
            }
        }

        # last_mail_time and last_sms_time are the timestamps when
        # the last notification was send. last_mail and last_sms
        # is the same but will be set back to 0 if the state of
        # the service was ok.
        my $next_mail_hard = $c_service->{last_mail_time} + $c_service->{mail_hard_interval};
        my $next_sms_hard  = $c_service->{last_sms_time}  + $c_service->{sms_hard_interval};
        my $next_mail_soft = $c_service->{last_mail}      + $c_service->{mail_soft_interval};
        my $next_sms_soft  = $c_service->{last_sms}       + $c_service->{sms_soft_interval};
        my $next_mail_flap = $c_service->{last_mail_time} + $c_service->{mail_soft_interval};
        my $next_sms_flap  = $c_service->{last_sms_time}  + $c_service->{sms_soft_interval};
        my ($save_sms, $save_mail);

        $self->log->info("check if a sms or email must be send");

        $self->log->notice(
            "last_sms=$c_service->{last_sms}",
            "last_sms_time=$c_service->{last_sms_time}",
            "sms_soft_interval=$c_service->{sms_soft_interval}",
            "sms_hard_interval=$c_service->{sms_hard_interval}"
        );

        # Now check if a sms must be send
        if ($c_service->{send_sms} == 0) {
            $self->log->notice("send_sms disabled by service, no sms send");
        } elsif ($self->company->{sms_enabled} == 0) {
            $self->log->notice("send_sms disabled by company, no sms send");
        } elsif (!$flapping && $n_status eq "OK" && $c_service->{sms_ok} == 0) {
            $self->log->notice("sms_ok disabled, no sms send");
        } elsif (!$flapping && $n_status eq "OK" && $a_status eq "WARNING" && $c_service->{sms_warnings} == 0) {
            $self->log->notice(
                "highest_attempt_status $a_status,",
                "sms_warnings disabled,",
                "no sms send",
            );
        } elsif (!$flapping && $n_status eq "WARNING" && $c_service->{sms_warnings} == 0) {
            $self->log->notice("sms_warnings disabled, no sms send");
        } elsif ($next_sms_hard > $self->etime) {
            $self->log->notice("no sms send - next sms $next_sms_hard (hard interval)");
        } elsif ($flapping && $next_sms_flap > $self->etime) {
            $self->log->notice("no sms send - service is flapping - next sms $next_sms_flap");
        } elsif ($n_status ne "OK" && $next_sms_soft > $self->etime && $self->statbyprio->{$n_status} <= $self->statbyprio->{$c_status}) {
            # Do not send a SMS if next_time is lower then etime
            # and if the new status is lower then the current status.
            # That means: if etime is lower -> sent a SMS
            # And: if the new status is higher -> sent a SMS (maybe the status switched from WARNING to CRITICAL)
            $self->log->notice("no sms send - next sms $next_sms_soft (soft interval)");
        } else {
            # Each host has a maximum pool of sms per month.
            # To improve the performance the counting of sent sms
            # is moved here, so the sms_count is first selected
            # from the database if the other conditions above
            # does not match.
            if (!defined $host->{sms_count}) {
                my $sms_count = $self->db->get_sms_count($host->{id});
                $host->{sms_count} = $sms_count->{count};

                if ($host->{max_sms} > 0) {
                    if ($host->{sms_count} * 100 / $host->{max_sms} > 90 || $host->{max_sms} - $host->{sms_count} < 5) {
                        $host->{available_sms_to_low} = 1;
                    }
                }
            }
            if ($host->{sms_count} >= $host->{max_sms}) {
                $self->log->notice("reached max_sms $host->{sms_count}/$host->{max_sms}");
            } else {
                $self->log->notice("sms will be send");
                $save_sms = 1;
            }
        }

        $self->log->notice(
            "last_mail=$c_service->{last_mail}",
            "last_mail_time=$c_service->{last_mail_time}",
            "mail_soft_interval=$c_service->{mail_soft_interval}",
            "mail_hard_interval=$c_service->{mail_hard_interval}"
        );

        # Now check if a mail must be send
        if (!$flapping && $n_status eq "OK" && $c_service->{mail_ok} == 0) {
            $self->log->notice("mail_ok disabled, no mail send");
        } elsif (!$flapping && $n_status eq "OK" && $a_status eq "WARNING" && $c_service->{mail_warnings} == 0) {
            $self->log->notice(
                "highest_attempt_status $a_status,",
                "mail_warnings disabled,",
                "no mail send",
            );
        } elsif (!$flapping && $n_status eq "WARNING" && $c_service->{mail_warnings} == 0) {
            $self->log->notice("mail_warnings disabled, no mail send");
        } elsif ($next_mail_hard > $self->etime) {
            $self->log->notice("no mail send - next mail $next_mail_hard (hard interval)");
        } elsif ($flapping && $next_mail_flap > $self->etime) {
            $self->log->notice("no mail send - service is flapping - next mail $next_mail_flap");
        } elsif ($n_status ne "OK" && $next_mail_soft > $self->etime && $self->statbyprio->{$n_status} <= $self->statbyprio->{$c_status}) {
            $self->log->notice("no mail send - next mail $next_mail_soft (soft interval)");
        } else {
            $self->log->notice("mail will be send");
            $save_mail = 1;
        }

        if ($save_sms || $save_mail) {
            my $contact = $self->db->get_service_contacts($host->{id}, $service_id);
            push @$contact, $self->get_roster;

            if (scalar @$contact) {
                # At first it will be checked if the service or host
                # has a dependency and if the dependency is in any
                # status that no notification must be send.
                if ($n_status ne "OK" && $self->dependency_is_in_true_status($host->{id}, $service_id, $n_status)) {
                    $self->log->notice(
                        "host id $host->{id} or service id $service_id has a",
                        "dependency status that is true, skipping notification",
                        "for status $n_status",
                    );
                    $self->db->save_service_status(
                        $c_service->{id},
                        { status_dependency_matched => $self->etime },
                    );
                    next CHECK;
                } elsif ($n_status eq "OK" && $c_service->{status_dependency_matched} > 0) {
                    # Do not send a notification if the new status is OK and
                    # if the last notifications were not send because of a
                    # service dependency.
                    $self->log->notice(
                        "host id $host->{id} or service id $service_id has a",
                        "dependency status that was true, skipping notification",
                        "for status $n_status",
                    );
                    next CHECK;
                } elsif ($n_status ne "OK" && $c_service->{status_dependency_matched} + 60 > $self->etime) {
                    # Avoid a race condition. If the service dependencies doesn't
                    # match any more but the service is still in a higher status
                    # than OK then a notification should send first if the last
                    # dependency check is 60 seconds ago.
                    $self->log->notice(
                        "host id $host->{id} or service id $service_id has a",
                        "dependency status that was true, skipping notification",
                        "for status $n_status to avoid a race condition",
                    );
                    next CHECK;
                } elsif ($c_service->{status_dependency_matched} > 0) {
                    $self->db->save_service_status(
                        $c_service->{id},
                        { status_dependency_matched => 0 },
                    );
                }

                # If the service currently switched from OK to CRITICAL then
                # and attempt_max is set to 1, then status_nok_since contains
                # the timestamp since the status is OK. For this reason it's
                # necessary to set s_since to 0 if the last status of the
                # service was OK or INFO.
                my $s_since = 0;
                if ($c_status ne "OK" && $c_status ne "INFO") {
                    $s_since = $self->etime - $c_service->{status_nok_since};
                }

                my $s_h_int = $c_service->{sms_hard_interval}  || 0;
                my $s_s_int = $c_service->{sms_soft_interval}  || 0;
                my $m_h_int = $c_service->{mail_hard_interval} || 0;
                my $m_s_int = $c_service->{mail_soft_interval} || 0;

                CONTACT:
                foreach my $c (@$contact) {
                    # Start to check contact
                    $self->log->info("check contact $c->{name} ($c->{id})");

                    my $e_level = $c->{escalation_level} || 0;
                    my $do_send = { sms => 0, mail => 0 };

                    # Pre-check if notifications are completly disabled
                    if ($c->{sms_notifications_enabled} == 0 && $c->{mail_notifications_enabled} == 0) {
                        # notifications are completly disabled for this contact
                        next CONTACT; # skip
                    }

                    # Pre-check if the contact has any contact data set
                    if (!$c->{sms_to} && !$c->{mail_to}) {
                        # there are no contact data set
                        next CONTACT; # skip
                    }

                    # Check if the contact has a valid timeperiod or if the
                    # contact in configured in a active roster.
                    if ($c->{is_roster}) {
                        $self->log->info("check roster-time for contact $c->{name} ($c->{id})");
                        $do_send = { sms => $c->{send_sms}, mail => $c->{send_mail} };
                    } else {
                        $self->log->info("check timeperiod for contact $c->{name} ($c->{id})");
                        $do_send = $self->is_in_notification_period($c->{id}, $c->{name});
                    }

                    # Check the escalation level of the contact. If the escalation level
                    # not NULL then the contact wants to be informed every time the soft
                    # or hard interval timed out.
                    if ($e_level) {
                        $self->log->notice(
                            "check sms escalation level for contact '$c->{name}' ($c->{id}):",
                            "($s_h_int && $s_since / $s_h_int < $c->{escalation_level})",
                            "|| ($s_s_int && $s_since / $s_s_int < $e_level})",
                        );

                        if (($s_h_int && $s_since / $s_h_int < $e_level) || ($s_s_int && $s_since / $s_s_int < $e_level)) {
                            $self->log->notice("sms escalation level does not match for contact $c->{name} ($c->{id})");
                            $do_send->{sms} = 0;
                        } else {
                            $self->log->notice("sms escalation level matched for contact $c->{name} ($c->{id})");
                        }

                        $self->log->notice(
                            "check mail escalation level for contact '$c->{name}' ($c->{id}):",
                            "($m_h_int && $s_since / $m_h_int < $c->{escalation_level})",
                            "|| ($m_s_int && $s_since / $m_s_int < $e_level})",
                        );

                        if (($m_h_int && $s_since / $m_h_int < $e_level) || ($m_s_int && $s_since / $m_s_int < $e_level)) {
                            $self->log->notice("mail escalation level does not match for contact $c->{name} ($c->{id})");
                            $do_send->{mail} = 0;
                        } else {
                            $self->log->notice("mail escalation level matched for contact $c->{name} ($c->{id})");
                        }
                    }

                    # Some shortcuts because the if-condition are so fucking long :-)
                    my $sms_note_enabled  = $c->{sms_notifications_enabled} == 1;
                    my $sms_note_level    = $c->{sms_notification_level} =~ /all|$n_status/i;
                    my $mail_note_enabled = $c->{mail_notifications_enabled} == 1;
                    my $mail_note_level   = $c->{mail_notification_level} =~ /all|$n_status/i;

                    if ($save_sms && $c->{sms_to} && $sms_note_enabled && $sms_note_level && $do_send->{sms}) {
                        $self->log->notice(
                            "save sms for service id $service_id for contact",
                            "'$c->{name}' id $c->{id} level $e_level",
                        );

                        $self->save_sms(
                            service_id => $service_id,
                            service => $c_service->{service_name},
                            status => $n_status,
                            message => $status{message},
                            sms_to => $c->{sms_to}
                        );
                    }

                    if ($save_mail && $c->{mail_to} && $mail_note_enabled && $mail_note_level && $do_send->{mail}) {
                        $self->log->notice(
                            "save mail for service id $service_id for contact",
                            "'$c->{name}' id $c->{id} level $e_level",
                        );

                        my $escalation_level = 0;

                        if ($s_since) {
                            if ($m_h_int > $m_s_int) {
                                $escalation_level = $m_h_int == 0 ? 0 : int($s_since / $m_h_int);
                            } else {
                                $escalation_level = $m_s_int == 0 ? 0 : int($s_since / $m_s_int);
                            }
                        }

                        $self->save_mail(
                            service_id => $service_id,
                            service => $c_service->{service_name},
                            status => $n_status,
                            message => $status{message},
                            mail_to => $c->{mail_to},
                            description => $c_service->{description},
                            comment => $c_service->{comment},
                            escalation => $escalation_level
                        );
                    }
                }
            } else {
                $self->log->notice("no contacts found for service $service_id");
            }
        }
    }
}

sub check_if_host_or_service_not_active {
    my $self = shift;
    my $comment;

    if ($self->c_service->{active} != 0 && $self->host->{active} != 0 && $self->company->{active} != 0) {
        return 0;
    }

    $self->log->notice("host", $self->host->{id}, "or service", $self->service_id, "is inactive");

    if ($self->c_service->{active} == 0) {
        $comment = $self->c_service->{active_comment} || "n/a";
    } elsif ($self->host->{active} == 0) {
        $comment = $self->host->{active_comment} || "n/a";
    } elsif ($self->company->{active} == 0) {
        $comment = $self->company->{active_comment} || "n/a";
    }

    my %status = (
        status => "INFO",
        message => join(" ", "[INACTIVE: $comment]", $self->n_service->{message}),
        attempt_counter => 1,
        next_check_timeout => $self->etime + $self->service_interval + $self->service_timeout
    );

    if ($self->n_service->{status} eq "OK" && $self->c_service->{status_dependency_matched} > 0) {
        $status{status_dependency_matched} = 0;
    }

    # Store the new status to the events table.
    if ($self->c_service->{status} ne "INFO" || $self->force_timed_event_entry) {
        $self->log->notice("EVENT STATUS OK SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $status{last_event} = $self->etime;

        $self->save_event(
            status => "INFO",
            message => $status{message},
            tags => "inactive"
        );

        if ($self->c_service->{status} ne "INFO" && $self->c_service->{status} ne "OK") {
            $status{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $status{status_since} = $self->etime;
        }
    }

    $self->save_service_status(\%status);
    return 1;
}

sub check_if_downtime_is_active {
    my $self = shift;

    if (!$self->host_downtime && !$self->service_downtime->{$self->service_id}) {
        return 0;
    }

    $self->log->notice("service", $self->service_id, "has a scheduled downtime");
    my $downtime = $self->host_downtime ? $self->host_downtime : $self->service_downtime->{$self->service_id};
    my $message = "[SCHEDULED DOWNTIME, ";

    if ($downtime) {
        $message .= "CREATOR: $downtime->{username}, ";
        $message .= "REASON: $downtime->{description}, ";

        if ($downtime->{timeslice}) {
            $message .= "PERIOD: $downtime->{timeslice}]";
        } else {
            $message .= "PERIOD: $downtime->{begin} - $downtime->{end}]";
        }
    }

    my %status = (
        status => "INFO",
        message => join(" ", $message, $self->n_service->{message}),
        attempt_counter => 1,
        scheduled => 1,
        next_check_timeout => $self->etime + $self->service_interval + $self->service_timeout
    );

    if ($self->n_service->{status} eq "OK" && $self->c_service->{status_dependency_matched} > 0) {
        $status{status_dependency_matched} = 0;
    }

    # Store the new status to the event table.
    if ($self->c_service->{status} ne "INFO" || $self->force_timed_event_entry) {
        $self->log->notice("EVENT STATUS INFO SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $status{last_event} = $self->etime;

        $self->save_event(
            status => "INFO",
            message => $status{message},
            tags => "maintenance"
        );

        if ($self->c_service->{status} ne "INFO" && $self->c_service->{status} ne "OK") {
            $status{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $status{status_since} = $self->etime;
        }
    }

    $self->save_service_status(\%status);
    return 1;
}

sub check_if_srvchk_remote_error {
    my $self = shift;

    if ($self->whoami ne "srvchk" || $self->c_service->{agent_id} ne "remote" || !$self->config->{redirect_remote_agent_timeouts}) {
        return 0;
    }

    $self->log->notice("service", $self->service_id, "timed out, redirect sms and email");

    my $redirect_config = $self->config->{redirect_remote_agent_timeouts};
    my $host = $self->host;

    if ($redirect_config->{mail_to}) {
        $self->log->notice("redirect notification for service", $self->service_id, "to $redirect_config->{mail_to}");
        $self->save_mail(
            service_id => $self->service_id,
            service => $self->c_service->{service_name},
            status => $self->n_service->{status},
            message => $self->n_service->{message},
            mail_to => $redirect_config->{mail_to},
            description => $self->c_service->{description},
            comment => $self->c_service->{comment},
            escalation => "-1",
            redirect => 1
        );
    }

    #if ($redirect_config->{sms_to}) {
    #    $self->log->notice("redirect notification for service", $self->service_id, "to $redirect_config->{sms_to}");
    #    $self->save_sms(
    #        service_id => $self->service_id,
    #        service => $self->c_service->{service_name},
    #        status => $self->n_service->{status},
    #        message => $self->n_service->{message},
    #        sms_to => $redirect_config->{sms_to},
    #        redirect => 1
    #    );
    #}

    my %status = (
        status => "WARNING",
        message => join(" ", "[INTERNAL WARNING - remote agent dead]", $self->n_service->{message}),
        attempt_counter => 1,
        next_check_timeout => $self->etime + $self->service_interval + $self->service_timeout
    );

    if ($self->c_service->{status} ne "WARNING" || $self->force_timed_event_entry) {
        $self->log->notice("EVENT STATUS INFO SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $status{last_event} = $self->etime;

        $self->save_event(
            status => "WARNING",
            message => $status{message},
            tags => "remote-agent-dead"
        );

        if ($self->c_service->{status} ne "WARNING") {
            $status{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $status{status_since} = $self->etime;
        }
    }

    $self->save_service_status(\%status);
    return 1;
}

sub save_service_status {
    my $self = shift;
    my $data = @_ > 1 ? {@_} : shift;

    if ($self->{set_next_check}) {
        $data->{next_check_timeout} //= $self->etime + $self->service_interval;
    } else {
        $data->{last_check} = $self->etime;
    }

    if (!$data->{status} || ($data->{status} ne "INFO" && $data->{status} ne $self->n_service->{status})) {
        $data->{status} = $self->n_service->{status};
    }

    $data->{next_check_id} = 0;
    $self->db->save_service_status($self->service_id, $data);
}

sub save_event {
    my $self = shift;
    my $data = @_ > 1 ? {@_} : shift;
    $data->{status} //= $self->n_service->{status};
    $data->{last_status} = $self->c_service->{status};
    $data->{service_id} = $self->service_id;
    $data->{duration} = $self->service_status_duration;

    foreach my $key (qw/result debug/) {
        if (ref $self->n_service->{$key}) {
            $data->{$key} = $self->n_service->{$key};
        }
    }

    $self->save_es_data(event => $data);
}

sub save_stats {
    my $self = shift;
    my $data = @_ > 1 ? {@_} : shift;
    $self->typecast($data);
    $self->save_es_data(stats => $data);
}

sub typecast {
    my ($self, $data) = @_;

    if (ref $data eq "HASH") {
        foreach my $key (keys %$data) {
            if (ref $data->{$key} eq "HASH") {
                $self->typecast($data->{$key});
            } elsif ($data->{$key} =~ /^\d+(\.\d+){0,1}\z/) {
                $data->{$key} += 0;
            }
        }
    }
}

sub save_results {
    my $self = shift;
    my $data = @_ > 1 ? {@_} : shift;
    $self->save_es_data(results => $data);
}

sub save_es_data {
    my ($self, $type, $data) = @_;
    my $path = join("/", $self->es_index, $type, "?routing=".$self->host->{id});

    $data->{time} = $self->mtime;
    $data->{host_id} = $self->host->{id};

    $self->debug_data($path);
    $self->debug_data($data);

    $self->rest_post(
        path => $path,
        data => $data
    );
}

sub dependency_is_in_true_status {
    my ($self, $host_id, $service_id, $service_status, $counter) = @_;
    my $ws;
    $host_id //= 0;
    $service_id //= 0;

    if (!defined $counter) {
        $counter = 10;
        $ws = "--";
    } else {
        $counter--;
        $ws = "--" x (11 - $counter);
    }

    $self->log->info($ws, "check dependencies for host id $host_id service id $service_id, counter $counter");

    my $deps = $self->db->get_dependencies($host_id, $service_id);
    my $stash = $self->dependencies;

    foreach my $dep (@$deps) {
        $self->log->info($ws, "checking dependency id $dep->{id}");

        my $on_host_id = $dep->{on_host_id};
        my $on_service_id = $dep->{on_service_id};
        my ($on_host, $on_service, $on_status);

        if ($stash->{host}->{$on_host_id}) {
            $on_host = $stash->{host}->{$on_host_id};
        } else {
            $on_host = $self->db->get_host_by_id($on_host_id);
            $stash->{host}->{$on_host_id} = $on_host;
        }

        $on_status = $on_host->{status};

        if ($on_service_id) {
            if ($stash->{service}->{$on_service_id}) {
                $on_service = $stash->{service}->{$on_service_id}
            } else {
                $on_service = $self->db->get_service_by_id($on_service_id);
                $stash->{service}->{$on_service_id} = $on_service;
            }
            $on_status = $on_service->{status};
        }

        $self->log->info($ws, "host [$on_host->{hostname} ($on_host->{id})]");

        if ($on_service_id) {
            $self->log->info($ws, "service [$on_service->{service_name} ($on_service->{id})]");
        }

        # timeperiod check
        $self->log->info(
            $ws, "check if timeperiod is active:",
            "$dep->{timeslice} - $dep->{timezone}"
        );

        my $ret = Bloonix::Timeperiod->check(
            $dep->{timeslice},
            $self->etime,
            $dep->{timezone}
        );

        if (!$ret) {
            $self->log->info(
                $ws, "ignoring dependency $dep->{id} because the timeperiod does not match:",
                "$dep->{timeslice} - $dep->{timezone}"
            );
            next;
        }

        # status check
        $self->log->info(
            $ws, "check if the status matched:",
            $dep->{status}, "==", $service_status,
        );

        if ($dep->{status} !~ /$service_status/) {
            $self->log->info(
                $ws, "ignoring dependency $dep->{id} because the status does not match:",
                $dep->{status}, "!=", $service_status,
            );
            next;
        }

        $self->log->info(
            $ws, "noticed active dependency $dep->{id} because the status matched:",
            $dep->{status}, "==", $service_status,
        );

        # on status check
        $self->log->info(
            $ws, "check if the parent status matched:",
            $dep->{on_status}, "==", $on_status
        );

        if ($dep->{on_status} =~ /$on_status/) {
            $self->log->info(
                $ws, "dependency $dep->{id} matched",
                $on_service_id ? "on service id $on_service_id" : "on host id $on_host_id",
                $dep->{on_status}, "==", $on_status,
            );
            return 1;
        }

        $self->log->info(
            $ws, "parent status of dependency $dep->{id} doesn't matched",
            $dep->{on_status}, "!=", $on_status
        );

        # check inheritation
        if ($dep->{inherit} && $counter > 0) {
            if ($self->dependency_is_in_true_status($on_host_id, $on_service_id, $service_status, $counter)) {
                $self->log->info($ws, "inherited dependency matched");
                return 1;
            } else {
                $self->log->info($ws, "inherited dependency does not matched");
            }
        }
    }

    $self->log->info($ws, "dependencies doesn't matched: host id $host_id, service id $service_id");
    return 0;
}

sub is_in_notification_period {
    my ($self, $contact_id, $contact_name) = @_;

    my $timeslices = $self->db->get_timeslices_by_contact_id($contact_id);
    my ($send_sms, $send_mail, $send_all, $exclude);

    $self->log->notice("check time periods for contact $contact_id $contact_name");

    if ($timeslices) {
        foreach my $timeslice (@$timeslices) {
            my $ret = Bloonix::Timeperiod->check(
                $timeslice->{timeslice}, 
                $self->etime,
                $timeslice->{timezone},
            );

            if ($ret) {
                $self->log->notice(
                    "time period $timeslice->{type} matched -",
                    "$timeslice->{timeslice} -",
                    $timeslice->{timezone},
                );

                if ($timeslice->{type} eq "send_to_all") {
                    $send_all = 1;
                } elsif ($timeslice->{type} eq "send_only_sms") {
                    $send_sms = 1;
                } elsif ($timeslice->{type} eq "send_only_mail") {
                    $send_mail = 1;
                } elsif ($timeslice->{type} eq "exclude") {
                    $exclude = 1;
                    return { sms => 0, mail => 0 };
                } else {
                    $self->log->error("invalid time slice found:");
                    $self->log->dump(error => $timeslice);
                }
            } else {
                $self->log->notice(
                    "time period $timeslice->{type} does not matched -",
                    "$timeslice->{timeslice} -",
                    $timeslice->{timezone},
                );
            }
        }

        if ($send_all) {
            return { sms => 1, mail => 1 };
        }

        if ($send_sms && $send_mail) {
            return { sms => 1, mail => 1 };
        }

        if ($send_sms) {
            return { sms => 1, mail => 0 };
        }

        if ($send_mail) {
            return { sms => 0, mail => 1 };
        }

        $self->log->notice("no time periods matched");
    } else {
        $self->log->notice("no time periods configured for contact $contact_id $contact_name");
    }

    return { sms => 0, mail => 0 };
}

sub update_host_status {
    my $self = shift;
    my $host_id = $self->host->{id};
    my $curstat = $self->host->{status};
    my $states = $self->db->get_service_states($host_id);
    my $status = "OK";

    foreach my $s (@$states) {
        if ($self->statbyprio->{$s->{status}} > $self->statbyprio->{$status}) {
            $status = $s->{status};
        }
    }

    $self->log->notice("update host status to $status");

    my %update = (status => $status);

    if (!$self->{set_next_check}) {
        $update{last_check} = $self->etime;

        if ($self->request->{agent_id} eq "localhost") {
            $update{facts} = $self->json->encode($self->request->{facts});
        }
    }

    if (($status eq "OK" && $curstat ne "OK") || ($status ne "OK" && $curstat eq "OK")) {
        $update{status_since} = $self->etime;
    }

    $self->db->update_host_status($host_id => \%update);
}

sub store_stats {
    my ($self, $data) = @_;
    my ($plugin_def, $plugin_stat);
    my $host_id = $self->host->{id};
    my $services = $self->host_services;

    $self->log->info("store statistics");

    foreach my $service_id (keys %$data) {
        # If a plugin name is not set then
        # no statistics are expected.
        next unless $services->{$service_id}->{plugin_id};

        # Request the plugin data first if its really necessary.
        if (!defined $plugin_def) {
            $plugin_def = $self->db->get_plugin;
            $plugin_stat = $self->db->get_plugin_stats;
        }

        # n_service = new service data
        # c_service = current service data
        my $n_service = $data->{$service_id};
        my $c_service = $services->{$service_id};
        my $stats = $n_service->{stats};
        my $plugin_id = $c_service->{plugin_id};
        my $service_id = $c_service->{id};
        my $p_def = $plugin_def->{$plugin_id};
        my $p_stat = $plugin_stat->{$plugin_id};

        #if ($n_service->{result} && ref $n_service->{result} && !$self->attempt_max_reached->{$service_id}) {
            $self->save_results(
                service_id => $service_id,
                status => $n_service->{status},
                message => $n_service->{message},
                data => $n_service->{result},
                attempts => "$c_service->{attempt_counter}/$c_service->{attempt_max}"
            );
        #}

        if (!defined $stats) {
            $self->log->info("no statistics received for service id $service_id");
            next;
        }

        if ($p_def->{datatype} eq "table") {
            my $ok = 0;

            if (ref $stats eq "ARRAY") {
                foreach my $row (@$stats) {
                    if ($self->validate_stats($row, $p_stat, $c_service)) {
                        $ok++;
                    }
                }

                if ($ok > 0 && $ok == scalar @$stats) {
                    $self->save_stats(
                        service_id => $service_id,
                        plugin_id => $plugin_id,
                        data => $stats
                    );
                }
            } else {
                $self->log->info("invalid statistic format received for service id $service_id");
                delete $n_service->{stats};
            }

            next;
        }

        # Invalid statistic format
        if (ref $stats ne "HASH") {
            $self->log->info("invalid statistic format received for service id $service_id");
            delete $n_service->{stats};
            next;
        }

        # Check if the statistics are stored into a hash reference.
        if (!scalar keys %$stats) {
            $self->log->info("no statistics received for service id $service_id");
            delete $n_service->{stats};
            next;
        }

        # Does the plugin exists? We need some data to validate it...
        if (!$p_def) {
            $self->log->warning("unknown plugin_id '$plugin_id' configured for service id $service_id");
            delete $n_service->{stats};
            next;
        }

        my ($anykey) = keys %$stats;

        if ($p_def->{subkey} || ref $stats->{$anykey} eq "HASH") {
            my $subkeys = join(",", sort keys %$stats);

            if (!$c_service->{subkeys} || $c_service->{subkeys} ne $subkeys) {
                $self->db->save_service_status($service_id, { subkeys => $subkeys });
            }

            foreach my $subvalue (keys %$stats) {
                if ($subvalue !~ m!^[a-zA-Z_0-9\-\.\:/]+\z!) {
                    $self->log->error("invalid subkey '$subvalue' for plugin_id '$plugin_id'");
                    last;
                }
                if ($self->validate_stats($stats->{$subvalue}, $p_stat, $c_service)) {
                    $self->save_stats(
                        subkey => $subvalue,
                        service_id => $service_id,
                        plugin_id => $plugin_id,
                        data => $stats->{$subvalue}
                    );
                }
            }
        } elsif ($self->validate_stats($stats, $p_stat, $c_service)) {
            if ($c_service->{subkeys}) {
                $self->db->save_service_status($service_id, { subkeys => "" });
            }
            $self->save_stats(
                service_id => $service_id,
                plugin_id => $plugin_id,
                data => $stats
            );
        }
    }
}

sub rest_post {
    my $self = shift;
    my %request = @_;

    if (!$self->rest->post(@_)) {
        $self->log->error($self->rest->errstr);
        $self->tlog->log(message => $self->json->encode(\%request) ."\n");
    }
}

sub validate_stats {
    my ($self, $stats, $plugin, $c_service) = @_;
    my $host_id = $self->host->{id};

    foreach my $key (keys %$stats) {
        if (!exists $plugin->{$key}) {
            delete $stats->{$key};
            next;
        }

        my $value  = $stats->{$key};
        my $type   = $plugin->{$key}->{datatype};
        my $substr = $plugin->{$key}->{substr};
        my $regex  = $plugin->{$key}->{regex};
        my $sucess = 0;

        if (defined $substr && length($substr) && $substr > 0 && length($value) > $substr) {
            $value = substr($value, 0, $substr);
            $stats->{$key} = $value;
        }

        if ($value =~ /^0+(?:\.0+){0,1}\z/) {
            next;
        } elsif ($type eq "smallint") {
            if ($value =~ /^-{0,1}\d+\z/ && $value >= $self->min_smallint && $value <= $self->max_smallint) {
                next;
            }
        } elsif ($type eq "integer") {
            if ($value =~ /^-{0,1}\d+\z/ && $value >= $self->min_int && $value <= $self->max_int) {
                next;
            }
        } elsif ($type eq "bigint") {
            if ($value =~ /^-{0,1}\d+\z/ && $value >= $self->min_bigint && $value <= $self->max_bigint) {
                next;
            }
        } elsif ($type eq "float") {
            if ($value =~ /^-{0,1}\d+(?:\.\d+){0,1}\z/) {
                if ($value >= $self->min_m_float && $value <= $self->max_m_float) {
                    next;
                } elsif ($value >= $self->min_p_float && $value <= $self->max_p_float) {
                    next;
                }
            }
        } elsif ($type =~ /^varchar\((\d+)\)\z/) {
            if (length($value) <= $1) {
                next;
            }
        } elsif (defined $regex && length($regex) && $value =~ /$regex/) {
            next;
        } else {
            die "no datatype set: type($type) key($key) plugin_id($c_service->{plugin_id}) host_id($host_id)";
        }

        $self->log->warning(
            "invalid value: datatype($type) key($key) value($value) plugin_id($c_service->{plugin_id})",
            "service($c_service->{id}) host_id($host_id)",
        );

        return undef;
    }

    foreach my $key (keys %$plugin) {
        if (!exists $stats->{$key}) {
            if (defined $plugin->{$key}->{default} && length($plugin->{$key}->{default})) {
                $stats->{$key} = $plugin->{$key}->{default};
            } else {
                $stats->{$key} = 0;
            }
        }
    }

    return 1;
}

sub send_sms {
    my $self  = shift;

    if (!scalar keys %{$self->{sms}}) {
        return 1;
    }

    if ($self->maintenance) {
        $self->log->alert("server runs in maintenance mode, unable to send sms");
        return 1;
    }

    my $host = $self->host;
    my $param = $self->config->{smsgateway};
    my $mail = $self->config->{email};
    my %service_id = ();

    if (!$param->{command}) {
        $self->log->notice("sms disabled");
        return 1;
    }

    foreach my $sms_to (keys %{ $self->{sms} }) {
        my $message = "$host->{hostname} $host->{ipaddr}";
        my $sms = $self->{sms}->{$sms_to};
        my (@id, $redirect);

        # Check here the sms_count again because if more than
        # one contact is configured then the sms counter
        # increases with each sms that is send.
        if ($host->{sms_count} >= $host->{max_sms}) {
            $self->log->notice("no more sms available - $host->{sms_count}/$host->{max_sms}");
            last;
        }

        if ($host->{available_sms_to_low}) {
            $message .= " [$host->{sms_count}/$host->{max_sms} SMS USED]";
            $host->{sms_count}++;
        }

        if (@$sms == 1) {
            $sms = shift @$sms;
            $message .= " - $sms->{service} $sms->{status} - $sms->{message}";
            push @id, $sms;
            $redirect = $sms->{redirect};
        } else {
            my (%status, @message, @service);

            foreach my $sms (@$sms) {
                $status{ $sms->{status} }++;
                push @id, $sms;
                push @service, $sms->{service};

                if ($sms->{redirect}) {
                    $redirect = $sms->{redirect};
                }
            }

            foreach my $s (qw/INFO UNKNOWN CRITICAL WARNING OK/) {
                if (exists $status{$s}) {
                    push @message, "$s($status{$s})";
                }
            }

            $message .= " - " . join(" ", @message);
            $message .= " - " . join(", ", @service);
        }

        if ($redirect) {
            $message = "RAD: $message";
        }

        if (length($message) > 160) {
            $message = substr($message, 0, 157) . "...";
        }

        my $qm = uri_escape($message);
        my ($command, $response);
        my $route = $self->company->{sms_route} || "gold";
        $command = $param->{command};
        $response = $param->{response};
        $command =~ s/<route>/$route/;
        $command =~ s/<to>/$sms_to/;
        $command =~ s/<message>/$qm/;
        $command =~ s/%TO%/$sms_to/;
        $command =~ s/%MESSAGE%/$qm/;
        $command = "$command 2>&1";

        $self->log->notice("send sms to $sms_to: $message");
        $self->log->notice($command);

        my $output;
        eval {
            local $SIG{__DIE__} = sub { alarm(0) };
            local $SIG{ALRM} = sub { die "timeout" };
            alarm(15);
            $output = qx{$command};
            alarm(0);
        };

        if ($@) {
            $self->log->error("unable to send sms to $sms_to - $@");
        } elsif (defined $response && $output =~ /$response/) {
            $self->log->notice("sms successfully send");

            $self->db->create_send_sms(
                $self->etime,
                $host->{id},
                $self->company->{id},
                $sms_to,
                $message
            );

            # Update "last_sms" first if send was successful,
            # but only if the status is not OK
            foreach my $id (@id) {
                if ($id->{status} ne "OK") {
                    $service_id{$id->{service_id}}++;
                }
            }

            # Send this notification as mail to BCC
            if ($mail->{mail_bcc}) {
                MIME::Lite->new(
                    From => $mail->{from},
                    To => $mail->{bcc},
                    Subject => "*** SEND TO $sms_to FOR $host->{hostname} ($host->{ipaddr}) ***\n",
                    Type => "TEXT",
                    Data => $message,
                )->send("sendmail", "$mail->{sendmail}");
            }
        } else {
            $self->log->error("error send sms to $sms_to: $output");
        }
    }

    foreach my $id (keys %service_id) {
        $self->log->notice("update last_sms to", $self->etime);
        $self->db->save_service_status($id, { last_sms => $self->etime, last_sms_time => $self->etime });
    }
}

sub send_mails {
    my $self = shift;

    if (!scalar keys %{$self->{mails}}) {
        return 1;
    }

    if ($self->maintenance) {
        $self->log->alert("server runs in maintenance mode, unable to send mail");
        return 1;
    }

    my $host = $self->host;
    my $param = $self->config->{email};
    my $hostname = $self->config->{hostname};
    my (%service_id, @recipients);

    foreach my $mail_to (keys %{ $self->{mails} }) {
        my $mails = $self->{mails}->{$mail_to};
        my $subject = $param->{subject};
        my (%status, $status, $redirect, @id);

        my $message = "*** Status for host $host->{hostname} ($host->{ipaddr}) at ". $self->stime ." ***\n\n";
        $message .= "https://$hostname/#monitoring/hosts/$host->{id}\n";

        $subject =~ s/%a/$host->{ipaddr}/;
        $subject =~ s/%h/$host->{hostname}/;

        if ($host->{description}) {
            $message .= "$host->{description}\n";
        }

        if ($host->{comment}) {
            $message .= "$host->{comment}\n";
        }

        if ($host->{available_sms_to_low}) {
            $message .= "\n=== WARNING ===\n\n";
            $message .= "$host->{sms_count}/$host->{max_sms} SMS used\n";
            $message .= "Please increase the maximal allowed SMS per month!\n";
        }

        $message .= "\n";

        foreach my $m (@$mails) {
            push @id, $m;
            $status{ $m->{status} }++;
            $message .= "---\n";
            $message .= "Service: $m->{service}\n";
            $message .= "Status: $m->{status}\n";
            $message .= "Message: $m->{message}\n";

            if ($m->{description}) {
                $message .= "Description: $m->{description}\n";
            }

            if ($m->{comment}) {
                $message .= "Comment:     $m->{comment}\n";
            }

            if (defined $m->{escalation}) {
                $message .= "Level of escalation: $m->{escalation}\n";
            }

            if ($m->{redirect}) {
                $redirect = 1;
            }
        }

        foreach my $s (qw/OK WARNING CRITICAL UNKNOWN INFO/) {
            if ($status{$s}) {
                if ($status) {
                    $status .= " $s($status{$s})";
                } else {
                    $status = "$s($status{$s})";
                }
            }
        }

        $subject =~ s/%s/$status/;

        if ($redirect) {
            $subject = "RAD: $subject";
        }

        my %email = (
            From => $param->{from},
            To => $mail_to,
            Subject => $subject,
            Type => "TEXT",
            Data => $message,
        );

        if ($param->{bcc}) {
            $email{Bcc} = $param->{bcc};
        }

        my $mail = MIME::Lite->new(%email);
        $mail->attr("content-type.charset" => "UTF8");
        $mail->send("sendmail", $param->{sendmail})
            or do { 
                $self->log->error("unable to send email to $mail_to");
                next;
            };

        my $length = length($message);
        $self->log->notice("send mail to $mail_to, length $length bytes");
        $self->log->debug("mail text:");
        $self->log->debug($message);

        if (length($subject) > 200) {
            $subject = substr($subject, 0, 197) . "...";
        }

        if (length($mail_to) > 100) {
            $mail_to = substr($mail_to, 0, 97) . "...";
        }

        $self->db->create_send_mail(
            $self->etime,
            $host->{id},
            $self->company->{id},
            $mail_to,
            $subject,
            $message,
        );

        # Update "last_mail" first if sendmail was successful,
        # but only if the status is not OK
        foreach my $id (@id) {
            if ($id->{status} ne "OK") {
                $service_id{$id->{service_id}}++;
            }
        }
    }

    foreach my $id (keys %service_id) {
        $self->log->notice("update last mail to", $self->etime, "for service $id");
        $self->db->save_service_status($id, { last_mail => $self->etime, last_mail_time => $self->etime });
    }
}

sub save_mail {
    my ($self, %mail) = @_;
    my $mails = $self->{mails};
    my $to = delete $mail{mail_to};

    if ($self->log->is_debug) {
        $self->log->debug("saved mail:");
        $self->log->dump(debug => \%mail);
    }

    push @{$mails->{$to}}, \%mail;
}

sub save_sms {
    my ($self, %sms) = @_;
    my $sms = $self->{sms};
    my $to = delete $sms{sms_to};

    $to =~ s/^\+/00/;

    if ($self->log->is_debug) {
        $self->log->debug("saved sms:");
        $self->log->dump(debug => \%sms);
    }

    push @{$sms->{$to}}, \%sms;
}

sub get_service_flaps_by_time {
    my ($self, $host_id, $service_id, $from_time, $to_time) = @_;

    my @indices = $self->get_indices($from_time, $to_time);
    my $index = join(",", @indices);

    if (!$index) {
        $self->log->error("unable to get elasticsearch indices");
        return 0;
    }

    $from_time .= "000";
    $to_time .= "000";

    my @query = (
        path => "/$index/event/_search?routing=$host_id",
        data => {
            filter => {
                and => [
                    { term => { service_id => $service_id } },
                    { range => { time => { from => $from_time, to => $to_time } } }
                ]
            },
            size => 200
        }
    );

    my $count = 0;
    my $result = $self->rest->get(@query);

    if ($result && defined $result->{hits}->{total}) {
        foreach my $row (@{$result->{hits}->{hits}}) {
            my $source = $row->{_source};
            if (defined $source->{status} && defined $source->{last_status} && $source->{status} ne $source->{last_status}) {
                $count++;
            }
        }
    }

    return $count;
}

sub get_indices {
    my ($self, $from, $to) = @_;

    my $result = $self->rest->get(path => "_aliases");
    my @indices;

    if ($from && $to) {
        my $from_time = $self->get_year_month($from);
        my $to_time = $self->get_year_month($to);

        foreach my $index (sort keys %$result) {
            if ($index =~ /^bloonix\-(\d\d\d\d)\-(\d\d)\z/) {
                my $index_time = "$1$2";

                if ($index_time >= $from_time && $index_time <= $to_time) {
                    push @indices, $index;
                }
            }
        }
    }  else {
        @indices = sort keys %$result;
    }

    return wantarray ? @indices : \@indices;
}

sub update_agent_version {
    my ($self, $services) = @_;
    my @ids;

    foreach my $service (@$services) {
        if ($self->request->{version} && $service->{agent_version} ne $self->request->{version}) {
            push @ids, $service->{service_id};
        }
    }

    if (@ids) {
        $self->db->update_agent_version($self->request->{version}, \@ids);
    }
}

sub get_year_month {
    my ($self, $time) = @_;

    my ($year, $month) = (localtime($time))[5,4];
    $year += 1900;
    $month = sprintf("%02d", $month + 1);

    return "$year$month";
}

sub set_time {
    my $self = shift;
    my ($mtime, $etime, $year, $month);

    $mtime = sprintf("%.3f", Time::HiRes::gettimeofday());
    $mtime =~ s/\.//;
    $etime = $mtime;
    $etime =~ s/\d\d\d\z//;
    ($year, $month) = (localtime($etime))[5,4];
    $year += 1900;
    $month = sprintf("%02d", $month + 1);

    $self->mtime($mtime);
    $self->etime($etime);
    $self->stime($self->timestamp($etime));
    $self->es_index("bloonix-$year-$month");
}

sub timestamp {
    my ($self, $time) = @_;
    $time ||= time;

    my @time  = (localtime($time))[reverse 0..5];
    $time[0] += 1900;
    $time[1] += 1;

    return sprintf "%04d-%02d-%02d %02d:%02d:%02d", @time[0..5];
}

sub year_month_stamp {
    my $self = shift;
    my $time = $self->timestamp(@_);
    return do { $time =~ /^(\d+\-\d+)/; $1 };
}

sub response {
    my ($self, $data) = @_;
    my $pretty = $self->cgi->param("pretty");

    if ($pretty) {
        $self->json->pretty(1);
    }

    $data = $self->json->encode($data);

    if ($pretty) {
        $self->json->pretty(0);
    }

    print "Content-Type: text/plain\n\n";
    print $data;

    $self->fcgi->finish;
}

1;
