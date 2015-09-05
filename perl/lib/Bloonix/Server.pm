package Bloonix::Server;

use strict;
use warnings;
use JSON;
use IO::Select;
use Math::BigFloat;
use MIME::Lite;
use POSIX qw(getgid getuid setgid setuid);
use Time::HiRes qw();
use URI::Escape qw();

use Log::Handler;
use Log::Handler::Output::File;
Log::Handler->create_logger("bloonix")->set_pattern("%X", "X", "n/a"); # client ip
Log::Handler->get_logger("bloonix")->set_pattern("%Y", "Y", "n/a"); # host id

use Bloonix::HangUp;
use Bloonix::FCGI;
use Bloonix::IO::SIPC;
use Bloonix::ProcManager;
use Bloonix::Server::Validate;
use Bloonix::Server::Database;
use Bloonix::Timeperiod;
use Bloonix::REST;

use base qw/Bloonix::Accessor/;
__PACKAGE__->mk_accessors(qw/config log tlog ipc db done rest json proc proc_helper fcgi cgi sipc client peerhost select/);
__PACKAGE__->mk_accessors(qw/host_services host_downtime service_downtime dependencies service_has_active_dependency/);
__PACKAGE__->mk_accessors(qw/host stime etime mtime company request request_type host_down whoami runtime max_sms_reached sms_enabled/);
__PACKAGE__->mk_accessors(qw/force_timed_event es_index maintenance locations plugin plugin_def plugin_stat/);
__PACKAGE__->mk_accessors(qw/service_status service_status_duration service_id c_service n_service c_status n_status service_interval service_timeout/);
__PACKAGE__->mk_accessors(qw/min_smallint max_smallint min_int max_int min_bigint max_bigint/);
__PACKAGE__->mk_accessors(qw/min_m_float max_m_float min_p_float max_p_float/);
__PACKAGE__->mk_array_accessors(qw/event_tags/);
__PACKAGE__->mk_hash_accessors(qw/stat_by_prio attempt_max_reached/);

our $VERSION = "0.37";

sub run {
    my $class = shift;
    my $opts = Bloonix::Server::Validate->argv(@_);
    my $self = bless $opts, $class;

    $self->init;

    if ($self->config->{fcgi_server}) {
        return $self->run_deprecated;
    }

    $self->sipc(Bloonix::IO::SIPC->new($self->config->{tcp_server}));
    $self->proc(Bloonix::ProcManager->new($self->config->{proc_manager}));

    while (!$self->proc->done) {
        eval {
            while (!$self->proc->done) {
                $self->proc->set_status_waiting;
                $self->process_tcp_request;
            }
        };
    }
}

