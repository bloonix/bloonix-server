use strict;
use warnings;
use Module::Build;

my $build = Module::Build->new(
    create_makefile_pl => 'traditional',
    module_name => 'Bloonix::Server',
    dist_author => 'Jonny Schulz',
    dist_abstract => 'Bloonix Server',
    sign => 0,
    requires => {
        "Bloonix::Core" => 0,
        "Bloonix::DBI" => 0,
        "JSON" => 0,
        "Log::Handler" => 0,
        "Math::BigFloat" => 0,
        "Math::BigInt" => 0,
        "MIME::Lite" => 0,
        "Params::Validate" => 0,
        "POSIX" => 0,
        "Sys::Hostname" => 0,
        "Time::HiRes" => 0,
        "Time::ParseDate" => 0,
        "URI::Escape" => 0
    },
);

$build->create_build_script;
