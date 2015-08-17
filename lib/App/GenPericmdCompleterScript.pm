package App::GenPericmdCompleterScript;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

use Data::Dump qw(dump);
use File::Which;
use String::Indent qw(indent);

use Exporter qw(import);
our @EXPORT_OK = qw(gen_perinci_cmdline_script);

our %SPEC;

sub _pa {
    state $pa = do {
        require Perinci::Access;
        my $pa = Perinci::Access->new;
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

$SPEC{gen_perinci_cmdline_script} = {
    v => 1.1,
    summary => 'Generate Perinci::CmdLine completer script',
    args => {

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

        url => {
            summary => 'URL to function (or package, if you have subcommands)',
            schema => 'str*',
            'x.schema.entity' => 'riap_url',
            req => 1,
            pos => 0,
        },
        subcommand => {
            summary => 'Subcommand name followed by colon and function URL',
            description => <<'_',

Optionally, it can be additionally followed by a summary, so:

    NAME:URL[:SUMMARY]

Example (on CLI):

    --subcommand "delete:/My/App/delete_item:Delete an item"

_
            schema => ['array*', of=>'str*'],
            cmdline_aliases => { s=>{} },
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
        #log => {
        #    summary => 'Will be passed to Perinci::CmdLine constructor',
        #    schema  => 'bool',
        #},
        load_module => {
            summary => 'Load extra modules',
            schema => ['array', of=>'str*'],
            'x.schema.element_entity' => 'modulename',
        },
        interpreter_path => {
            summary => 'What to put on shebang line',
            schema => 'str',
        },
    },
};
sub gen_perinci_cmdline_completer_script {
    my %args = @_;

    local $Data::Dump::INDENT = "    ";

    # XXX schema
    $args{ssl_verify_hostname} //= 1;

    my $output_file = $args{output_file};

    my $script_name = $args{script_name};
    unless ($script_name) {
        if ($output_file eq '-') {
            $script_name = 'script';
        } else {
            $script_name = $output_file;
            $script_name =~ s!.+[\\/]!!;
        }
    }

    my $cmdline_mod = "Perinci::CmdLine::Any";
    my $cmdline_mod_ver = 0;
    if ($args{cmdline}) {
        my $val = $args{cmdline};
        if ($val eq 'any') {
            $cmdline_mod = "Perinci::CmdLine::Any";
        } elsif ($val eq 'classic') {
            $cmdline_mod = "Perinci::CmdLine::Classic";
        } elsif ($val eq 'lite') {
            $cmdline_mod = "Perinci::CmdLine::Lite";
        } elsif ($val eq 'inline') {
            $cmdline_mod = "Perinci::CmdLine::Inline";
        } else {
            $cmdline_mod = $val;
        }
    }

    my $subcommands;
    if ($args{subcommand} && @{ $args{subcommand} }) {
        $subcommands = {};
        for (@{ $args{subcommand} }) {
            my ($sc_name, $sc_url, $sc_summary) = split /:/, $_, 3;
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

    my $gen_sig = join(
        "",
        "# Note: This script is a CLI interface",
        ($meta->{args} ? " to Riap function $args{url}" : ""), # a quick hack to guess meta is func metadata (XXX should've done an info Riap request)
        "\n",
        "# and generated automatically using ", __PACKAGE__,
        " version ", ($App::GenPericmdScript::VERSION // '?'), "\n",
    );

    # generate code
    my $code;
    if ($cmdline_mod eq 'Perinci::CmdLine::Inline') {
        require Perinci::CmdLine::Inline;
        $cmdline_mod_ver = $Perinci::CmdLine::Inline::VERSION;
        my $res = Perinci::CmdLine::Inline::gen_inline_pericmd_script(
            url => $args{url},
            program_name => $args{script_name},
            program_version => $args{script_version},
            subcommands => $subcommands,
            log => $args{log},
            (extra_urls_for_version => $args{extra_urls_for_version}) x !!$args{extra_urls_for_version},
            include => $args{load_module},
            code_after_shebang => $gen_sig,
            (code_before_parse_cmdline_options => $args{snippet_before_instantiate_cmdline}) x !!$args{snippet_before_instantiate_cmdline},
            # config_filename => $args{config_filename},
            shebang => $args{interpreter_path},
            skip_format => $args{skip_format} ? 1:0,
        );
        return $res if $res->[0] != 200;
        $code = $res->[2];
    } else {
        $code = join(
            "",
            "#!", ($args{interpreter_path} // $^X), "\n",
            "\n",
            $gen_sig,
            "\n",
            "# DATE\n",
            "# DIST\n",
            "# VERSION\n",
            "\n",
            "use 5.010001;\n",
            "use strict;\n",
            "use warnings;\n",
            "\n",

            ($args{load_module} && @{$args{load_module}} ?
                 join("", map {"use $_;\n"} @{$args{load_module}})."\n" : ""),

            ($args{default_log_level} ?
                 "BEGIN { no warnings; \$main::Log_Level = '$args{default_log_level}'; }\n\n" : ""),

            "use $cmdline_mod",
            ($cmdline_mod eq 'Perinci::CmdLine::Any' &&
                 defined($args{prefer_lite}) && !$args{prefer_lite} ? " -prefer_lite=>0" : ""),
            ";\n\n",

            ($args{ssl_verify_hostname} ?
                 "" : '$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;' . "\n\n"),

            ($args{snippet_before_instantiate_cmdline} ? "# snippet_before_instantiate_cmdline\n" . $args{snippet_before_instantiate_cmdline} . "\n\n" : ""),

            "$cmdline_mod->new(\n",
            "    url => ", dump($args{url}), ",\n",
            (defined($subcommands) ? "    subcommands => " . indent("    ", dump($subcommands), {first_line_indent=>""}) . ",\n" : ""),
            (defined($args{log}) ? "    log => " . dump($args{log}) . ",\n" : ""),
            (defined($args{extra_urls_for_version}) ? "    extra_urls_for_version => " . dump($args{extra_urls_for_version}) . ",\n" : ""),
            (defined($args{config_filename}) ? "    config_filename => " . dump($args{config_filename}) . ",\n" : ""),
            ($args{skip_format} ? "    skip_format => 1,\n" : ""),
            ")->run;\n",
            "\n",
        );

        # abstract line
        $code .= "# ABSTRACT: " . ($meta->{summary} // $script_name) . "\n";

        # podname
        $code .= "# PODNAME: $script_name\n";
    } # END generate code

    if ($output_file ne '-') {
        $log->trace("Outputing result to %s ...", $output_file);
        if ((-f $output_file) && !$args{overwrite}) {
            return [409, "Output file '$output_file' already exists (please use --overwrite if you want to override)"];
        }
        open my($fh), ">", $output_file
            or return [500, "Can't open '$output_file' for writing: $!"];

        print $fh $code;
        close $fh
            or return [500, "Can't write '$output_file': $!"];

        chmod 0755, $output_file or do {
            $log->warn("Can't 'chmod 0755, $output_file': $!");
        };

        my $output_name = $output_file;
        $output_name =~ s!.+[\\/]!!;

        if (which("shcompgen") && which($output_name)) {
            $log->trace("We have shcompgen in PATH and output ".
                            "$output_name is also in PATH, running shcompgen ...");
            system "shcompgen", "generate", $output_name;
        }

        $code = "";
    }

    [200, "OK", $code, {
        'func.cmdline_module' => $cmdline_mod,
        'func.cmdline_module_version' => $cmdline_mod_ver,
        'func.cmdline_module_inlined' => ($cmdline_mod eq 'Perinci::CmdLine::Inline' ? 1:0),
        'func.script_name' => 0,
    }];
}

1;
# ABSTRACT:
