package DBIx::Class::Storage::DBI::mysql::Retryable;

use strict;
use warnings;

use base qw< DBIx::Class::Storage::DBI::mysql >;

use Context::Preserve;
use DBIx::ParseError::MySQL;
use List::Util  qw< min max >;
use POSIX       qw< floor >;
use Time::HiRes qw< time sleep >;
use namespace::clean;

# ABSTRACT: MySQL-specific DBIC storage engine with retry support
# VERSION

__PACKAGE__->mk_group_accessors('inherited' => qw<
    parse_error_class
    max_attempts retryable_timeout aggressive_timeouts
    warn_on_retryable_error disable_retryable
>);

__PACKAGE__->mk_group_accessors('simple' => qw<
    _retryable_first_attempt_time _retryable_last_attempt_time
    _retryable_current_timeout
>);

# Set defaults
__PACKAGE__->parse_error_class('DBIx::ParseError::MySQL');
__PACKAGE__->max_attempts(8);
__PACKAGE__->retryable_timeout(0);
__PACKAGE__->aggressive_timeouts(0);
__PACKAGE__->warn_on_retryable_error(0);
__PACKAGE__->disable_retryable(0);

=head1 SYNOPSIS

    package MySchema;

    # Recommended
    DBIx::Class::Storage::DBI::mysql::Retryable->_use_join_optimizer(0);

    __PACKAGE__->storage_type('::DBI::mysql::Retryable');

    # Optional settings
    my $storage_class = 'DBIx::Class::Storage::DBI::mysql::Retryable';
    $storage_class->max_attempts(8);             # default
    $storage_class->retryable_timeout(50);       # default is 0 (off)
    $storage_class->aggressive_timeouts(0);      # default
    $storage_class->warn_on_retryable_error(0);  # default
    $storage_class->disable_retryable(0);        # default

=head1 DESCRIPTION

This storage engine for L<DBIx::Class> is a MySQL-specific engine that implements better
retry support, based on common retryable MySQL errors.  This engine should be much better
at handling deadlocks, connection errors, and Galera node flips to ensure the transaction
always goes through.

=head2 How Retryable Works

=head3 Without retryable_timeout

A DBIC command triggers some sort of connection to the MySQL server to send SQL.  If that
fails at any point in the process, and the error is a recoverable failure (deadlocks,
connection failures, etc.), the retry process starts:

    Die if connected and error is not retryable

    Warn about error if warn_on_retryable_error is on

    S = 2 ** (A/2) seconds (A=Attempt count)
        (ie: 1.4, 2, 2.8, 4, 5.7, 8, etc.)

    If the last attempt (LAS) took under S seconds:
        Sleep for S-LAS seconds

    Force disconnection of database handle

    Retry and repeat, stopping on max_attempts

=head3 With retryable_timeout

A DBIC command triggers some sort of connection to the MySQL server to send SQL.  First,
Retryable makes sure the connection C<mysql_*_timeout> values (except C<mysql_read_timeout>
unless L</aggressive_timeouts> is set) are set to one-half of the L</retryable_timeout>
setting ("R").  If the connection was successful, a few C<SET SESSION> commands for
timeouts are sent first:

    wait_timeout   # only with aggressive_timeouts=1
    lock_wait_timeout
    innodb_lock_wait_timeout
    net_read_timeout
    net_write_timeout

These are all set to C<R/2> as well.  If the DBIC command fails at any point in the
process, and the error is a recoverable failure (deadlocks, connection failures, etc.),
the retry process starts:

    Die if connected and error is not retryable

    Warn about error if warn_on_retryable_error is on

    Calculate the time left (T), based on R and the first attempt time

    Die if we're out of time

    S = 2 ** (A/2) seconds (A=Attempt count)
        (ie: 1.4, 2, 2.8, 4, 5.7, 8, etc.)

    If the last attempt (LAS) took under S seconds:
        Sleep for S-LAS or T/2 seconds, whichever is smaller
        T is readjusted

    Force disconnection of database handle

    Re-connection will use T/2 or 5 seconds for timeouts, whichever is larger
        (This includes SET SESSION commands.)

    Retry and repeat, stopping on max_attempts

If any re-attempts happened during the DBIC command, the timeouts are reset back to
C<R/2>.

=head1 STORAGE OPTIONS

=head2 max_attempts

Number of re-connection attempts before L<DBIx::Class::Storage::BlockRunner> gives up and
dies with the last error.  If the response was quick, each attempt will sleep for
C<< 2 ** (A/2) >> seconds (ie: 1.4, 2, 2.8, 4, etc.) to give the DB a chance to clear its
error.

Default is 8, which would have a total exponential backoff period of 51.2 seconds, for
quick errors.

=head2 retryable_timeout

Timeout value set to time the entire duration of a DB transaction, including retries.
This is different than the usual timeout values for MySQL that only affect the connection
or a single try.

The timeouts are only checked during the retry handler.  Since the DB operations are XS
calls, Perl-style "safe" ALRM signals won't do any good, and the engine won't attempt to
use unsafe ones.  However, it will auto-adjust MySQL timeouts based on how much time it
has left.

Default is off.

=head2 aggressive_timeouts

Boolean that controls whether to use some of the more aggressive, query-unfriendly
timeouts:

=over

=item mysql_read_timeout

Controls the timeout for all read operations.  Since SQL queries in the middle of
sending its first set of row data are still considered to be in a read operation, those
queries could time out during those circumstances.

If you're confident that you don't have any SQL statements that would take longer than
C<R/2> (or at least returning results before that time), you can turn this option on.
Otherwise, you may experience longer-running statements going into a retry death spiral
until they finally hit the Retryable timeout for good and die.

=item wait_timeout

Controls how long the MySQL server waits for activity from the connection before timing
out.  While most applications are going to be using the database connection pretty
frequently, the MySQL default (8 hours) is much much longer than the mere seconds this
engine would set it to.

=back

Default is off.  Obviously, this setting only makes sense with L</retryable_timeout>
turned on.

=head2 warn_on_retryable_error

Boolean that controls whether to warn on retryable failures, as the engine encounters
them.  Many applications don't want spam on their screen for recoverable conditions, but
this may be useful for debugging or CLI tools.

Unretryable failures always generate an exception as normal, regardless of the setting.

This is functionally equivalent to L<DBI/PrintError>, but since L<"RaiseError"|DBI/RaiseError>
is already the DBIC-required default, the former option can't be used within DBI.

Default is off.

=head2 disable_retryable

Boolean to temporarily disable the Retryable logic, and revert to DBIC's basic "retry
once if disconnected" default.  This may be useful if a process is already using some
other retry logic (like L<DBIx::OnlineDDL>).

Messing with this setting in the middle of a database action would not be wise.

Default is off.

=head1 METHODS

=cut

# Return the list of timeout strings to check
sub _timeout_set_list {
    my ($self, $type) = @_;

    my @timeout_set;
    if    ($type eq 'dbi') {
        @timeout_set = (qw< connect write >);
        push @timeout_set, 'read' if $self->aggressive_timeouts;

        @timeout_set = map { "mysql_${_}_timeout" } @timeout_set;
    }
    elsif ($type eq 'session') {
        @timeout_set = (qw< lock_wait innodb_lock_wait net_read net_write >);
        push @timeout_set, 'wait' if $self->aggressive_timeouts;

        @timeout_set = map { "${_}_timeout" } @timeout_set;
    }
    else {
        die "Unknown mysql timeout set: $type";
    }

    return @timeout_set;
}

