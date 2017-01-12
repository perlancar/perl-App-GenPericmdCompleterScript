package App::GenPericmdCompleterScript;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

use Data::Dmp;

use Exporter qw(import);
our @EXPORT_OK = qw(gen_pericmd_completer_script);

our %SPEC;

sub _pa {
    state $pa = do {
        require Perinci::Access::Lite;
        my $pa = Perinci::Access::Lite->new;
        $pa;
    };
    $pa;
}

sub _riap_request {
    my ($action, $url, $extras, $main_args) = @_;

    local $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0
        unless $main_args->{ssl_verify_hostname};

    _pa()->request($action => $url, %{$extras // {}});
}

$SPEC{gen_pericmd_completer_script} = {
    v => 1.1,
    summary => 'Generate Perinci::CmdLine completer script',
    args => {
        program_name => {
            summary => 'Program name that is being completed',
            schema  => 'str*',
            req     => 1,
            pos     => 0,
        },
        url => {
            summary => 'URL to function (or package, if you have subcommands)',
            schema => 'riap::url*',
            req => 1,
            pos => 1,
            tags => ['category:pericmd-attribute'],
        },
        subcommands => {
            summary => 'Hash of subcommand names and function URLs',
            description => <<'_',

Optionally, it can be additionally followed by a summary, so:

    URL[:SUMMARY]

Example (on CLI):

    --subcommand "delete=/My/App/delete_item:Delete an item"

_
            schema => ['hash*', of=>['any*', of=>['hash*', 'str*']]],
            cmdline_aliases => { s=>{} },
            tags => ['category:pericmd-attribute'],
        },
        subcommands_from_package_functions => {
            summary => "Form subcommands from functions under package's URL",
            schema => ['bool', is=>1],
            description => <<'_',

This is an alternative to the `subcommand` option. Instead of specifying each
subcommand's name and URL, you can also specify that subcommand names are from
functions under the package URL in `url`. So for example if `url` is `/My/App/`,
hen all functions under `/My/App` are listed first. If the functions are:

    foo
    bar
    baz_qux

then the subcommands become:

    foo => /My/App/foo
    bar => /My/App/bar
    "baz-qux" => /My/App/baz_qux

_
        },
        include_package_functions_match => {
            schema => 're*',
            summary => 'Only include package functions matching this pattern',
            links => [
                'subcommands_from_package_functions',
                'exclude_package_functions_match',
            ],
        },
        exclude_package_functions_match => {
            schema => 're*',
            summary => 'Exclude package functions matching this pattern',
            links => [
                'subcommands_from_package_functions',
                'include_package_functions_match',
            ],
        },
        output_file => {
            summary => 'Path to output file',
            schema => ['str*'],
            default => '-',
            cmdline_aliases => { o=>{} },
            tags => ['category:output'],
            'x.schema.entity' => 'filename',
        },
        overwrite => {
            schema => [bool => default => 0],
            summary => 'Whether to overwrite output if previously exists',
            tags => ['category:output'],
        },
        interpreter_path => {
            summary => 'What to put on shebang line',
            schema => 'str',
        },
        load_module => {
            summary => 'Load extra modules',
            schema  => ['array*', of=>'str*'],
        },
        completion => {
            schema => 'code*',
            tags => ['category:pericmd-attribute'],
        },
        default_subcommand => {
            schema => 'str*',
            tags => ['category:pericmd-attribute'],
        },
        per_arg_json => {
            schema => 'bool*',
            tags => ['category:pericmd-attribute'],
        },
        per_arg_yaml => {
            schema => 'bool*',
            tags => ['category:pericmd-attribute'],
        },
        skip_format => {
            schema => 'bool*',
            tags => ['category:pericmd-attribute'],
        },
        read_config => {
            schema => 'bool*',
            tags => ['category:pericmd-attribute'],
        },
        read_env => {
            schema => 'bool*',
            tags => ['category:pericmd-attribute'],
        },
        get_subcommand_from_arg => {
            schema => ['int*', in=>[0,1,2]],
            default => 1,
            tags => ['category:pericmd-attribute'],
        },
    },
};
sub gen_pericmd_completer_script {
    require Perinci::CmdLine::Lite;

    my %args = @_;

    # XXX schema
    my $output_file = $args{output_file} // '-';

    my $subcommands;
    my $sc_metas = {};
    if ($args{subcommands}) {
        $subcommands = {};
        for my $sc_name (keys %{ $args{subcommands} }) {
            my $v = $args{subcommands}{$sc_name};
            my ($sc_url, $sc_summary);
            if (ref($v) eq 'HASH') {
                $sc_url = $v->{url};
                $sc_summary = $v->{summary};
            } else {
                ($sc_url, $sc_summary) = split /:/, $v, 2;
            }
            my $res = _riap_request(meta => $sc_url => {}, \%args);
            return [500, "Can't meta $sc_url: $res->[0] - $res->[1]"]
                unless $res->[0] == 200;
            my $meta = $res->[2];
            $sc_metas->{$sc_name} = $meta;
            $sc_summary //= $meta->{summary};
            $subcommands->{$sc_name} = {
                url => $sc_url,
                summary => $sc_summary,
            };
        }
    } elsif ($args{subcommands_from_package_functions}) {
        my $res = _riap_request(child_metas => $args{url} => {detail=>1}, \%args);
        return [500, "Can't child_metas $args{url}: $res->[0] - $res->[1]"]
            unless $res->[0] == 200;
        $subcommands = {};
        for my $uri (keys %{ $res->[2] }) {
            next unless $uri =~ /\A\w+\z/; # functions only
            my $meta = $res->[2]{$uri};
            if ($args{include_package_functions_match}) {
                next unless $uri =~ /$args{include_package_functions_match}/;
            }
            if ($args{exclude_package_functions_match}) {
                next if $uri =~ /$args{exclude_package_functions_match}/;
            }
            (my $sc_name = $uri) =~ s/_/-/g;
            $sc_metas->{$sc_name} = $meta;
            $subcommands->{$sc_name} = {
                url     => "$args{url}$uri",
                summary => $meta->{summary},
            };
        }
    }

    # request metadata to get summary (etc)
    my $meta;
    {
        my $res = _riap_request(meta => $args{url} => {}, \%args);
        return [500, "Can't meta $args{url}: $res->[0] - $res->[1]"]
            unless $res->[0] == 200;
        $meta = $res->[2];
    }

    my $cli;
    {
        use experimental 'smartmatch';
        my $spec = $SPEC{gen_pericmd_completer_script};
        my @attr_args = grep {
            'category:pericmd-attribute' ~~ @{ $spec->{args}{$_}{tags} } }
            keys %{ $spec->{args} };
        $cli = Perinci::CmdLine::Lite->new(
            map { $_ => $args{$_} } @attr_args
        );
    }

    # GENERATE CODE
    my $code;
    my %used_modules = map {$_=>1} (
        'Complete::Bash',
        'Complete::Tcsh',
        'Complete::Util',
        'Perinci::Sub::Complete',
    );
    {
        my @res;

        # header
        {
            # XXX hide long-ish arguments

            push @res, (
                "#!", ($args{interpreter_path} // $^X), "\n\n",

                "# Note: This completer script is generated by ", __PACKAGE__, " version ", ($App::GenPericmdCompleterScript::VERSION // '?'), "\n",
                "# on ", scalar(localtime), ". You probably should not manually edit this file.\n\n",

                "# NO_PERINCI_CMDLINE_SCRIPT\n",
                "# PERINCI_CMDLINE_COMPLETER_SCRIPT: ", dmp(\%args), "\n",
                "# FRAGMENT id=shcompgen-hint completer=1 for=$args{program_name}\n",
                "# DATE\n",
                "# VERSION\n",
                "# PODNAME: _$args{program_name}\n",
                "# ABSTRACT: Completer script for $args{program_name}\n",
                "\n",
            );
        }

        # code
        push @res, (
            "use 5.010;\n",
            "use strict;\n",
            "use warnings;\n",
            "\n",

            'die "Please run this script under shell completion\n" unless $ENV{COMP_LINE} || $ENV{COMMAND_LINE};', "\n\n",

            ($args{load_module} ? (
                "# require extra modules\n",
                (map {"use $_ ();\n"} @{$args{load_module}}),
                "\n") : ()),

            'my $args = ', dmp(\%args), ";\n\n",

            'my $meta = ', dmp($meta), ";\n\n",

            'my $sc_metas = ', dmp($sc_metas), ";\n\n",

            'my $copts = ', dmp($cli->common_opts), ";\n\n",

            'my $r = {};', "\n\n",

            "# get words\n",
            'my $shell;', "\n",
            'my ($words, $cword);', "\n",
            'if ($ENV{COMP_LINE}) { $shell = "bash"; require Complete::Bash; require Encode; ($words,$cword) = @{ Complete::Bash::parse_cmdline() }; ($words,$cword) = @{ Complete::Bash::join_wordbreak_words($words,$cword) }; $words = [map {Encode::decode("UTF-8", $_)} @$words]; }', "\n",
            'elsif ($ENV{COMMAND_LINE}) { $shell = "tcsh"; require Complete::Tcsh; ($words,$cword) = @{ Complete::Tcsh::parse_cmdline() }; }', "\n",
            '@ARGV = @$words;', "\n",
            "\n",

            "# strip program name\n",
            'shift @$words; $cword--;', "\n\n",

            "# parse common_opts which potentially sets subcommand\n",
            '{', "\n",
            "    require Getopt::Long;\n",
            q(    my $old_go_conf = Getopt::Long::Configure('pass_through', 'no_ignore_case', 'bundling', 'no_auto_abbrev', 'no_getopt_compat', 'gnu_compat');), "\n",
            q(    my @go_spec;), "\n",
            q(    for my $k (keys %$copts) { push @go_spec, $copts->{$k}{getopt} => sub { my ($go, $val) = @_; $copts->{$k}{handler}->($go, $val, $r); } }), "\n",
            q(    Getopt::Long::GetOptions(@go_spec);), "\n",
            q(    Getopt::Long::Configure($old_go_conf);), "\n",
            "}\n\n",

            "# select subcommand\n",
            'my $scn = $r->{subcommand_name};', "\n",
            'my $scn_from = $r->{subcommand_name_from};', "\n",
            'if (!defined($scn) && defined($args->{default_subcommand})) {', "\n",
            '    # get from default_subcommand', "\n",
            '    if ($args->{get_subcommand_from_arg} == 1) {', "\n",
            '        $scn = $args->{default_subcommand};', "\n",
            '        $scn_from = "default_subcommand";', "\n",
            '    } elsif ($args->{get_subcommand_from_arg} == 2 && !@ARGV) {', "\n",
            '        $scn = $args->{default_subcommand};', "\n",
            '        $scn_from = "default_subcommand";', "\n",
            '    }', "\n",
            '}', "\n",
            'if (!defined($scn) && $args->{subcommands} && @ARGV) {', "\n",
            '    # get from first command-line arg', "\n",
            '    $scn = shift @ARGV;', "\n",
            '    $scn_from = "arg";', "\n",
            '}', "\n\n",
            'if (defined($scn) && !$sc_metas->{$scn}) { undef $scn } # unknown subcommand name', "\n",

            "# XXX read_env\n\n",

            "# complete with periscomp\n",
            'my $compres;', "\n",
            "{\n",
            '    require Perinci::Sub::Complete;', "\n",
            '    $compres = Perinci::Sub::Complete::complete_cli_arg(', "\n",
            '        meta => defined($scn) ? $sc_metas->{$scn} : $meta,', "\n",
            '        words => $words,', "\n",
            '        cword => $cword,', "\n",
            '        common_opts => $copts,', "\n",
            '        riap_server_url => undef,', "\n",
            '        riap_uri => undef,', "\n",
            '        extras => {r=>$r, cmdline=>undef},', "\n", # no cmdline object
            '        func_arg_starts_at => (($scn_from//"") eq "arg" ? 1:0),', "\n",
            '        completion => sub {', "\n",
            '            my %args = @_;', "\n",
            '            my $type = $args{type};', "\n",
            '', "\n",
            '            # user specifies custom completion routine, so use that first', "\n",
            '            if ($args->{completion}) {', "\n",
            '                my $res = $args->{completion}->(%args);', "\n",
            '                return $res if $res;', "\n",
            '            }', "\n",
            q(            # if subcommand name has not been supplied and we're at arg#0,), "\n",
            '            # complete subcommand name', "\n",
            '            if ($args->{subcommands} &&', "\n",
            '                $scn_from ne "--cmd" &&', "\n",
            '                     $type eq "arg" && $args{argpos}==0) {', "\n",
            '                require Complete::Util;', "\n",
            '                return Complete::Util::complete_array_elem(', "\n",
            '                    array => [keys %{ $args->{subcommands} }],', "\n",
            '                    word  => $words->[$cword]);', "\n",
            '            }', "\n",
            '', "\n",
            '            # otherwise let periscomp do its thing', "\n",
            '            return undef;', "\n",
            '        },', "\n",
            '    );', "\n",
            "}\n\n",

            "# display result\n",
            'if    ($shell eq "bash") { print Complete::Bash::format_completion($compres, {word=>$words->[$cword]}) }', "\n",
            'elsif ($shell eq "tcsh") { print Complete::Tcsh::format_completion($compres) }', "\n",
        );

        $code = join "", @res;
    } # END GENERATE CODE

    # pack the modules
    my $packed_code;
    {
        require App::depak;
        require File::Slurper;
        require File::Temp;

        my (undef, $tmp_unpacked_path) = File::Temp::tempfile();
        my (undef, $tmp_packed_path)   = File::Temp::tempfile();

        File::Slurper::write_text($tmp_unpacked_path, $code);

        my $res = App::depak::depak(
            include_prereq => [sort keys %used_modules],
            input_file     => $tmp_unpacked_path,
            output_file    => $tmp_packed_path,
            overwrite      => 1,
            trace_method   => 'none',
            pack_method    => 'datapack',

            stripper         => 1,
            stripper_pod     => 1,
            stripper_comment => 1,
            stripper_ws      => 1,
            stripper_maintain_linum => 0,
            stripper_log     => 0,
        );
        return $res unless $res->[0] == 200;

        $packed_code = File::Slurper::read_text($tmp_packed_path);
    }

    if ($output_file ne '-') {
        $log->trace("Outputing result to %s ...", $output_file);
        if ((-f $output_file) && !$args{overwrite}) {
            return [409, "Output file '$output_file' already exists (please use --overwrite if you want to override)"];
        }
        open my($fh), ">", $output_file
            or return [500, "Can't open '$output_file' for writing: $!"];

        print $fh $packed_code;
        close $fh
            or return [500, "Can't write '$output_file': $!"];

        chmod 0755, $output_file or do {
            $log->warn("Can't 'chmod 0755, $output_file': $!");
        };

        my $output_name = $output_file;
        $output_name =~ s!.+[\\/]!!;

        $packed_code = "";
    }

    [200, "OK", $packed_code, {
    }];
}

1;
# ABSTRACT:
