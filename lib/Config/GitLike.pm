package Config::GitLike;

use strict;
use warnings;
use File::Spec;
use Cwd;
use File::HomeDir;
use Regexp::Common;
use Any::Moose;
use Fcntl qw/O_CREAT O_EXCL O_WRONLY/;
use 5.008;


has 'confname' => (
    is => 'rw',
    required => 1,
    isa => 'Str',
);

# not defaulting to {} allows the predicate is_loaded
# to determine whether data has been loaded yet or not
has 'data' => (
    is => 'rw',
    predicate => 'is_loaded',
    isa => 'HashRef',
);

has 'multiple' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { +{} },
);

sub set_multiple {
    my $self = shift;
    my ($name, $mult) = @_, 1;
    $self->multiple->{$name} = $mult;
}

sub is_multiple {
    my $self = shift;
    my $name = shift;
    return $self->multiple->{$name};
}

sub load {
    my $self = shift;
    my $path = shift || Cwd::cwd;
    $self->data({});
    $self->load_global;
    $self->load_user;
    $self->load_dirs( $path );
    return wantarray? %{$self->data} : $self->data;
}

sub dir_file {
    my $self = shift;
    return "." . $self->confname;
}

sub load_dirs {
    my $self = shift;
    my $path = shift;
    my($vol, $dirs, undef) = File::Spec->splitpath( $path, 1 );
    my @dirs = File::Spec->splitdir( $dirs );
    while (@dirs) {
        my $path = File::Spec->catpath( $vol, File::Spec->catdir(@dirs),
            $self->dir_file );
        if (-f $path) {
            $self->load_file( $path );
            last;
        }
        pop @dirs;
    }
}

sub global_file {
    my $self = shift;
    return "/etc/" . $self->confname;
}

sub load_global {
    my $self = shift;
    return unless -f $self->global_file;
    return $self->load_file( $self->global_file );
}

sub user_file {
    my $self = shift;
    return File::Spec->catfile( File::HomeDir->my_home, "." . $self->confname );
}

sub load_user {
    my $self = shift;
    return unless -f $self->user_file;
    return $self->load_file( $self->user_file );
}

# returns undef if the file was unable to be opened
sub _read_config {
    my $self = shift;
    my $filename = shift;

    open(my $fh, "<", $filename) or return;

    my $c = do {local $/; <$fh>};

    $c =~ s/\n*$/\n/; # Ensure it ends with a newline
    close $fh;

    return $c;
}

sub load_file {
    my $self = shift;
    my ($filename) = @_;
    my $c = $self->_read_config($filename);

    $self->parse_content(
        content  => $c,
        callback => sub {
            $self->define(@_);
        },
        error    => sub {
            die "Error parsing $filename, near:\n@_\n";
        },
    );
    return $self->data;
}

sub parse_content {
    my $self = shift;
    my %args = (
        content  => "",
        callback => sub {},
        error    => sub {},
        @_,
    );
    my $c = $args{content};
    my $length = length $c;

    my($section, $prev) = (undef, '');
    while (1) {
        # drop leading white space and blank lines
        $c =~ s/\A\s*//im;

        my $offset = $length - length($c);
        # drop to end of line on comments
        if ($c =~ s/\A[#;].*?$//im) {
            next;
        # [sub]section headers of the format [section "subsection"] (with
        # unlimited whitespace between) or [section.subsection] variable
        # definitions may directly follow the section header, on the same line!
        # - rules for sections: not case sensitive, only alphanumeric
        #   characters, -, and . allowed
        # - rules for subsections enclosed in ""s: case sensitive, can
        #   contain any character except newline, " and \ must be escaped
        # - rules for subsections with section.subsection alternate syntax:
        #   same rules as for sections
        } elsif ($c =~ s/\A\[([0-9a-z.-]+)(?:[\t ]*"([^\n]*?)")?\]//im) {
            $section = lc $1;
            return $args{error}->(
                content => $args{content},
                offset =>  $offset,
                # don't allow quoted subsections to contain unquoted
                # double-quotes or backslashes
            ) if $2 && $2 =~ /(?<!\\)(?:"|\\)/;
            $section .= ".$2" if defined $2;
            $args{callback}->(
                section    => $section,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        # keys followed by a unlimited whitespace and (optionally) a comment
        # (no value)
        } elsif ($c =~ s/\A([0-9a-z-]+)[\t ]*([#;].*)?$//im) {
            $args{callback}->(
                section    => $section,
                name       => $1,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        # key/value pairs (this particular regex matches only the key part and
        # the =, with unlimited whitespace around the =)
        } elsif ($c =~ s/\A([0-9a-z-]+)[\t ]*=[\t ]*//im) {
            my $name = $1;
            my $value = "";
            # parse the value
            while (1) {
                # comment or no content left on line
                if ($c =~ s/\A([ \t]*[#;].*?)?$//im) {
                    last;
                # any amount of whitespace between words becomes a single space
                } elsif ($c =~ s/\A[\t ]+//im) {
                    $value .= ' ';
                # line continuation (\ character followed by new line)
                } elsif ($c =~ s/\A\\\r?\n//im) {
                    next;
                # escaped quote characters are part of the value
                } elsif ($c =~ s/\A\\(['"])//im) {
                    $value .= $1;
                # escaped newline in config is translated to actual newline
                } elsif ($c =~ s/\A\\n//im) {
                    $value .= "\n";
                # escaped tab in config is translated to actual tab
                } elsif ($c =~ s/\A\\t//im) {
                    $value .= "\t";
                # escaped backspace in config is translated to actual backspace
                } elsif ($c =~ s/\A\\b//im) {
                    $value .= "\b";
                # quote-delimited value (possibly containing escape codes)
                } elsif ($c =~ s/\A"([^"\\]*(?:(?:\\\n|\\[tbn"\\])[^"\\]*)*)"//im) {
                    my $v = $1;
                    # remove all continuations (\ followed by a newline)
                    $v =~ s/\\\n//g;
                    # swap escaped newlines with actual newlines
                    $v =~ s/\\n/\n/g;
                    # swap escaped tabs with actual tabs
                    $v =~ s/\\t/\t/g;
                    # swap escaped backspaces with actual backspaces
                    $v =~ s/\\b/\b/g;
                    # swap escaped \ with actual \
                    $v =~ s/\\\\/\\/g;
                    $value .= $v;
                # valid value (no escape codes)
                } elsif ($c =~ s/\A([^\t \\\n]+)//im) {
                    $value .= $1;
                # unparseable
                } else {
                    # Note that $args{content} is the _original_
                    # content, not the nibbled $c, which is the
                    # remaining unparsed content
                    return $args{error}->(
                        content => $args{content},
                        offset =>  $offset,
                    );
                }
            }
            $args{callback}->(
                section    => $section,
                name       => $name,
                value      => $value,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        # end of content string; all done now
        } elsif (not length $c) {
            last;
        # unparseable
        } else {
            # Note that $args{content} is the _original_ content, not
            # the nibbled $c, which is the remaining unparsed content
            return $args{error}->(
                content => $args{content},
                offset  => $offset,
            );
        }
    }
}

sub define {
    my $self = shift;
    my %args = (
        section => undef,
        name    => undef,
        value   => undef,
        @_,
    );
    return unless defined $args{name};
    $args{name} = lc $args{name};
    my $key = join(".", grep {defined} @args{qw/section name/});
    if ($self->is_multiple($key)) {
        push @{$self->data->{$key} ||= []}, $args{value};
    } elsif (exists $self->data->{$key}) {
        $self->set_multiple($key);
        $self->data->{$key} = [$self->data->{$key}, $args{value}];
    } else {
        $self->data->{$key} = $args{value};
    }
}

sub cast {
    my $self = shift;
    my %args = (
        value => undef,
        as    => undef, # bool, int, or num
        human => undef, # true value / false value
        @_,
    );

    use constant {
        BOOL_TRUE_REGEX => qr/^(?:true|yes|on|-?0*1)$/i,
        BOOL_FALSE_REGEX => qr/^(?:false|no|off|0*)$/i,
        NUM_REGEX => qr/^-?[0-9]*\.?[0-9]*[kmg]?$/,
    };

    if (defined $args{as} && $args{as} eq 'bool-or-int') {
        if ( $args{value} =~ NUM_REGEX ) {
            $args{as} = 'int';
        } elsif ( $args{value} =~ BOOL_TRUE_REGEX ||
            $args{value} =~ BOOL_FALSE_REGEX ) {
            $args{as} = 'bool';
        } elsif ( !defined $args{value} ) {
            $args{as} = 'bool';
        } else {
            die "Invalid bool-or-int '$args{value}'\n";
        }
    }

    my $v = $args{value};
    return $v unless defined $args{as};
    if ($args{as} =~ /bool/i) {
        return 1 unless defined $v;
        if ( $v =~  BOOL_TRUE_REGEX ) {
            if ( $args{human} ) {
                return 'true';
            } else {
                return 1;
            }
        } elsif ($v =~ BOOL_FALSE_REGEX ) {
            if ( $args{human} ) {
                return 'false';
            } else {
                return 0;
            }
        } else {
            die "Invalid bool '$args{value}'\n";
        }
    } elsif ($args{as} =~ /int|num/) {
        die "Invalid unit while casting to $args{as}\n"
            unless $v =~ NUM_REGEX;

        if ($v =~ s/([kmg])$//) {
            $v *= 1024 if $1 eq "k";
            $v *= 1024*1024 if $1 eq "m";
            $v *= 1024*1024*1024 if $1 eq "g";
        }

        return $args{as} eq 'int' ? int $v : $v + 0;
    }
}

sub get {
    my $self = shift;
    my %args = (
        key => undef,
        as  => undef,
        human  => undef,
        filter => '',
        @_,
    );
    $self->load unless $self->is_loaded;

    $args{key} = lc $self->_remove_balanced_quotes($args{key});

    return undef unless exists $self->data->{$args{key}};
    my $v = $self->data->{$args{key}};
    if (ref $v) {
        my @results;
        if (defined $args{filter}) {
            if ($args{filter} =~ s/^!//) {
                @results = grep { !/$args{filter}/i } @{$v};
            } else {
                @results = grep { m/$args{filter}/i } @{$v};
            }
        }
        die "Multiple values" unless @results <= 1;
        $v = $results[0];
    }
    return $self->cast( value => $v, as => $args{as},
        human => $args{human} );
}

# I'm pretty sure that someone can come up with an edge case where stripping
# all balanced quotes like this is not the right thing to do, but I don't
# see it actually being a problem in practice.
sub _remove_balanced_quotes {
    my $self = shift;
    my $key = shift;

    no warnings 'uninitialized';
    $key = join '', map { s/"(.*)"/$1/; $_ } split /("[^"]+"|[^.]+)/, $key;
    $key = join '', map { s/'(.*)'/$1/; $_ } split /('[^']+'|[^.]+)/, $key;

    return $key;
}

sub get_all {
    my $self = shift;
    my %args = (
        key => undef,
        as  => undef,
        @_,
    );
    $self->load unless $self->is_loaded;
    $args{key} = lc $self->_remove_balanced_quotes($args{key});

    return undef unless exists $self->data->{$args{key}};
    my $v = $self->data->{$args{key}};
    my @v = ref $v ? @{$v} : ($v);

    if (defined $args{filter}) {
        if ($args{filter} =~ s/^!//) {
            @v = grep { !/$args{filter}/i } @v;
        } else {
            @v = grep { m/$args{filter}/i } @v;
        }
    }

    @v = map {$self->cast( value => $_, as => $args{as} )} @v;
    return wantarray ? @v : \@v;
}

sub get_regexp {
    my $self = shift;

    my %args = (
        key => undef,
        filter => undef,
        as  => undef,
        @_,
    );

    $self->load unless $self->is_loaded;

    $args{key} = lc $args{key};

    my %results;
    for my $key (keys %{$self->data}) {
        $results{$key} = $self->data->{$key} if lc $key =~ m/$args{key}/i;
    }

    if (defined $args{filter}) {
        if ($args{filter} =~ s/^!//) {
            map { delete $results{$_} if $results{$_} =~ m/$args{filter}/i }
                keys %results;
        } else {
            map { delete $results{$_} if $results{$_} !~ m/$args{filter}/i }
                keys %results;
        }
    }

    @results{keys %results} = map { $self->cast( value => $results{$_}, as =>
            $args{as} ) } keys %results;
    return wantarray ? %results : \%results;
}

sub dump {
    my $self = shift;

    return %{$self->data} if wantarray;

    my $data = '';
    for my $key (sort keys %{$self->data}) {
        my $str;
        if (defined $self->data->{$key}) {
            $str = "$key=".$self->data->{$key}."\n";
        } else {
            $str = "$key\n";
        }
        if (!defined wantarray) {
            print $str;
        } else {
            $data .= $str;
        }
    }

    return $data if defined wantarray;
}

sub format_section {
    my $self = shift;

    my %args = (
        section => undef,
        bare    => undef,
        @_,
    );

    if ($args{section} =~ /^(.*?)\.(.*)$/) {
        my ($section, $subsection) = ($1, $2);
        $subsection =~ s/(["\\])/\\$1/g;
        my $ret = qq|[$section "$subsection"]|;
        $ret .= "\n" unless $args{bare};
        return $ret;
    } else {
        my $ret = qq|[$args{section}]|;
        $ret .= "\n" unless $args{bare};
        return $ret;
    }
}

sub format_definition {
    my $self = shift;
    my %args = (
        key   => undef,
        value => undef,
        bare  => undef,
        @_,
    );
    my $quote = $args{value} =~ /(^\s|;|#|\s$)/ ? '"' : '';
    $args{value} =~ s/\\/\\\\/g;
    $args{value} =~ s/"/\\"/g;
    $args{value} =~ s/\t/\\t/g;
    $args{value} =~ s/\n/\\n/g;
    my $ret = "$args{key} = $quote$args{value}$quote";
    $ret = "\t$ret\n" unless $args{bare};
    return $ret;
}

sub set {
    my $self = shift;
    my (%args) = (
        key      => undef,
        value    => undef,
        filename => undef,
        filter   => undef,
        as       => undef,
        multiple => undef,
        @_
    );

    die "No key given\n" unless defined $args{key};

    $args{multiple} = $self->is_multiple($args{key})
        unless defined $args{multiple};

    $args{key} =~ /^(?:(.*)\.)?(.*)$/;
    my($section, $key) = map { $self->_remove_balanced_quotes($_) }
        grep { defined $_ } ($1, $2);

    die "No section given in key or invalid key $args{key}\n"
        unless defined $section;

    die "Invalid key $key\n" if $self->_invalid_key($key);

    $args{value} = $self->cast(value => $args{value}, as => $args{as},
        human => 1)
        if defined $args{value} && defined $args{as};

    unless (-f $args{filename}) {
        die "No occurrence of $args{key} found to unset in $args{filename}\n"
            unless defined $args{value};
        open(my $fh, ">", $args{filename})
            or die "Can't write to $args{filename}: $!\n";
        print $fh $self->format_section(section => $section);
        print $fh $self->format_definition( key => $key, value => $args{value} );
        close $fh;
        return;
    }

    # returns if the file can't be opened, since that means nothing to
    # set/unset
    my $c = $self->_read_config($args{filename});

    my $new;
    my @replace;
    $self->parse_content(
        content  => $c,
        callback => sub {
            my %got = @_;
            return unless lc($got{section}) eq lc($section);
            $new = $got{offset} + $got{length};
            return unless defined $got{name};

            my $matched = 0;
            if (lc $key eq lc $got{name}) {
                if (defined $args{filter}) {
                    # copy the filter arg here since this callback may
                    # be called multiple times and we don't want to
                    # modify the original value
                    my $filter = $args{filter};
                    if ($filter =~ s/^!//) {
                        $matched = 1 if ($got{value} !~ m/$filter/i);
                    } elsif ($got{value} =~ m/$filter/i) {
                        $matched = 1;
                    }
                } else {
                    $matched = 1;
                }
            }

            push @replace, {offset => $got{offset}, length => $got{length}}
                if $matched;
        },
        error    => sub {
            die "Error parsing $args{filename}, near:\n@_\n";
        },
    );

    die "Multiple occurrences of non-multiple key?"
        if @replace > 1 && !$args{multiple};

    if (defined $args{value}) {
        if (@replace && (!$args{multiple} || $args{replace_all})) {
            # Replacing existing value(s)

            # if the string we're replacing with is not the same length as
            # what's being replaced, any offsets following will be wrong. save
            # the difference between the lengths here and add it to any offsets
            # that follow.
            my $difference = 0;

            # when replacing multiple values, we combine them all into one,
            # which is kept at the position of the last one
            my $last = pop @replace;

            # kill all values that are not last
            ($c, $difference) = $self->_unset_variables(\@replace, $c,
                $difference);

            # substitute the last occurrence with the new value
            substr(
                $c,
                $last->{offset}-$difference,
                $last->{length},
                $self->format_definition(
                    key   => $key,
                    value => $args{value},
                    bare  => 1,
                    ),
                );
        } elsif (defined $new) {
            # Adding a new value to the end of an existing block
            substr(
                $c,
                index($c, "\n", $new)+1,
                0,
                $self->format_definition(
                    key   => $key,
                    value => $args{value}
                )
            );
        } else {
            # Adding a new section
            $c .= $self->format_section( section => $section );
            $c .= $self->format_definition( key => $key, value => $args{value} );
        }
    } else {
        # Removing an existing value (unset / unset-all)
        die "No occurrence of $args{key} found to unset in $args{filename}\n"
            unless @replace;

        ($c, undef) = $self->_unset_variables(\@replace, $c, 0);
    }

    return $self->_write_config($args{filename}, $c);
}

sub _unset_variables {
    my ($self, $variables, $c, $difference) = @_;

    for my $var (@{$variables}) {
        # start from either the last newline or the last section
        # close bracket, since variable definitions can occur
        # immediately following a section header without a \n
        my $newline = rindex($c, "\n", $var->{offset}-$difference);
        # need to add 1 here to not kill the ] too
        my $bracket = rindex($c, ']', $var->{offset}-$difference) + 1;
        my $start = $newline > $bracket ? $newline : $bracket;

        my $length =
            index($c, "\n", $var->{offset}-$difference+$var->{length})-$start;

        substr(
            $c,
            $start,
            $length,
            '',
        );
        $difference += $length;
    }

    return ($c, $difference);
}

# according to the git test suite, keys cannot start with a number
sub _invalid_key {
    my $self = shift;
    my $key = shift;

    return $key =~ /^[0-9]/;
}

# write config with locking
sub _write_config {
    my($self, $filename, $content) = @_;

    # write new config file to disk
    sysopen(my $fh, "${filename}.lock", O_CREAT|O_EXCL|O_WRONLY)
        or die "Can't open ${filename}.lock for writing: $!\n";
    syswrite($fh, $content);
    close($fh);

    rename("${filename}.lock", ${filename})
        or die "Can't rename ${filename}.lock to ${filename}: $!\n";
}

sub rename_section {
    my $self = shift;

    my (%args) = (
        from        => undef,
        to          => undef,
        filename    => undef,
        @_
    );

    die "No section to rename from given\n" unless defined $args{from};

    my $c = $self->_read_config($args{filename});
    # file couldn't be opened = nothing to rename
    return if !defined($c);

    ($args{from}, $args{to}) = map { $self->_remove_balanced_quotes($_) }
                                grep { defined $_ } ($args{from}, $args{to});

    my @replace;
    my $prev_matched = 0;
    $self->parse_content(
        content  => $c,
        callback => sub {
            my %got = @_;

            $replace[-1]->{section_is_last} = 0
                if (@replace && !defined($got{name}));

            if (lc($got{section}) eq lc($args{from})) {
                if (defined $got{name}) {
                    # if we're removing rather than replacing and
                    # there was a previous section match, increase
                    # its length so it will kill this variable
                    # assignment too
                    if ($prev_matched && !defined $args{to} ) {
                        $replace[-1]->{length} += ($got{offset} + $got{length})
                            - ($replace[-1]{offset} + $replace[-1]->{length});
                    }
                } else {
                    # if we're removing rather than replacing, increase
                    # the length of the previous match so when it's
                    # replaced it will kill all the way up to the
                    # beginning of this next section
                    $replace[-1]->{length} += $got{offset} -
                        ($replace[-1]->{offset} + $replace[-1]->{length})
                        if @replace && $prev_matched && !defined($args{to});

                    push @replace, {offset => $got{offset}, length =>
                        $got{length}, section_is_last => 1};
                    $prev_matched = 1;
                }
            } else {
                # if we're removing rather than replacing and there was
                # a previous section match, increase its length to kill all
                # the way up to this non-matching section (takes care
                # of newlines between here and there, etc.)
                $replace[-1]->{length} += $got{offset} -
                    ($replace[-1]->{offset} + $replace[-1]->{length})
                    if @replace && $prev_matched && !defined($args{to});
                $prev_matched = 0;
            }
        },
        error    => sub {
            die "Error parsing $args{filename}, near:\n@_\n";
        },
    );
    die "No such section '$args{from}'\n"
        unless @replace;

    # if the string we're replacing with is not the same length as what's
    # being replaced, any offsets following will be wrong. save the difference
    # between the lengths here and add it to any offsets that follow.
    my $difference = 0;

    # rename ALL section headers that matched to
    # (there may be more than one)
    my $replace_with = defined $args{to} ?
        $self->format_section( section => $args{to}, bare => 1 ) : '';

    for my $header (@replace) {
        substr(
            $c,
            $header->{offset} + $difference,
            # if we're removing the last section, just kill all the way to the
            # end of the file
            !defined($args{to}) && $header->{section_is_last} ? length($c) -
                ($header->{offset} + $difference) : $header->{length},
            $replace_with,
        );
        $difference += (length($replace_with) - $header->{length});
    }

    return $self->_write_config($args{filename}, $c);
}

sub remove_section {
    my $self = shift;

    my (%args) = (
        section     => undef,
        filename    => undef,
        @_
    );

    die "No section given to remove\n" unless $args{section};

    # remove section is just a rename to nothing
    return $self->rename_section( from => $args{section}, filename =>
        $args{filename} );
}

1;

__END__

=head1 NAME

Config::GitLike - git-compatible config file parsing

=head1 SYNOPSIS

This module parses git-style config files, which look like this:

    [core]
        repositoryformatversion = 0
        filemode = true
        bare = false
        logallrefupdates = true
    [remote "origin"]
        url = spang.cc:/srv/git/home.git
        fetch = +refs/heads/*:refs/remotes/origin/*
    [another-section "subsection"]
        key = test
        key = multiple values are OK
        emptyvalue =
        novalue

Code that uses this config module might look like:

    use Config::GitLike;

    my $c = Config::GitLike->new(confname => 'config');
    $c->load;

    $c->get( key => 'section.name' );
    # make the return value a Perl true/false value
    $c->get( key => 'core.filemode', as => 'bool' );

    # replace the old value
    $c->set(
        key => 'section.name',
        value => 'val1',
        filename => '/home/user/.config',
    );

    # make this key have multiple values rather than replacing the
    # old value
    $c->set(
        key => 'section.name',
        value => 'val2',
        filename => '/home/user/.config',
        multiple => 1,
    );

    # replace all occurrences of the old value for section.name with a new one
    $c->set(
        key => 'section.name',
        value => 'val3',
        filename => '/home/user/.config',
        multiple => 1,
        replace_all => 1,
    );

    # get only the value of 'section.name' that matches '2'
    $c->get( key => 'section.name', filter => '2' );
    $c->get_all( key => 'section.name' );
    # prefixing a search regexp with a ! negates it
    $c->get_regexp( key => '!na' );

    $c->rename_section(
        from => 'section',
        to => 'new-section',
        filename => '/home/user/.config'
    );

    $c->remove_section(
        section => 'section',
        filename => '/home/user/.config'
    );

    # unsets all instances of the given key
    $c->set( key => 'section.name', filename => '/home/user/.config' );

    my %config_vals = $config->dump;
    # string representation of config data
    my $str = $config->dump;
    # prints rather than returning
    $config->dump;

=head1 DESCRIPTION

This module handles interaction with configuration files of the style used
by the version control system Git. It can both parse and modify these
files, as well as create entirely new ones.

You only need to know a few things about the configuration format in order
to use this module. First, a configuration file is made up of key/value
pairs. Every key must be contained in a section. Sections can have
subsections, but they don't have to. For the purposes of setting and
getting configuration variables, we join the section name,
subsection name, and variable name together with dots to get a key
name that looks like "section.subsection.variable". These are the
strings that you'll be passing in to C<key> arguments.

Configuration files inherit from each other. By default, C<Config::GitLike>
loads data from a system-wide configuration file, a per-user
configuration file, and a per-directory configuration file, but by
subclassing and overriding methods you can obtain any combination of
configuration files. By default, configuration files that don't
exist are just skipped.

See
L<http://www.kernel.org/pub/software/scm/git/docs/git-config.html#_configuration_file>
for details on the syntax of git configuration files. We won't waste pixels
on the nitty gritty here.

While the behaviour of a couple of this module's methods differ slightly
from the C<git config> equivalents, this module can read any config file
written by git, and git can write any config file written by this module.

This is an object-oriented module using L<Any::Moose|Any::Moose>. All
subroutines are object method calls.

A few methods have arguments that are always used for the same purpose:

=head2 Filenames

All methods that change things in a configuration file require a filename to
write to, via the C<filename> argument. Since a C<Config::GitLike> object can
be working with multiple config files that inherit from each other, we don't
try to figure out which one to write to automatically and let you specify
instead.

=head2 Casting

All get and set methods can make sure the values they're returning or
setting are valid values of a certain type: C<bool>, C<int>,
C<num>, or C<bool-or-int> (or at least as close as Perl can get
to having these types). Do this by passing one of these types
in via the C<as> argument. The set method, if told to write
bools, will always write "true" or "false" (not anything else that
C<cast> considers a valid bool).

Methods that are told to cast values will throw exceptions if
the values they're trying to cast aren't valid values of the
given type.

See the L<cast|/"cast( value =E<gt> 'foo', as => 'int', human =E<gt> 1 )">
method documentation for more on what is considered valid for
each type.

=head2 Filtering

All get and set methods can filter what values they return via their
C<filter> argument, which is expected to be a string that is a valid
regex. If you want to filter items OUT instead of IN, you can
prefix your regex with a ! and that'll do the trick.

Now, on the the methods!

=head1 MAIN METHODS

There are the methods you're likely to use the most.

=head2 new( confname => 'config' )

Create a new configuration object with the base config name C<confname>.

C<confname> is used to construct the filenames that will be loaded; by
default, these are C</etc/confname> (global configuration file),
C<~/.confname> (user configuration file), and C<<Cwd>/.confname> (directory
configuration file).

You can override these defaults by subclassing C<Config::GitLike> and
overriding the methods C<global_file>, C<user_file>, and C<dir_file>. (See
L<"METHODS YOU MAY WISH TO OVERRIDE"> for details.)

=head2 confname

The configuration filename that you passed in when you created
the C<Config::GitLike> object. You can change it if you want by
passing in a new name (and then reloading via L<"load">).

=head2 load

Load the global, local, and directory configuration file with the filename
C<confname>(if they exist). Configuration variables loaded later
override those loaded earlier, so variables from the directory
configuration file have the highest precedence.

Returns a hash of all loaded configuration data stored in the module
after the files have been loaded, as a reference or a hash depending on
context.

=head2 get

Params:

    key => 'sect.subsect.key'
    as => 'int'
    filter => '!foo

Retrieve the config value associated with C<key> cast as an C<as>.

The C<key> option is required (will return undef if unspecified); the C<as>
option is not (will return a string by default). Sections and subsections
are specified in the key by separating them from the key name with a .
character. Sections, subsections, and keys may all be quoted (double or
single quotes).

If C<key> doesn't exist in the config, undef is returned. Dies with
the exception "Multiple values" if the given key has more than one
value associated with it. (Use L<"get_all"> to retrieve multiple values.)

Calls L<"load"> if it hasn't been done already. Note that if you've run any
C<set> calls to the loaded configuration files since the last time they were
loaded, you MUST call L<"load"> again before getting, or the returned
configuration data may not match the configuration variables on-disk.

=head2 get_all

Params:

    key => 'section.sub'
    filter => 'regex'
    as => 'int'

Like L<"get"> but does not fail if the number of values for the key is not
exactly one.

Returns a list of values (or an arrayref in scalar context).

=head2 get_regexp

Params:

    key => 'regex'
    filter => 'regex'
    as => 'bool'

Similar to L<"get_all"> but searches for values based on a key regex.

Returns a hash of name/value pairs (or a hashref in scalar context).

=head2 dump

In scalar context, return a string containing all configuration data, sorted in
ASCII order, in the form:

    section.key=value
    section2.key=value

If called in void context, this string is printed instead.

In list context, returns a hash containing all the configuration data.

=head2 set

Params:

    key => 'section.name'
    value => 'bar'
    filename => File::Spec->catfile(qw/home user/, '.'.$config->confname)
    filter => 'regex'
    as => 'bool'
    multiple => 1
    replace_all => 1

Set the key C<foo> in the configuration section C<section> to the value C<bar>
in the given filename.

Replace C<key>'s value if C<key> already exists.

To unset a key, pass in C<key> but not C<value>.

Returns true on success, undef if the filename was unopenable and thus no
set was performed.

=head3 multiple values

By default, set will replace the old value rather than giving a key multiple
values. To override this, pass in C<multiple =E<gt> 1>. If you want to replace
all instances of a multiple-valued key with a new value, you need to pass
in C<replace_all =E<gt> 1> as well.

=head2 rename_section

Params:

    from => 'name.subname'
    to => 'new.subname'
    filename => '/file/to/edit'

Rename the section existing in C<filename> given by C<from> to the section
given by C<to>.

Throws an exception C<No such section> if the section in C<from> doesn't exist
in C<filename>.

If no value is given for C<to>, the section is removed instead of renamed.

Returns true on success, false if C<filename> was un-openable and thus
the rename did nothing.

=head2 remove_section

Params:

    section => 'section.subsection'
    filename => '/file/to/edit

Just a convenience wrapper around L<"rename_section"> for readability's sake.
Removes the given section (which you can do by renaming to nothing as well).

=head1 METHODS YOU MAY WISH TO OVERRIDE

If your configuration layout is different from the default, e.g. if
your home directory config files are in a directory within the
home directory (like C<~/.git/config>) instead of just
dot-prefixed, override these methods to return the right
directory names. For fancier things like altering precedence,
you'll need to override L<"load"> as well.

=head2 dir_file

Return a string containing the path to a configuration file with the
name C<confname> in a directory. The directory isn't specified here.

=head2 global_file

Return a string representing the path to a system-wide configuration file with
name C<confname>.

=head2 user_file

Return a string containing the path to a configuration file
in the current user's home directory with filename C<confname>.

=head2 load_dirs

Load the configuration file with the filename L<"dir_file"> in the current
working directory into the C<data> attribute or, if there is no config
matching C<dir_file> in the current working directory, walk up the directory
tree until one is found. (No error is thrown if none is found.)

Returns nothing of note.

=head1 OTHER METHODS

These are mostly used internally, but hey, maybe you'll need them for
something.

=head2 set_multiple( $name )

Mark the key string C<$name> as containing multiple values.

Returns nothing.

=head2 is_multiple( $name )

Return a true value if the key string C<$name> contains multiple values; false
otherwise.

=head2 load_global

If a global configuration file with the absolute name given by
L<"global_file"> exists, load its configuration variables into memory.

Returns the current contents of all the loaded configuration variables
after the file has been loaded, or undef if no global config file is found.

=head2 load_user

If a configuration file with the absolute name given by
L<"user_file"> exists, load its config variables into memory.

Returns the current contents of all the loaded configuration variables
after the file has been loaded, or undef if no user config file is found.

=head2 load_file( $filename )

Takes a string containing the path to a file, opens it if it exists, loads its
config variables into memory, and returns the currently loaded config
variables (a hashref).

=head2 parse_content

Parameters:

    content => 'str'
    callback => sub {}
    error => sub {}

Takes arguments consisting of C<content>, a string of the content of the
configuration file to be parsed, C<callback>, a submethod to run on information
retrieved from the config file (headers, subheaders, and key/value pairs), and
C<error>, a submethod to run on malformed content. Parses the given content
and runs callbacks as it finds valid information.

Returns undef on success and C<error($content)> on failure.

C<callback> is called like:

    callback(section => $str, offset => $num, length => $num, name => $str, value => $str)

C<name> and C<value> may be omitted if the callback is not being called on a
key/value pair, or if it is being called on a key with no value.

C<error> is called like:

    error( content => $content, offset => $offset )

=head2 define

Params:

    section => 'str'
    name => 'str'
    value => 'str'

Given a section, a key name, and a value¸ store this information
in memory in the config object.

Returns the value that was just defined on success, or undef
if no name is given and thus the key cannot be defined.

=head2 cast

Params:

    value => 'foo'
    as => 'int'
    human => 1

Return C<value> cast into the type specified by C<as>.

Valid values for C<as> are C<bool>, C<int>, C<num>, or C<bool-or-num>. For
C<bool>, C<true>, C<yes>, C<on>, C<1>, and undef are translated into a true
value (for Perl); anything else is false. Specifying a true value for the
C<human> arg will get you a human-readable 'true' or 'false' rather than a
value that plays along with Perl's definition of truthiness (0 or 1).

For C<int>s and C<num>s, if C<value> ends in C<k>, C<m>, or C<g>, it will be
multiplied by 1024, 1048576, and 1073741824, respectively, before being
returned. C<int>s are truncated after being multiplied, if they have
a decimal portion.

C<bool-or-int>, as you might have guessed, gives you either
a bool or an int depending on which one applies.

If C<as> is unspecified, C<value> is returned unchanged.

=head2 format_section

Params:

    section => 'section.subsection'
    base => 1

Return a string containing the section/subsection header, formatted
as it should appear in a config file. If C<bare> is true, the returned
value is not followed be a newline.

=head2 format_definition

Params:

    key => 'str'
    value => 'str'
    bare => 1

Return a string containing the key/value pair as they should be printed in the
config file. If C<bare> is true, the returned value is not tab-indented nor
followed by a newline.

=head1 SEE ALSO

L<http://www.kernel.org/pub/software/scm/git/docs/git-config.html#_configuration_file>,
<Config::GitLike::Cascaded|Config::GitLike::Cascaded>

=head1 LICENSE

You may modify and/or redistribute this software under the same terms
as Perl 5.8.8.

=head1 COPYRIGHT

Copyright 2009 Best Practical Solutions, LLC

=head1 AUTHORS

Alex Vandiver <alexmv@bestpractical.com>
Christine Spang <spang@bestpractical.com>