# Set the timeouts for reconnections by inserting them into the default DBI connection
# attributes.
sub _default_dbi_connect_attributes () {
    my $self = shift;
    return $self->next::method unless $self->retryable_timeout && !$self->disable_retryable;

    # Set the current timeout, if we need to.  This may be the case for the initial
    # connection.
    $self->_retryable_current_timeout(
        $self->retryable_timeout / 2
    ) unless $self->_retryable_current_timeout;

    my $timeout = floor $self->_retryable_current_timeout;

    return +{
        (map {; $_ => $timeout } $self->_timeout_set_list('dbi')),  # set timeouts
        mysql_auto_reconnect => 0,  # do not use MySQL's own reconnector
        %{ $self->next::method },   # inherit the other default attributes
    };
}

# Re-apply the timeout settings above on _dbi_connect_info.  Used after the initial
# connection by the retry handling.
sub _set_dbi_connect_info {
    my $self = shift;
    return unless $self->retryable_timeout && !$self->disable_retryable;

    # Set the current timeout, if we need to
    $self->_retryable_current_timeout(
        $self->retryable_timeout / 2
    ) unless $self->_retryable_current_timeout;

    my $timeout = floor $self->_retryable_current_timeout;

    my $info = $self->_dbi_connect_info;

    # Not even going to attempt this one...
    if (ref $info eq 'CODE') {
        warn <<"EOW" unless $ENV{DBIC_RETRYABLE_DONT_SET_CONNECT_SESSION_VARS};

***************************************************************************
Your connect_info is a coderef, which means connection-based MySQL timeouts
cannot be dynamically changed. Under certain conditions, the connection (or
combination of connection attempts) may take longer to timeout than your
current retryable_timeout setting.

You'll want to revert to a 4-element style DBI argument set, to fully
support the retryable_timeout functionality.

To disable this warning, set a true value to the environment variable
DBIC_RETRYABLE_DONT_SET_CONNECT_SESSION_VARS

***************************************************************************
EOW
        return;
}

    my $dbi_attr = $info->[3];
    return unless $dbi_attr && ref $dbi_attr eq 'HASH';

    $dbi_attr->{$_} = $timeout for $self->_timeout_set_list('dbi');
}

# Set session timeouts for post-connection variables
sub _run_connection_actions {
    my $self = shift;
    $self->_set_retryable_session_timeouts;
    $self->next::method(@_);
}

sub _set_retryable_session_timeouts {
    my $self = shift;
    return unless $self->retryable_timeout && !$self->disable_retryable;

    # Set the current timeout, if we need to
    $self->_retryable_current_timeout(
        $self->retryable_timeout / 2
    ) unless $self->_retryable_current_timeout;

    my $timeout = floor $self->_retryable_current_timeout;

    # Ironically, we aren't running our own SET SESSION commands with their own
    # BlockRunner protection, since that may lead to infinite stack recursion.  Instead,
    # put it in a basic eval, and do a quick is_transient check.  If it passes, let the
    # next *_do/_do_query call handle it.

    local $@;
    eval {
        my $dbh = $self->_dbh;
        if ($dbh) {
            $dbh->do("SET SESSION $_=$timeout") for $self->_timeout_set_list('session');
        }
    };
    if (my $error = $@) {
        my $parsed_error = $self->parse_error_class->new($error);
        die unless $parsed_error->is_transient;  # bare die for $@ propagation
        warn "Encountered a recoverable error during SET SESSION timeout commands: $error" if $self->warn_on_retryable_error;
    }
}

# Make sure the initial connection call is protected from retryable failures
sub _connect {
    my $self = shift;
    return $self->next::method() if $self->disable_retryable;
    # next::can here to do mro calculations prior to sending to _blockrunner_do
    return $self->_blockrunner_do( _connect => $self->next::can() );
}

=head2 dbh_do

    my $val = $schema->storage->dbh_do(
        sub {
            my ($storage, $dbh, @binds) = @_;
            $dbh->selectrow_array($sql, undef, @binds);
        },
        @passed_binds,
    );