sub run_deprecated {
    my $self = shift;

    $self->log->warning(
        "DEPRECATED WARNING:",
        "The usage of the parameter 'port' and 'listen' is deprecated",
        "in the section proc_manager! Please use the section tcp_server",
        "instead and upgrade the bloonix-agents on all your machines.",
        "You can find more information in the configuration documentation",
        "of the bloonix server"
    );

    $self->select(IO::Select->new);
    $self->fcgi(Bloonix::FCGI->new($self->config->{fcgi_server}));
    $self->select->add($self->fcgi->sock);
    $self->sipc(Bloonix::IO::SIPC->new($self->config->{tcp_server}));
    $self->select->add($self->sipc->sock);
    $self->proc(Bloonix::ProcManager->new($self->config->{proc_manager}));

    while (!$self->proc->done) {
        eval {
            $self->proc->set_status_waiting;
            my @ready = $self->select->can_read;

            foreach my $fh (@ready) {
                next unless $fh;

                if ($fh == $self->sipc->sock) {
                    $self->process_tcp_request;
                } elsif ($fh == $self->fcgi->sock) {
                    $self->process_http_request(0.5);
                }
            }
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
    $self->stat_by_prio->set(qw(OK 0 INFO 5 WARNING 10 CRITICAL 20 UNKNOWN 30));
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
    $SIG{__DIE__} = sub { $self->log->trace(fatal => @_) };
    $SIG{__WARN__} = sub { $self->log->warning(@_) };
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

###############################################################################################
# Protocol:
#
#   REQ (request): a request has an action (gimme data)
#   RES (response): the response has a status (ok, err) and a message or data
#
#   ping:
#
#       REQ: { "action": "ping" }
#       RES: { "status": "ok", "message": "pong" }
#
#   hostcheck:
#
#       REQ: { "action": "hostcheck", "hostkey": "secret" }
#       RES: { "status": "ok", "message": "host $host_id exists" }
#       RES: { "status": "err", "message": "host $host_id does not exists" }
#
#   server-status:
#
#       REQ: { "action": "server-status", "authkey": "secret", "pretty": "true", "plain": "true" }
#       RES: access denied
#       RES: or plain statistic data
#       RES: or a json string with the statistic data
#
#   get-services:
#
#       REQ: { "action": "get-services", "host_id": "12345", "agent_id": "remote", ... }
#       RES: { "status": "err", "message": "access denied" }
#       RES: { "status": "ok", "data": { "services": {}, "interval": $interval }
#
#   post-service-data:
#
#       REQ: { "action": "post-service-data", "host_id": "12345", ... }
#       RES: { "status": "err", "message": "access denied" }
#       RES: { "status": "ok", "message": "processing data" }
#
###############################################################################################

sub process_tcp_request {
    my ($self, $timeout) = @_;
    $timeout ||= 0;

    $self->log->info("wait for tcp connection");
    my $client = $self->sipc->accept($timeout) or return;

    $self->proc->set_status_reading;
    my $request = $client->recv;

    if (!$request || ref $request ne "HASH" || !$request->{action}) {
        return;
    }

    $self->proc->set_status_processing(
        client  => $client->sock->peerhost,
        request => join(" ", $request->{action})
    );

    $self->log->info("process tcp request");
    $self->peerhost($client->sock->peerhost);
    $self->client($client);
    $self->request_type("tcp");
    $self->request($request);
    $self->pre_process_request;
    $self->process_request;
    $self->post_process_request;
}

# The http method is deprecated. For backward compability the
# http request is converted into a tcp request.
sub process_http_request {
    my $self = shift;

    $self->log->info("wait for http connection");
    $self->fcgi->accept(0.5) or return;

    $self->proc->set_status_reading;
    my $cgi = $self->fcgi->get_new_cgi or return;

    $self->proc->set_status_processing(
        client  => $cgi->remote_addr,
        request => join(" ", $cgi->request_method, $cgi->request_uri)
    );

    $self->log->info("process http request");
    $self->peerhost($cgi->remote_addr);
    $self->cgi($cgi);
    $self->request_type("http");
    $self->pre_process_request;

    $self->request({});

    if ($self->cgi->path_info eq "/ping") {
        $self->request->{action} = "ping";
    } elsif ($self->cgi->path_info =~ m!^/hostcheck/(.+)\z!) {
        $self->request->{action} = "hostcheck";
        $self->request->{hostkey} = $1;
    } elsif ($self->cgi->path_info eq "/server-status") {
        $self->request->{action} = "server-status";
        $self->request->{authkey} = $self->cgi->param("authkey") || 0;
        $self->request->{pretty} = defined $self->cgi->param("pretty") ? 1 : 0;
        $self->request->{plain} = defined $self->cgi->param("plain") ? 1 : 0;
    } else {
        if (!$self->cgi->postdata) {
            $self->log->warning("no post data received");
            $self->response({ status => "err", message => "no post data received" });
            return undef;
        }

        my $data = $self->cgi->jsondata // $self->json->decode($self->cgi->postdata);

        foreach my $key (keys %$data) {
            $self->request->{$key} = $data->{$key};
        }

        if ($self->cgi->request_method eq "GET") {
            $self->request->{action} = "get-services";
        } elsif ($self->cgi->request_method eq "POST") {
            $self->request->{action} = "post-service-data";
        }
    }

    $self->process_request;
    $self->post_process_request;

    if ($self->host) {
        $self->log->warning("\nDEPRECATED", $self->host->{id}, $self->host->{hostname});
    }
}

sub pre_process_request {
    my $self = shift;
    my $time = sprintf("%.3f", Time::HiRes::gettimeofday());
    $self->runtime($time);
    $ENV{TZ} = $self->config->{timezone};
    $self->log->set_pattern("%X", "X", $self->peerhost);
    $self->log->set_pattern("%Y", "Y", "n/a");
    $self->db->reconnect;
    $self->set_time;
}

sub process_request {
    my $self = shift;

    $self->host(undef);

    if ($self->request->{action} eq "get-services" || $self->request->{action} eq "post-service-data") {
        $self->check_request or return;

        if ($self->request->{action} eq "get-services") {
            $self->get_locations;
            $self->process_get_services;
        } elsif ($self->request->{action} eq "post-service-data") {
            $self->process_post_service_data;
        }
    } elsif ($self->request->{action} eq "ping") {
        $self->response({ status => "ok", message => "pong" });
    } elsif ($self->request->{action} eq "hostcheck" && $self->request->{hostkey} && $self->request->{hostkey} =~ m!^(.+)\.([^\s.]+)\z!) {
        $self->process_host_check($1, $2);
    } elsif ($self->request->{action} eq "server-status") {
        $self->process_server_status;
    }
}

sub post_process_request {
    my $self = shift;
    my $time = sprintf("%.3f", Time::HiRes::gettimeofday() - $self->runtime);
    $self->log->notice("request finished (${time}s)");
}

sub process_host_check {
    my ($self, $host_id, $password) = @_;

    my $host = $self->db->get_host_by_auth(
        $host_id,
        $password,
        $self->peerhost,
        $self->config->{allow_from}
    );

    if ($host) {
        $self->log->warning("hostcheck from", $self->peerhost, "for host $host_id was successful");
        $self->response({ status => "ok", message => "host $host_id exists" });
    } else {
        $self->log->error("hostcheck from", $self->peerhost, "for host $host_id was not successful");
        $self->response({ status => "err", message => "host $host_id does not exists" });
    }
}

sub process_server_status {
    my $self = shift;

    my $server_status = $self->config->{server_status};
    my $allow_from = $server_status->{allow_from};
    my $addr = $self->peerhost;
    my $authkey = $self->request->{authkey} || 0;
    my $plain = $self->request->{plain} || 0;
    my $pretty = $self->request->{pretty} || 0;

    if ($allow_from->{all} || $allow_from->{$addr} || ($server_status->{authkey} && $server_status->{authkey} eq $authkey)) {
        $self->log->info("server status request from $addr - access allowed");
        $self->proc->set_status_sending;

        if ($plain) {
            $self->response({ status => "ok", data => $self->proc->get_plain_server_status, plain => 1 });
        } else {
            $self->response({ status => "ok", data => $self->proc->get_raw_server_status });
        }
    } else {
        $self->response({ status => "err", message => "access denied" });
    }
}

sub check_request {
    my $self = shift;
    my $request;

    $self->log->notice("check authorization");

    eval {
        local $SIG{__DIE__} = "DEFAULT";
        $request = Bloonix::Server::Validate->request($self->request);
    };

    if ($@) {
        $self->log->error($@);
        $self->response({ status => "err", message => "access denied" });
        return undef;
    }

    $self->whoami($request->{whoami} // "n/a");
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

    return 1;
}

sub get_locations {
    my $self = shift;

    $self->locations($self->db->get_locations);
}

sub process_get_services {
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

            if ($service->{location_options} && scalar keys %{$self->locations}) {
                my $location_options = $self->json->decode($service->{location_options});

                if (scalar keys %$location_options && $location_options->{check_type} ne "default") {
                    $service->{location_options} = {
                        check_type => $location_options->{check_type},
                        concurrency => $location_options->{concurrency} || 3,
                        locations => []
                    };

                    foreach my $location (@{$location_options->{locations}}) {
                        if ($self->locations->{$location}) {
                            push @{$service->{location_options}->{locations}}, $self->locations->{$location};
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
        my $counter = "$service->{attempt_counter}/$service->{attempt_max}";
        $service->{retry_interval} ||= $self->host->{retry_interval};
        $service->{interval} ||= $self->host->{interval};
        $service->{timeout} ||= $self->host->{timeout};

        if ($service->{force_check}) {
            $self->log->info("service $service->{service_id} check forced");
            $self->db->update_force_check($service->{service_id}, 0);
            push @services, $service;
        } elsif ($service->{last_check} - 30 > $self->etime) { # - 15 to prevent race conditions
            $self->log->warning("last_check is higher than current time, ntp issue?");
            push @services, $service;
        } elsif ($service->{status} eq "OK") {
            if ($service->{last_check} + $service->{interval} <= $self->etime) {
                $self->log->info("service $service->{service_id} is ready");
                push @services, $service;
            }
        } elsif ($service->{attempt_counter} < $service->{attempt_max}) {
            if ($service->{last_check} + $service->{retry_interval} <= $self->etime) {
                $self->log->info("service $service->{service_id} forced to be ready (attempts $counter retry $service->{retry_interval}s)");
                push @services, $service;
            }
        } elsif ($service->{retry_interval} < 60) {
            if ($service->{last_check} + 60 <= $self->etime) {
                $self->log->info("service $service->{service_id} forced to be ready (attempts $counter retry 60s fixed)");
                push @services, $service;
            }
        } elsif ($service->{last_check} + $service->{retry_interval} <= $self->etime) {
            $self->log->info("service $service->{service_id} forced to be ready (attempts $counter retry $service->{retry_interval})");
            push @services, $service;
        }
    }

    return \@services;
}

sub process_post_service_data {
    my $self = shift;
    $self->log->notice("send data for host id", $self->request->{host_id});
    $self->response({ status => "ok", message => "processing data" });
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
        return 1;
    }

    # Clear the message buffer
    $self->{notifications} = {};

    # Clear and reuse the object buffers
    $self->host_downtime(undef);
    $self->service_downtime(undef);
    $self->dependencies({});
    $self->attempt_max_reached->reset;
    $self->get_downtimes;
    $self->host_services($host_services);
    $self->check_host_alive_status($data);
    $self->maintenance($self->db->get_maintenance);
    $self->max_sms_reached(undef);
    $self->plugin_def(undef);
    $self->plugin_stat(undef);

    # Validate, check and store the service data
    $self->validate_data($data) or return undef;
    $self->check_services($data);
    $self->update_host_status;
    $self->send_notifications;
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

    if (ref $data ne "HASH") {
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

sub check_host_alive_status {
    my ($self, $data) = @_;
    my $services = $self->host_services;
    my $affected_services = scalar keys %$services;

    $self->host_down(0);

    foreach my $service_id (keys %$services) {
        if ($services->{$service_id}->{host_alive_check} == 1) {
            if (exists $data->{$service_id}) {
                if ($data->{$service_id}->{status} =~ /CRITICAL|UNKNOWN/) {
                    $self->host_down(1);
                    $data->{$service_id}->{message} = join(" ",
                        "[HOST ALIVE STATUS IS",
                        $data->{$service_id}->{status},
                        "WITH $affected_services AFFECTED SERVICES]",
                        $data->{$service_id}->{message},
                    );
                }
            } elsif ($services->{$service_id}->{status} =~ /CRITICAL|UNKNOWN/) {
                $self->host_down(1);
            }
        }
    }
}

sub check_services {
    my ($self, $data) = @_;

    $self->log->notice("check the status of services");

    CHECK:
    foreach my $service_id (keys %$data) {
        $self->event_tags->clear;
        $self->force_timed_event(0);
        $self->service_has_active_dependency(0);
        $self->service_id($service_id);
        $self->n_service($data->{$service_id});
        $self->n_status($self->n_service->{status});
        $self->c_service($self->host_services->{$service_id});
        $self->c_status($self->c_service->{status});
        $self->service_interval($self->c_service->{interval} || $self->host->{interval});
        $self->service_timeout($self->c_service->{timeout} || $self->host->{timeout});
        $self->service_status_duration($self->etime - $self->c_service->{status_since});
        $self->check_last_event;

        $self->service_status({
            status => $self->n_service->{status},
            message => $self->n_service->{message},
            last_check => $self->etime
        });

        if ($self->c_service->{force_event}) {
            $self->service_status->{force_event} = 0;
        }

        $self->log->notice(
            "start checking",
            "service id", $service_id,
            "command", $self->c_service->{command},
            "status", $self->n_service->{status}
        );

        next CHECK
            if $self->check_srvchk_passive_check
            || $self->check_srvchk_next_timeout
            || $self->check_if_host_or_service_not_active
            || $self->check_if_downtime_is_active
            || $self->check_if_srvchk_remote_error;

        $self->prepare_service_data;
        $self->check_service_message_tags($self->n_service->{message});
        $self->check_service_notification_status;
        $self->attempt_max_reached->set($service_id => 0);
        $self->check_nok_service_status;
        $self->check_volatile_service_status;
        $self->reset_service_parameter;
        $self->check_service_attempt_counter;
        $self->check_if_service_is_flapping;
        $self->check_highest_attempt_status;
        $self->check_notifications;
        $self->set_service_next_check;
        $self->store_stats;
        $self->save_service_event;
        $self->update_service_status($self->service_status);
    }
}

sub check_notifications {
    my $self = shift;

    if ($self->pre_check_notification_status) {
        return;
    }

    if ($self->check_notification_interval) {
        return;
    }

    $self->check_if_sms_are_enabled;
    $self->save_notifications_by_contact;
}

sub check_if_sms_are_enabled {
    my $self = shift;

    $self->sms_enabled(1);

    if ($self->company->{sms_enabled} == 0) {
        $self->log->notice("send_sms disabled by company, no sms send");
        $self->sms_enabled(0);
    } elsif ($self->check_if_max_sms_reached) {
        $self->log->notice("max sms reached, no sms send");
        $self->sms_enabled(0);
    }
}

sub pre_check_notification_status {
    my $self = shift;

    # Do nothing if the status doesn't changed
    if ($self->n_status eq "OK" && $self->c_status eq "OK") {
        return 1;
    }

    # If the new status is OK and highest_attempt_status is
    # OK too then it's not necessary to send a notification.
    if ($self->n_status eq "OK" && $self->c_service->{highest_attempt_status} eq "OK") {
        return 1;
    }

    # No notification if notifications are disabled
    if ($self->host->{notification} == 0) {
        $self->log->notice("host notifications disabled");
        return 1;
    }

    if ($self->c_service->{notification} == 0) {
        $self->log->notice("service notifications disabled");
        return 1;
    }

    # No notification if the status isn't changed and the status is acknowledged
    if ($self->n_status eq $self->c_status && $self->c_service->{acknowledged} == 1) {
        $self->log->notice("service status is acknowledged");
        return 1;
    }

    if ($self->c_service->{attempt_max} == 0) {
        $self->log->notice("attempt_max = 0 = notification disabled");
        return 1;
    }

    if ($self->service_status->{flapping}) {
        $self->log->notice("service if flapping between states");
    } elsif ($self->whoami ne "srvchk" && $self->c_service->{attempt_counter} < $self->c_service->{attempt_max}) {
        $self->log->notice("attempt max not reached");
        return 1;
    }

    return 0;
}

sub check_notification_interval {
    my $self = shift;

    # last_notification_1 is the timestamps when the last notification was send.
    # last_notification_2 is the same but will be set back to 0 if the status of the service is ok.
    my $notification_interval = $self->c_service->{notification_interval} ? $self->c_service->{notification_interval} : $self->host->{notification_interval};
    my $next_notification1 = $self->c_service->{last_notification_1} + $notification_interval;
    my $next_notification2 = $self->c_service->{last_notification_2} + $notification_interval;

    $self->log->info("check if a notification must be send");
    $self->log->notice(
        last_notification_1 => $self->c_service->{last_notification_1},
        last_notification_2 => $self->c_service->{last_notification_2},
        notification_interval => $notification_interval
    );

    if ($self->service_status->{flapping} && $next_notification1 > $self->etime) {
        $self->log->notice("no notification send - service is flapping - next notification $next_notification1");
        return 1;
    }

    # If the new status is OK and the old status is not OK then the notification interval is ignored.
    if ($self->n_status ne "OK" && $next_notification2 > $self->etime) {
        $self->log->notice("no notification send - next notification $next_notification2");
        return 1;
    }

    if (
        $self->n_status ne "OK"
        && $next_notification2 > $self->etime
        && $self->stat_by_prio->get($self->n_status) <= $self->stat_by_prio->get($self->c_status)
    ) {
        # Do not send a SMS if next_time is lower then etime
        # and if the new status is lower then the current status.
        # That means: if etime is lower -> sent a SMS
        # And: if the new status is higher -> sent a SMS (maybe the status switched from WARNING to CRITICAL)
        $self->log->notice("no notification send - next notification $next_notification2");
        return 1;
    }

    $self->log->notice("possible to send a notification");
    return 0;
}

sub set_service_next_check {
    my $self = shift;

    if ($self->c_service->{passive_check}) {
        if ($self->c_service->{next_check}) {
            $self->service_status->{next_check} = 0;
        }
        if ($self->c_service->{next_timeout}) {
            $self->service_status->{next_timeout} = 0;
        }
        return;
    }

    my $interval = $self->c_service->{interval} || $self->host->{interval};
    my $timeout = $self->c_service->{timeout} || $self->host->{timeout};

    # If srvchk reports an critical status then all contacts
    # are notified immediate. For this reason it's not necessary
    # to the next timeout too early. The next timeout is forced
    # to 300 seconds because the lowest escalation time of the
    # contacts is 300 seconds. Next check remains untouched!
    $self->service_status->{next_timeout} = $interval + $timeout > 600
        ? $self->etime + 600
        : $self->etime + $interval + $timeout;

    $self->service_status->{next_check} = $self->etime + $interval;
}

sub save_notifications_by_contact {
    my $self = shift;
    my $send_sms = 1;

    my $contacts = $self->db->get_service_contacts($self->host->{id}, $self->service_id);

    if (!scalar @$contacts) {
        $self->log->notice("no contacts found for service", $self->service_id);
        return;
    }

    if ($self->check_if_service_has_a_active_dependency) {
        return;
    }

    # If the service currently switched from OK to CRITICAL
    # and attempt_max is set to 1, then status_nok_since contains
    # the timestamp since the status is OK. For this reason it's
    # necessary to set s_since to 0 if the last status of the
    # service was OK or INFO.
    my $status_duration = $self->c_status ne "OK" && $self->c_status ne "INFO"
        ? $self->etime - $self->c_service->{status_nok_since}
        : $self->etime;

    foreach my $contact (@$contacts) {
        $self->log->info("check contact $contact->{name} ($contact->{id})");

        # Check if the contact has a valid timeperiod.
        $self->log->info("check timeperiod for contact $contact->{name} ($contact->{id})");

        if ($contact->{escalation_time} && $self->c_service->{status_nok_since} + $contact->{escalation_time} > $self->etime) {
            $self->log->info("contact $contact->{name} ($contact->{id}) has a higher escalation level");
            next;
        }

        my $active_timeperiods = $self->check_contact_timeperiods($contact->{id}, $contact->{name});

        if (!scalar keys %$active_timeperiods) {
            $self->log->info("no active timeslices found for contact $contact->{name} ($contact->{id})");
            next;
        }

        my $message_services = $self->db->get_contact_message_services($contact->{id});
        my $service_status = $self->service_status->{status};

        if (!@$message_services) {
            $self->log->info("no message services configured for contact $contact->{name} ($contact->{id})");
            next;
        }

        foreach my $message_service (@$message_services) {
            if ($active_timeperiods->{$message_service->{message_service}} && $active_timeperiods->{$message_service->{message_service}} == 2) {
                $self->log->info(
                    "message service is excluded in timeperiods:",
                    $message_service->{id},
                    $message_service->{message_service},
                    $message_service->{send_to},
                    $message_service->{notification_level}
                );
                next;
            }

            if (!$active_timeperiods->{$message_service->{message_service}} && !$active_timeperiods->{all}) {
                $self->log->info(
                    "message service is not configured in timeperiods:",
                    $message_service->{id},
                    $message_service->{message_service},
                    $message_service->{send_to},
                    $message_service->{notification_level}
                );
                next;
            }

            if ($message_service->{notification_level} !~ /all|$service_status/i) {
                $self->log->info(
                    "notification level of message service does not match:",
                    $message_service->{id},
                    $message_service->{message_service},
                    $message_service->{send_to},
                    $message_service->{notification_level}
                );
                next;
            }

            if ($message_service->{enabled} == 0) {
                $self->log->info(
                    "message service not enabled:",
                    $message_service->{id},
                    $message_service->{message_service},
                    $message_service->{send_to},
                    $message_service->{notification_level}
                );
                next;
            }

            $self->log->notice(
                "save notification for",
                "service id", $self->service_id,
                "contact id", $contact->{id},
                "contact name", $contact->{name}
            );

            $self->save_notification(
                service_id => $self->service_id,
                service_name => $self->c_service->{service_name},
                status => $self->n_status,
                message_service => $message_service->{message_service},
                send_to => $message_service->{send_to},
                message => $self->service_status->{message},
                description => $self->c_service->{description},
                comment => $self->c_service->{comment},
                status_duration => $status_duration
            );
        }
    }
}

sub check_if_service_has_a_active_dependency {
    my $self = shift;

    # service_has_active_dependency
    #   0 = not checkec
    #   1 = no
    #   2 = yes

    if ($self->service_has_active_dependency == 1) {
        return 0;
    }

    if ($self->service_has_active_dependency == 2) {
        return 1;
    }

    # At first it will be checked if the service or host
    # has a dependency and if the dependency is in any
    # status that no notification must be send.
    if ($self->n_status ne "OK" && $self->dependency_is_in_true_status($self->host->{id}, $self->service_id, $self->n_status)) {
        $self->log->notice(
            "host id", $self->host->{id}, "or service id", $self->service_id, "has a",
            "dependency status that is true, skipping notification",
            "for status", $self->n_status
        );
        $self->service_status->{status_dependency_matched} = $self->etime;
        $self->service_has_active_dependency(2);
        return 1;
    }

    if ($self->n_status eq "OK" && $self->c_service->{status_dependency_matched} > 0) {
        # Do not send a notification if the new status is OK and
        # if the last notifications were not send because of a
        # service dependency.
        $self->log->notice(
            "host id", $self->host->{id}, "or service id", $self->service_id, "has a",
            "dependency status that was true, skipping notification",
            "for status", $self->n_status
        );
        $self->service_has_active_dependency(2);
        return 1;
    }

    if ($self->n_status ne "OK" && $self->c_service->{status_dependency_matched} + 60 > $self->etime) {
        # Avoid a race condition. If the service dependencies doesn't
        # match any more but the service is still in a higher status
        # than OK then a notification should send first if the last
        # dependency check is 60 seconds ago.
        $self->log->notice(
            "host id", $self->host->{id}, "or service id", $self->service_id, "has a",
            "dependency status that was true, skipping notification",
            "for status $self->n_status to avoid a race condition",
        );
        $self->service_has_active_dependency(2);
        return 1;
    }

    if ($self->c_service->{status_dependency_matched} > 0) {
        $self->service_status->{status_dependency_matched} = 0;
    }

    $self->service_has_active_dependency(1);
    return 0;
}

sub check_if_service_is_flapping {
    my $self = shift;
    my $flapping;

    # At first check if the service flaps between states.
    if ($self->c_service->{fd_enabled} == 1) {
        my $flap_count = $self->get_service_flaps_by_time(
            $self->host->{id},
            $self->service_id,
            $self->etime - $self->c_service->{fd_time_range},
            $self->etime
        );

        $self->log->notice("flap count", $self->service_id, $flap_count);

        if ($flap_count >= $self->c_service->{fd_flap_count}) {
            $self->log->notice("service", $self->service_id, "is flapping - count $flap_count");
            $self->service_status->{message} = sprintf("[SERVICE IS FLAPPING BETWEEN STATES] %s", $self->service_status->{message});
            $flapping = 1;
        }
    }

    if ($flapping) {
        $self->service_status->{flapping} = 1;
        $self->event_tags->push("flapping");
    } elsif ($self->c_service->{flapping}) {
        $self->service_status->{flapping} = 0;
    }
}

sub check_service_attempt_counter {
    my $self = shift;

    # Check if the status is WARNING, CRITICAL or UNKNOWN
    if ($self->n_status =~ /^(?:WARNING|CRITICAL|UNKNOWN)\z/) {
        if ($self->c_service->{attempt_counter} == $self->c_service->{attempt_max}) {
            $self->attempt_max_reached->set($self->service_id => 1);
        } elsif ($self->c_service->{attempt_counter} > $self->c_service->{attempt_max}) {
            $self->service_status->{attempt_counter} = $self->c_service->{attempt_max};
            $self->c_service->{attempt_counter} = $self->c_service->{attempt_max};
            $self->attempt_max_reached->set($self->service_id => 1);
        } elsif ($self->c_service->{attempt_counter} < $self->c_service->{attempt_max} && $self->c_status ne "OK") {
            $self->service_status->{attempt_counter} = 1 + $self->c_service->{attempt_counter};
            $self->c_service->{attempt_counter} = 1 + $self->c_service->{attempt_counter};
        }

        if ($self->n_status eq "WARNING") {
            if ($self->c_service->{attempt_counter} == $self->c_service->{attempt_max}) {
                if ($self->c_service->{attempt_warn2crit} == 1) {
                    $self->log->notice("attempt_max exceeded, status critical");
                    $self->n_service->{status} = $self->service_status->{status} = "CRITICAL";
                }
            }
        }
    }
}

sub reset_service_parameter {
    my $self = shift;

    # Check if the status is OK and reset some parameter
    if ($self->n_status eq "OK") {
        if ($self->c_service->{attempt_counter} > 1) {
            $self->service_status->{attempt_counter} = 1;
        }

        if ($self->c_service->{last_notification_2} > 0) {
            $self->service_status->{last_notification_2} = 0;
        }

        if ($self->c_service->{acknowledged} == 1) {
            $self->service_status->{acknowledged} = 0;
            $self->service_status->{acknowledged_comment} = "auto cleared";
        }

        if ($self->c_service->{status_dependency_matched} > 0) {
            $self->service_status->{status_dependency_matched} = 0;
        }
    }
}

sub check_highest_attempt_status {
    my $self = shift;

    # The option highest_attempt_status is used to store the highest status
    # for the last notification that was send. That means if the status is
    # not OK and attempt_max is reached then the status will be saved to
    # "highest_attempt_status". Then, if the status fall back to OK again,
    # and a high status is saved to "highest_attempt_status", it's necessary
    # to send a OK notification because the admin wants to know if all is ok.
    if (
        $self->n_status eq "OK"
        || (
            $self->n_status ne "INFO"
            && $self->c_service->{attempt_counter} >= $self->c_service->{attempt_max}
            && $self->stat_by_prio->get($self->c_service->{highest_attempt_status}) < $self->stat_by_prio->get($self->n_status)
           )
    ) {
        $self->service_status->{highest_attempt_status} = $self->n_status;
    }
}

sub check_service_message_tags {
    my $self = shift;
    my @tags;

    # set tag agent dead
    if ($self->whoami eq "srvchk") {
        $self->event_tags->push("agent dead");
    }

    # set tag timeout
    if ($self->n_service->{message} =~ /timeout|timed out/) {
        $self->event_tags->push("timeout");
    }
}

sub prepare_service_data {
    my $self = shift;

    # rename advanced_status to result
    if ($self->n_service->{advanced_status}) {
        $self->n_service->{result} = delete $self->n_service->{advanced_status};
    }

    foreach my $key (qw/result debug/) {
        if ($self->n_service->{$key}) {
            $self->service_status->{$key} = ref $self->n_service->{$key}
                ? $self->json->encode($self->n_service->{$key})
                : $self->n_service->{$key};
        } else {
            $self->service_status->{$key} = "";
        }
    }
}

sub check_nok_service_status {
    my $self = shift;

    # status_nok_since:
    #     ok = OK | INFO
    #    nok = WARNING | CRITICAL | UNKNOWN
    # status_since
    #    The time in epoch since the service is in this status
    if ($self->c_status ne $self->n_status) {
        my $cs_is_ok = $self->c_status =~ /^(OK|INFO)\z/;
        my $ns_is_ok = $self->n_status =~ /^(OK|INFO)\z/;

        if (($cs_is_ok && !$ns_is_ok) || (!$cs_is_ok && $ns_is_ok)) {
            $self->service_status->{status_nok_since} = $self->etime;
        }

        $self->service_status->{status_since} = $self->etime;
    }
}

sub check_volatile_service_status {
    my $self = shift;

    # Just some short variables
    my $is_volatile = $self->c_service->{is_volatile}; # is this a volatile status?
    my $volatile_status = $self->c_service->{volatile_status}; # has become the service volatile?
    my $volatile_retain = $self->c_service->{volatile_retain};
    my $volatile_since = $self->c_service->{volatile_since};
    my $volatile_time = $volatile_retain + $volatile_since;

    # If the status is not OK and if the volatile_status flag is not set
    if ($self->n_status =~ /^(?:WARNING|CRITICAL|UNKNOWN)\z/) {
        if ($is_volatile && !$volatile_status) {
            $self->log->info("set service in volatile status since", $self->etime);
            $self->service_status->{volatile_status} = 1;
            $self->service_status->{volatile_since} = $self->etime;
        }
    }

    # If the volatile_status flag is set and the retain time is not expired
    if ($is_volatile && $volatile_status && ($volatile_retain == 0 || $volatile_time > $self->etime)) {
        $self->log->info("unable to set the status to OK because service is in volatile status");
        $self->event_tags->push("volatile");
        $self->service_status->{volatile_status} = 1;
    }

    # Manipulate the volatile status because the status must be hold
    if ($self->service_status->{volatile_status}) {
        if ($self->stat_by_prio->get($self->n_status) < $self->stat_by_prio->get($self->c_status)) {
            $self->log->info("overwrite service status from", $self->n_status, "to volatile status", $self->c_status);
            $self->service_status->{status} = $self->c_status;
            $self->n_status($self->c_status);
        }
        $self->service_status->{message} = sprintf("[VOLATILE] %s", $self->service_status->{message});
    }

    if ($self->n_status eq "OK") {
        if ($volatile_status) {
            $self->service_status->{volatile_status} = 0;
        }

        if ($volatile_since) {
            $self->service_status->{volatile_since} = 0;
        }
    }
}

sub check_last_event {
    my $self = shift;
    my $month_now = $self->year_month_stamp;
    my $month_last_event = $self->year_month_stamp($self->c_service->{last_event});

    if ($month_now ne $month_last_event || $self->c_service->{force_event}) {
        $self->force_timed_event(1);
    }
}

sub check_if_max_sms_reached {
    my $self = shift;
    my $host = $self->host;
    my $company = $self->company;

    if (defined $self->max_sms_reached) {
        return $self->max_sms_reached;
    }

    $self->max_sms_reached(0);

    if (!defined $host->{sms_count}) {
        my $host_sms_count = $self->db->get_sms_count(host => $host->{id});
        my $company_sms_count = $self->db->get_sms_count(company => $host->{company_id});
        $host->{sms_count} = $host_sms_count->{count};
        $company->{sms_count} = $company_sms_count->{count};
    }

    if ($host->{max_sms} && $host->{sms_count} >= $host->{max_sms}) {
        $self->log->notice("reached host max_sms $host->{sms_count}/$host->{max_sms}");
        $self->max_sms_reached(1);
    } elsif ($company->{max_sms} && $company->{sms_count} >= $company->{max_sms}) {
        $self->log->notice("reached company max_sms $company->{sms_count}/$company->{max_sms}");
        $self->max_sms_reached(1);
    }

    $self->log->notice("possible to send sms");
    return $self->max_sms_reached;
}

sub check_if_sms_contingent_is_low {
    my $self = shift;
    my $host = $self->host;
    my $company = $self->company;

    if ($host->{max_sms} > 0) {
        if ($host->{sms_count} * 100 / $host->{max_sms} > 90 || $host->{max_sms} - $host->{sms_count} < 5) {
            return 1;
        }
    }

    if ($company->{max_sms} > 0) {
        if ($company->{sms_count} * 100 / $company->{max_sms} > 90 || $company->{max_sms} - $company->{sms_count} < 5) {
            return 2;
        }
    }

    return 0;
}

sub check_service_notification_status {
    my $self = shift;

    if ($self->c_service->{acknowledged} == 1) {
        $self->n_service->{message} = sprintf(
            "[ACKNOWLEDGED: %s] %s",
            $self->c_service->{acknowledged_comment} || "n/a",
            $self->n_service->{message}
        );
    }

    if ($self->host->{notification} == 0 || $self->c_service->{notification} == 0) {
        my $comment = $self->host->{notification} == 0
            ? $self->host->{notification_comment}
            : $self->c_service->{notification_comment};
        $self->n_service->{message} = sprintf(
            "[SILENCED: %s] %s",
            $comment || "n/a",
            $self->n_service->{message}
        );
    }

    if ($self->maintenance && $self->n_service->{status} ne "OK") {
        $self->n_service->{status} = "INFO";
        $self->n_service->{message} = sprintf(
            "[MAINTENANCE (true status: %s)] %s",
            $self->n_service->{status},
            $self->n_service->{message}
        );
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

    $self->service_status({
        status => "INFO",
        message => join(" ", "[INACTIVE: $comment]", $self->n_service->{message}),
        attempt_counter => 1
    });

    if ($self->n_service->{status} eq "OK" && $self->c_service->{status_dependency_matched} > 0) {
        $self->service_status->{status_dependency_matched} = 0;
    }

    # Store the new status to the events table.
    if ($self->c_service->{status} ne "INFO" || $self->force_timed_event) {
        $self->log->notice("EVENT STATUS OK SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $self->service_status->{last_event} = $self->etime;

        $self->save_event(
            status => "INFO",
            message => $self->service_status->{message},
            tags => "inactive"
        );

        if ($self->c_service->{status} ne "INFO" && $self->c_service->{status} ne "OK") {
            $self->service_status->{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $self->service_status->{status_since} = $self->etime;
        }
    }

    $self->set_service_next_check;
    $self->update_service_status($self->service_status);
    return 1;
}

sub check_if_downtime_is_active {
    my $self = shift;

    if (!$self->host_downtime && !$self->service_downtime->{$self->service_id}) {
        $self->service_status->{scheduled} = 0;
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

    $self->service_status({
        status => "INFO",
        message => join(" ", $message, $self->n_service->{message}),
        attempt_counter => 1,
        scheduled => 1
    });

    if ($self->n_service->{status} eq "OK" && $self->c_service->{status_dependency_matched} > 0) {
        $self->service_status->{status_dependency_matched} = 0;
    }

    # Store the new status to the event table.
    if ($self->c_service->{status} ne "INFO" || $self->force_timed_event) {
        $self->log->notice("EVENT STATUS INFO SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $self->service_status->{last_event} = $self->etime;

        $self->save_event(
            status => "INFO",
            message => $self->service_status->{message},
            tags => "maintenance"
        );

        if ($self->c_service->{status} ne "INFO" && $self->c_service->{status} ne "OK") {
            $self->service_status->{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $self->service_status->{status_since} = $self->etime;
        }
    }

    $self->set_service_next_check;
    $self->update_service_status($self->service_status);
    return 1;
}

sub check_srvchk_next_timeout {
    my $self = shift;
    my $interval = $self->c_service->{interval} || $self->host->{interval};
    my $timeout = $self->c_service->{timeout} || $self->host->{timeout};
    my $last_check = $self->c_service->{last_check};

    if ($self->whoami eq "srvchk" && $last_check + $interval + $timeout > $self->etime) {
        my $next_timeout = $last_check + $interval + $timeout - $self->etime > 600
            ? $self->etime + 600
            : $last_check + $interval + $timeout;
        $self->log->notice("refresh next_timeout to $next_timeout for service id", $self->service_id);
        $self->update_service_status(next_timeout => $next_timeout);
        return 1;
    }

    return 0;
}

sub check_srvchk_passive_check {
    my $self = shift;

    if ($self->whoami eq "srvchk" && $self->c_service->{passive_check}) {
        $self->log->notice("reset next_check and next_timeout of passive check");
        $self->update_service_status(next_check => 0, next_timeout => 0);
        return 1;
    }

    return 0;
}

sub check_if_srvchk_remote_error {
    my $self = shift;
    my $host = $self->host;
    my $redirect_config = $self->config->{redirect_remote_agent_timeouts};

    if ($self->whoami ne "srvchk" || $self->c_service->{agent_id} ne "remote" || !$redirect_config->{mail_to}) {
        return 0;
    }

    $self->log->notice("service", $self->service_id, "timed out, redirect notification");
    $self->log->notice("redirect notification for service", $self->service_id, "to $redirect_config->{mail_to}");

    $self->save_notification(
        service_id => $self->service_id,
        service => $self->c_service->{service_name},
        status => $self->n_service->{status},
        message_service => "mail",
        message => $self->n_service->{message},
        send_to => $redirect_config->{mail_to},
        description => $self->c_service->{description},
        comment => $self->c_service->{comment},
        redirect => 1
    );

    $self->service_status({
        status => "WARNING",
        message => join(" ", "[INTERNAL WARNING - remote agent dead]", $self->n_service->{message}),
        attempt_counter => 1
    });

    if ($self->c_service->{status} ne "WARNING" || $self->force_timed_event) {
        $self->log->notice("EVENT STATUS INFO SERVICE", $self->service_id, "MESSAGE", $self->n_service->{message});
        $self->service_status->{last_event} = $self->etime;

        $self->save_event(
            status => "WARNING",
            message => $self->service_status->{message},
            tags => "remote-agent-dead"
        );

        if ($self->c_service->{status} ne "WARNING") {
            $self->service_status->{status_nok_since} = $self->etime;
        }

        if ($self->c_service->{status} ne "INFO") {
            $self->service_status->{status_since} = $self->etime;
        }
    }

    $self->set_service_next_check;
    $self->update_service_status($self->service_status);
    return 1;
}

sub save_service_event {
    my $self = shift;

    if (
        $self->n_status ne $self->c_status
        || $self->force_timed_event
        || ($self->n_status !~ /^(OK|INFO)\z/ && !$self->attempt_max_reached->get($self->service_id))
    ) {
        $self->log->notice(
            "save event",
            status => $self->n_status,
            service => $self->service_id,
            message => $self->n_service->{message}
        );

        $self->service_status->{last_event} = $self->etime;

        if ($self->check_if_service_has_a_active_dependency) {
            $self->event_tags->push("dependent");
        }

        $self->log->dump(notice => {
            message => $self->service_status->{message},
            tags => $self->event_tags->join(","),
            attempts => join("/", $self->c_service->{attempt_counter}, $self->c_service->{attempt_max})
        });

        $self->save_event(
            message => $self->service_status->{message},
            tags => $self->event_tags->join(","),
            attempts => join("/", $self->c_service->{attempt_counter}, $self->c_service->{attempt_max})
        );
    }
}

sub update_service_status {
    my $self = shift;
    my $data = @_ > 1 ? {@_} : shift;

    $self->log->notice(
        "save service",
        status => $data->{status},
        message => $data->{message}
    );

    $self->db->update_service_status($self->service_id, $data);
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

    if ($self->log->is_debug) {
        $self->log->debug("save es data:");
        $self->log->dump(debug => {
            path => $path,
            data => $data
        });
    }

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

sub check_contact_timeperiods {
    my ($self, $contact_id, $contact_name) = @_;

    $self->log->notice("check time periods for contact $contact_id $contact_name");

    my $message_services = {};
    my $exclude_message_services = {};
    my $timeslices = $self->db->get_timeslices_by_contact_id($contact_id);

    # timeslices = [
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Monday - Sunday 00:00 - 23:59',
    #       'timeperiod_id' => '1',
    #       'id' => '1',
    #       'exclude' => '0',
    #       'message_service' => 'all'
    #     },
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Monday - Friday 09:00 - 17:00',
    #       'timeperiod_id' => '2',
    #       'id' => '1374',
    #       'exclude' => '0',
    #       'message_service' => 'sms'
    #     },
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Monday - Friday 09:00 - 17:00',
    #       'timeperiod_id' => '2',
    #       'id' => '2',
    #       'exclude' => '0',
    #       'message_service' => 'sms'
    #     },
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Saturday - Sunday 00:00 - 23:59',
    #       'timeperiod_id' => '3',
    #       'id' => '5',
    #       'exclude' => '0',
    #       'message_service' => 'mail'
    #     },
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Monday - Friday 00:00 - 08:59',
    #       'timeperiod_id' => '3',
    #       'id' => '4',
    #       'exclude' => '0',
    #       'message_service' => 'mail'
    #     },
    #     {
    #       'timezone' => 'Europe/Berlin',
    #       'timeslice' => 'Monday - Friday 17:01 - 23:59',
    #       'timeperiod_id' => '3',
    #       'id' => '3',
    #       'exclude' => '0',
    #       'message_service' => 'mail'
    #     }
    # ];

    if (!@$timeslices) {
        $self->log->notice("no time periods configured for contact $contact_id $contact_name");
        return $message_services;
    }

    foreach my $timeslice (@$timeslices) {
        my $matched = Bloonix::Timeperiod->check(
            $timeslice->{timeslice}, 
            $self->etime,
            $timeslice->{timezone},
        );

        if (!$matched) {
            $self->log->info(
                "timeslice $timeslice->{id} does not matched:",
                $timeslice->{message_service},
                $timeslice->{timeslice},
                $timeslice->{timezone},
                "exclude", $timeslice->{exclude}
            );
            next;
        }

        $self->log->notice(
            "timeslice $timeslice->{id} matched:",
            $timeslice->{message_service},
            $timeslice->{timeslice},
            $timeslice->{timezone},
            "exclude", $timeslice->{exclude}
        );

        if ($timeslice->{exclude}) {
            $self->log->info(
                "timeslice $timeslice->{id} excludes message service",
                $timeslice->{message_service}
            );

            if ($timeslice->{message_service} eq "all") {
                return {};
            }

            $exclude_message_services->{$timeslice->{message_service}} = 1;
            # setting a message service to 2 means that the service will be excluded
            $message_services->{$timeslice->{message_service}} = 2;
        } elsif (!$exclude_message_services->{$timeslice->{message_service}}) {
            $message_services->{$timeslice->{message_service}} = 1;
        }
    }

    return $message_services;
}

sub update_host_status {
    my $self = shift;
    my $host_id = $self->host->{id};
    my $curstat = $self->host->{status};
    my $states = $self->db->get_service_states($host_id);
    my $status = "OK";

    foreach my $s (@$states) {
        if ($self->stat_by_prio->get($s->{status}) > $self->stat_by_prio->get($status)) {
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

    if ($status ne $curstat) {
        my $cs_is_ok = $curstat =~ /^(OK|INFO)\z/;
        my $ns_is_ok = $status =~ /^(OK|INFO)\z/;

        if (($cs_is_ok && !$ns_is_ok) || (!$cs_is_ok && $ns_is_ok)) {
            $update{status_nok_since} = $self->etime;
        }
    }

    $self->db->update_host_status($host_id => \%update);
}

sub store_stats {
    my $self = shift;

    # statistics of simple scripts are not stored
    if (!$self->c_service->{plugin_id}) {
        return;
    }

    $self->log->info("store result");

    if ($self->n_service->{result}) {
        $self->save_results(
            service_id => $self->service_id,
            status => $self->n_service->{status},
            message => $self->n_service->{message},
            data => $self->n_service->{result},
            attempts => join("/", $self->c_service->{attempt_counter}, $self->c_service->{attempt_max})
        );
    }

    if (!defined $self->n_service->{stats}) {
        $self->log->info("no statistics received for service id", $self->service_id);
        return;
    }

    $self->log->info("store statistics");

    # The plugin data are cached for each loop a host is processed.
    if (!$self->plugin_def) {
        $self->plugin_def($self->db->get_plugin);
        $self->plugin_stat($self->db->get_plugin_stats);
    }

    my $stats = $self->n_service->{stats};
    my $plugin_id = $self->c_service->{plugin_id};
    my $plugin_def = $self->plugin_def->{$plugin_id};
    my $plugin_stat = $self->plugin_stat->{$plugin_id};

    if ($plugin_def->{datatype} eq "table") {
        my $ok = 0;

        if (ref $stats eq "ARRAY") {
            foreach my $row (@$stats) {
                if ($self->validate_stats($row, $plugin_stat, $self->c_service)) {
                    $ok++;
                }
            }

            if ($ok > 0 && $ok == scalar @$stats) {
                $self->save_stats(
                    service_id => $self->service_id,
                    plugin_id => $plugin_id,
                    data => $stats
                );
            }
        } else {
            $self->log->info("invalid statistic format received for service id", $self->service_id);
        }

        return;
    }

    if ($plugin_id == 59) {
        foreach my $key (keys %$stats) {
            if (
                $key !~ /^[^\s]+\z/
                || ref $stats->{$key}
                || !defined $stats->{$key}
                || $stats->{$key} !~ /^\d+(\.\d+){0,1}(s|us|ms|%|[YZEPTGMK]{0,1}B|c){0,1}\z/
            ) {
                delete $stats->{$key}
            }
        }
        if (scalar keys %$stats) {
            $self->save_stats(
                service_id => $self->service_id,
                plugin_id => $plugin_id,
                data => $stats
            );
        }
        return;
    }

    # Invalid statistic format
    if (ref $stats ne "HASH") {
        $self->log->info("invalid statistic format received for service id", $self->service_id);
        return;
    }

    # Check if the statistics are stored into a hash reference.
    if (!scalar keys %$stats) {
        $self->log->info("no statistics received for service id", $self->service_id);
        return;
    }

    # Does the plugin exists? We need some data to validate it...
    if (!$plugin_def) {
        $self->log->warning("unknown plugin_id '$plugin_id' configured for service id", $self->service_id);
        return;
    }

    my ($anykey) = keys %$stats;

    if ($plugin_def->{subkey} || ref $stats->{$anykey} eq "HASH") {
        my $subkeys = join(",", sort keys %$stats);

        if (!$self->c_service->{subkeys} || $self->c_service->{subkeys} ne $subkeys) {
            $self->service_status->{subkeys} = $subkeys;
        }

        foreach my $subvalue (keys %$stats) {
            if ($subvalue !~ m!^[a-zA-Z_0-9\-\.\:/]+\z!) {
                $self->log->error("invalid subkey '$subvalue' for plugin_id '$plugin_id'");
                last;
            }
            if ($self->validate_stats($stats->{$subvalue}, $plugin_stat, $self->c_service)) {
                $self->save_stats(
                    subkey => $subvalue,
                    service_id => $self->service_id,
                    plugin_id => $plugin_id,
                    data => $stats->{$subvalue}
                );
            }
        }
    } elsif ($self->validate_stats($stats, $plugin_stat, $self->c_service)) {
        if ($self->c_service->{subkeys}) {
            $self->service_status->{subkeys} = "";
        }
        $self->save_stats(
            service_id => $self->service_id,
            plugin_id => $plugin_id,
            data => $stats
        );
    }
}

sub rest_post {
    my $self = shift;
    my %request = @_;

    if (!$self->rest->post(@_)) {
        $self->log->error($self->rest->errstr);
        $self->log->dump(error => \%request);
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

sub save_notification {
    my ($self, %msg) = @_;
    my $notification = $self->{notifications};
    my $message_service = delete $msg{message_service};
    my $send_to = delete $msg{send_to};

    if ($message_service eq "sms") {
        $send_to =~ s/^\+/00/;
    }

    if ($self->log->is_debug) {
        $self->log->debug("saved notification:");
        $self->log->dump(debug => \%msg);
    }

    push @{$notification->{$message_service}->{$send_to}}, \%msg;
}

sub send_notifications {
    my $self = shift;

    if ($self->maintenance) {
        $self->log->warning("server runs in maintenance mode, unable to send any notifications");
        return 1;
    }

    if ($self->{notifications}->{mail}) {
        $self->send_mails;
    }

    if ($self->{notifications}->{sms}) {
        $self->send_sms;
    }
}

sub send_sms {
    my $self  = shift;
    my $host = $self->host;
    my $company = $self->company;
    my $mail = $self->config->{notification}->{mail};
    my $sms_config = $self->config->{notifications}->{sms};
    my %service_id = ();

    if (!$sms_config) {
        $self->log->notice("sms disabled");
        return 1;
    }

    foreach my $sms_to (keys %{ $self->{notifications}->{sms} }) {
        my ($service_ids, $message) = $self->gen_sms_message($sms_to);

        if ($self->send_sms_to_provider($sms_to, URI::Escape::uri_escape($message))) {
            $self->log->notice("sms successfully send");
            $host->{sms_count}++;
            $company->{sms_count}++;

            $self->db->create_send_sms(
                $self->etime,
                $host->{id},
                $self->company->{id},
                $sms_to,
                $message
            );

            foreach my $id (@$service_ids) {
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

            # Check here the sms_count again because if more than
            # one contact is configured then the sms counter
            # increases with each sms that is send.
            last if $self->check_inner_if_max_sms_reached;
        }
    }

    # Update last_notification first if send was successful,
    # but only if the status is not OK
    $self->update_last_notification(keys %service_id);
}

sub gen_sms_message {
    my ($self, $sms_to) = @_;
    my $host = $self->host;
    my $message = "$host->{hostname} $host->{ipaddr}";
    my $sms = $self->{notifications}->{sms}->{$sms_to};
    my (@service_ids, $redirect);

    if (@$sms == 1) {
        $sms = shift @$sms;
        $message .= " - $sms->{service_name} $sms->{status} - $sms->{message}";
        push @service_ids, $sms;
        $redirect = $sms->{redirect};
    } else {
        my (%status, @message, @service);

        foreach my $sms (@$sms) {
            $status{ $sms->{status} }++;
            push @service_ids, $sms;
            push @service, $sms->{service_name};

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
        $message = "REMOTE AGENT DEAD: $message";
    }

    if (length($message) > 160) {
        $message = substr($message, 0, 157) . "...";
    }

    return (\@service_ids, $message);
}

sub send_sms_to_provider {
    my ($self, $sms_to, $message) = @_;

    $self->log->notice("send sms to $sms_to: $message");

    if (!$self->execute_command_to_send_sms(primary => $sms_to => $message)) {
        if (!$self->execute_command_to_send_sms(failover => $sms_to => $message)) {
            return undef;
        }
    }

    return 1;
}

sub execute_command_to_send_sms {
    my ($self, $type, $sms_to, $message) = @_;
    my $param = $self->config->{notifications}->{sms};
    my ($command, $response, $route, $output);

    if ($type eq "primary") {
        $command = $param->{command};
        $response = $param->{response};
        $route = $self->company->{sms_route} || "gold";
    } elsif ($type eq "failover") {
        if (!$param->{failover_command}) {
            return undef;
        }
        $command = $param->{failover_command};
        $response = $param->{failover_response};
        $route = $self->company->{failover_sms_route} || "gold";
    }

    $command =~ s/<route>/$route/;
    $command =~ s/<to>/$sms_to/;
    $command =~ s/<message>/$message/;
    $command =~ s/%ROUTE%/$route/;
    $command =~ s/%TO%/$sms_to/;
    $command =~ s/%MESSAGE%/$message/;
    $command = "$command 2>&1";
    $self->log->notice($command);

    eval {
        local $SIG{__DIE__} = sub { alarm(0) };
        local $SIG{ALRM} = sub { die "command runs on a timeout after 10 seconds" };
        alarm(10);
        $output = qx{$command};
        alarm(0);
    };

    if ($@) {
        $self->log->error("unable to send sms to $sms_to - $@");
        return undef;
    }

    if (defined $response && (!defined $output || $output !~ /$response/)) {
        $self->log->error("error send sms to $sms_to: $output");
        return undef;
    }

    return 1;
}

sub check_inner_if_max_sms_reached {
    my $self = shift;
    my $host = $self->host;
    my $company = $self->company;

    if ($host->{max_sms} && $host->{sms_count} >= $host->{max_sms}) {
        $self->log->notice("no more host sms available - $host->{sms_count}/$host->{max_sms}");
        return 1;
    }

    if ($company->{max_sms} && $company->{sms_count} >= $company->{max_sms}) {
        $self->log->notice("no more company sms available - $company->{sms_count}/$company->{max_sms}");
        return 1;
    }

    return undef;
}

sub send_mails {
    my $self = shift;
    my $host = $self->host;
    my $company = $self->company;
    my $param = $self->config->{notifications}->{mail};
    my $hostname = $self->config->{hostname};
    my (%service_id, @recipients);

    foreach my $mail_to (keys %{ $self->{notifications}->{mail} }) {
        my $mails = $self->{notifications}->{mail}->{$mail_to};
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

        my $low_sms_contingent = $self->check_if_sms_contingent_is_low;

        if ($low_sms_contingent) {
            $message .= "\n=== WARNING ===\n\n";
            if ($host->{max_sms}) {
                $message .= "SMS host contingent: $host->{sms_count}/$host->{max_sms} SMS used\n";
            }
            if ($company->{max_sms}) {
                $message .= "SMS company contingent: $company->{sms_count}/$company->{max_sms} SMS used\n";
            }
            $message .= "Please increase the maximal allowed SMS per month!\n";
        }

        $message .= "\n";

        foreach my $m (@$mails) {
            push @id, $m;
            $status{ $m->{status} }++;
            $message .= "---\n";
            $message .= "Service: $m->{service_name}\n";
            $message .= "Status: $m->{status}\n";
            $message .= "Message: $m->{message}\n";

            if ($m->{description}) {
                $message .= "Description: $m->{description}\n";
            }

            if ($m->{comment}) {
                $message .= "Comment: $m->{comment}\n";
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
            $subject = "REMOTE AGENT DEAD: $subject";
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

        foreach my $id (@id) {
            if ($id->{status} ne "OK") {
                $service_id{$id->{service_id}}++;
            }
        }
    }

    # Update last_notification first if sendmail was successful,
    # but only if the status is not OK
    $self->update_last_notification(keys %service_id);
}

sub update_last_notification {
    my ($self, @ids) = @_;

    if (@ids) {
        $self->log->notice(
            "update last_notification to", $self->etime,
            "for service ids", @ids
        );
        $self->db->update_service_status(\@ids, {
            last_notification_1 => $self->etime,
            last_notification_2 => $self->etime
        });
    }
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

    if ($self->request_type eq "tcp") {
        $self->client->send($data);
        #$self->client->disconnect;
    } elsif ($self->request_type eq "http") {
        if ($data->{data} && $data->{plain}) {
            print "Content-Type: text/plain\n\n";
            print $data->{data};
        } else {
            print "Content-Type: application/json\n\n";
            print $self->json->encode($data);
        }
        $self->fcgi->finish;
    }
}

1;