This is very much like L<DBIx::Class::Storage::DBI/dbh_do>, except it doesn't require a
connection failure to retry the sub block.  Instead, it will also retry on locks, query
interruptions, and failovers.

Normal users of DBIC typically won't use this method directly.  Instead, any ResultSet
or Result method that contacts the DB will send its SQL through here, and protect it from
retryable failures.

However, this method is recommended over using C<< $schema->storage->dbh >> directly to
run raw SQL statements.

See also: L<DBIx::Class::Storage::BlockRunner>.

=cut

# Main "doer" method for both dbh_do and txn_do
sub _blockrunner_do {
    my $self       = shift;
    my $call_type  = shift;
    my $run_target = shift;

    # See https://metacpan.org/release/DBIx-Class/source/lib/DBIx/Class/Storage/DBI.pm#L842
    my $args = @_ ? \@_ : [];

    my $target_runner = sub {
        # dbh_do and txn_do have different sub arguments, and _connect shouldn't
        # have a _get_dbh call.
        if    ($call_type eq 'txn_do')   { $run_target->( @$args ); }
        elsif ($call_type eq 'dbh_do')   { $self->$run_target( $self->_get_dbh, @$args ); }
        elsif ($call_type eq '_connect') { $self->$run_target( @$args ); }
        else { die "Unknown call type: $call_type" }
    };

    # Transaction depth short circuit (same as DBIx::Class::Storage::DBI)
    return $target_runner->() if $self->{_in_do_block} || $self->transaction_depth;

    # Given our transaction depth short circuits, we should be at the outermost loop,
    # so it's safe to reset our variables.
    my $epoch = time;
    $self->_retryable_first_attempt_time($epoch);
    $self->_retryable_last_attempt_time($epoch);
    $self->_retryable_current_timeout( $self->retryable_timeout / 2 ) if $self->retryable_timeout;

    # We have some post-processing to do, so save the BlockRunner object, and then save
    # the result in a context-sensitive manner.
    my $br = DBIx::Class::Storage::BlockRunner->new(
        storage       => $self,
        wrap_txn      => $call_type eq 'txn_do',
        max_attempts  => $self->max_attempts,
        retry_handler => \&_blockrunner_retry_handler,
    );

    return preserve_context {
        $br->run($target_runner);
    }
    after => sub { $self->_reset_counters_and_timers($br) };
}

# Our own BlockRunner retry handler
sub _blockrunner_retry_handler {
    my $br   = shift;
    my $self = $br->storage;  # "self" for this module

    my ($failed, $max, $last_error) = ($br->failed_attempt_count, $br->max_attempts, $br->last_exception);

    # If it's not a retryable error, stop here
    my $parsed_error = $self->parse_error_class->new($last_error);
    return $self->_reset_counters_and_timers($br) unless $parsed_error->is_transient;

    $last_error =~ s/\n.+//s;
    warn "\nEncountered a recoverable error during attempt $failed of $max: $last_error\n\n" if $self->warn_on_retryable_error;

    # Figure out all of the times, timers, and timeouts
    my $epoch = time;

    my $this_attempt_time  = $epoch - $self->_retryable_last_attempt_time;
    my $total_attempt_time = $epoch - $self->_retryable_first_attempt_time;

    my $sleep_time = 2 ** ($failed / 2) - $this_attempt_time;
    my $time_left  = $self->retryable_timeout ?
        $self->retryable_timeout - $total_attempt_time :
        86400  # infinity, basically
    ;
    my $max_timeout = $time_left / 2;
    $sleep_time = min(max(0, $sleep_time), $max_timeout);  # make $sleep_time between 0 and $max_timeout

    # Time's up!
    return $self->_reset_counters_and_timers($br) if $time_left < 0;

    # If the response was quick and below our attempt timer, sleep for a bit
    if ($sleep_time > 0) {
        sleep $sleep_time;
        $time_left  -= $sleep_time;
        $max_timeout = $time_left / 2;
    }

    if ($self->retryable_timeout) {
        # Use half of the time we have left for the next timeout, but make sure it's at least
        # five seconds
        my $new_timeout = floor( max($max_timeout, 5) );
        $self->_retryable_current_timeout($new_timeout);

        # Reset the connection timeouts before we connect again
        $self->_set_dbi_connect_info;
    }

    # Include reconnection costs in the next attempt time calculations
    $self->_retryable_last_attempt_time(time);

    # Force a disconnect
    local $@;
    eval { local $SIG{__DIE__}; $self->disconnect };

    # Because BlockRunner calls this unprotected, and because our own _connect is going
    # to hit the _in_do_block short-circuit, we should call this ourselves, in a
    # protected eval, and re-direct any errors as if it was another failed attempt.
    eval { $self->ensure_connected };
    if (my $connect_error = $@) {
        push @{ $br->exception_stack }, $connect_error;

        # This will throw if max_attempts is reached
        $br->_set_failed_attempt_count($br->failed_attempt_count + 1);

        return _blockrunner_retry_handler($br);
    }

    return 1;
}

sub _reset_counters_and_timers {
    my ($self, $br) = @_;

    $self->_retryable_first_attempt_time(0);
    $self->_retryable_last_attempt_time(0);

    # Only reset timeouts if we have to
    if ($br->failed_attempt_count && $self->retryable_timeout) {
        $self->_retryable_current_timeout(0);  # gets set back to R/2
        $self->_set_dbi_connect_info;
        $self->_set_retryable_session_timeouts;
    }

    # Useful for chaining to the return call in _blockrunner_retry_handler
    return undef;
}

sub dbh_do {
    my $self = shift;
    return $self->next::method(@_) if $self->disable_retryable;
    return $self->_blockrunner_do( dbh_do => @_ );
}

=head2 txn_do

    my $val = $schema->txn_do(
        sub {
            # ...DBIC calls within transaction...
        },
        @misc_args_passed_to_coderef,
    );

Works just like L<DBIx::Class::Storage/txn_do>, except it's now protected against
retryable failures.

Calling this method through the C<$schema> object is typically more convenient.

=cut

sub txn_do {
    my $self = shift;
    return $self->next::method(@_) if $self->disable_retryable;

    # Connects or reconnects on pid change to grab correct txn_depth (same as
    # DBIx::Class::Storage::DBI)
    $self->_get_dbh;

    $self->_blockrunner_do( txn_do => @_ );
}

=head1 CAVEATS

=head2 Transactions without txn_do

Retryable is transaction-safe.  Only the outermost transaction depth gets the retry
protection, since that's the only layer that is idempotent and atomic.

However, transaction commands like C<txn_begin> and C<txn_scope_guard> are NOT granted
retry protection, because DBIC/Retryable does not have a defined transaction-safe code
closure to use upon reconnection.  Only C<txn_do> will have the protections available.

For example:

    # Has retry protetion
    my $rs = $schema->resultset('Foo');
    $rs->delete;

    # This effectively turns off retry protection
    $schema->txn_begin;

    # NOT protected from retryable errors!
    my $result = $rs->create({bar => 12});
    $result->update({baz => 42});

    $schema->txn_commit;
    # Retry protection is back on

    # Do this instead!
    $schema->txn_do(sub {
        my $result = $rs->create({bar => 12});
        $result->update({baz => 42});
    });

    # Still has retry protection
    $rs->delete;

All of this behavior mimics how DBIC's original storage engines work.

=head2 (Ab)using $dbh directly

Similar to C<txn_begin>, directly accessing and using a DBI database or statement handle
does NOT grant retry protection, even if they are acquired from the storage engine via
C<< $storage->dbh >>.

Instead, use L</dbh_do>.  This method is also used by DBIC for most of its active DB
calls, after it has composed a proper SQL statement to run.

=cut

1;
