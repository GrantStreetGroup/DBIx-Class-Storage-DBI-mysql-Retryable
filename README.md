# NAME

DBIx::Class::Storage::DBI::mysql::Retryable - MySQL-specific DBIC storage engine with retry support

# VERSION

version v1.0.0

# SYNOPSIS

    package MySchema;

    # Recommended
    DBIx::Class::Storage::DBI::mysql::Retryable->_use_join_optimizer(0);

    __PACKAGE__->storage_type('::DBI::mysql::Retryable');

    # Optional settings (defaults shown)
    my $storage_class = 'DBIx::Class::Storage::DBI::mysql::Retryable';
    $storage_class->parse_error_class('DBIx::ParseError::MySQL');
    $storage_class->timer_class('Algorithm::Backoff::RetryTimeouts');
    $storage_class->timer_options({});           # same defaults as the timer class
    $storage_class->aggressive_timeouts(0);
    $storage_class->warn_on_retryable_error(0);
    $storage_class->enable_retryable(1);

# DESCRIPTION

This storage engine for [DBIx::Class](https://metacpan.org/pod/DBIx%3A%3AClass) is a MySQL-specific engine that will explicitly
retry on MySQL-specific transient error messages, as identified by [DBIx::ParseError::MySQL](https://metacpan.org/pod/DBIx%3A%3AParseError%3A%3AMySQL),
using [Algorithm::Backoff::RetryTimeouts](https://metacpan.org/pod/Algorithm%3A%3ABackoff%3A%3ARetryTimeouts) as its retry algorithm.  This engine should be
much better at handling deadlocks, connection errors, and Galera node flips to ensure the
transaction always goes through.

## How Retryable Works

A DBIC command triggers some sort of connection to the MySQL server to send SQL.  First,
Retryable makes sure the connection `mysql_*_timeout` values (except `mysql_read_timeout`
unless ["aggressive\_timeouts"](#aggressive_timeouts) is set) are set properly.  (The default settings for
[RetryTimeouts](https://metacpan.org/pod/Algorithm%3A%3ABackoff%3A%3ARetryTimeouts#Typical-scenario) will use half of the
maximum duration, with some jitter.)  If the connection was successful, a few `SET SESSION`
commands for timeouts are sent first:

    wait_timeout   # only with aggressive_timeouts=1
    lock_wait_timeout
    innodb_lock_wait_timeout
    net_read_timeout
    net_write_timeout

If the DBIC command fails at any point in the process, and the error is a recoverable
failure (according to the [error parsing class](https://metacpan.org/pod/DBIx%3A%3AParseError%3A%3AMySQL)), the retry
process starts.

The timeouts are only checked during the retry handler.  Since DB operations are XS
calls, Perl-style "safe" ALRM signals won't do any good, and the engine won't attempt to
use unsafe ones.  Thus, the engine relies on the server to honor the timeouts set during
each attempt, and will give up if it runs out of time or attempts.

If the DBIC command succeeds during the process, program flow resumes as normal.  If any
re-attempts happened during the DBIC command, the timeouts are reset back to the original
post-connection values.

# STORAGE OPTIONS

## parse\_error\_class

Class used to parse MySQL error messages.

Default is [DBIx::ParseError::MySQL](https://metacpan.org/pod/DBIx%3A%3AParseError%3A%3AMySQL).  If a different class is used, it must support a
similar interface, especially the [`is_transient`](https://metacpan.org/pod/DBIx%3A%3AParseError%3A%3AMySQL#is_transient)
method.

## timer\_class

Algorithm class used to determine timeout and sleep values during the retry process.

Default is [Algorithm::Backoff::RetryTimeouts](https://metacpan.org/pod/Algorithm%3A%3ABackoff%3A%3ARetryTimeouts).  If a different class is used, it must
support a similar interface, including the dual return of the [`failure`](https://metacpan.org/pod/Algorithm%3A%3ABackoff%3A%3ARetryTimeouts#failure)
method.

## timer\_options

Options to pass to the timer algorithm constructor, as a hashref.

Default is an empty hashref, which would retain all of the defaults of the algorithm
module.

## aggressive\_timeouts

Boolean that controls whether to use some of the more aggressive, query-unfriendly
timeouts:

- mysql\_read\_timeout

    Controls the timeout for all read operations.  Since SQL queries in the middle of
    sending its first set of row data are still considered to be in a read operation, those
    queries could time out during those circumstances.

    If you're confident that you don't have any SQL statements that would take longer than
    `R/2` (or at least returning results before that time), you can turn this option on.
    Otherwise, you may experience longer-running statements going into a retry death spiral
    until they finally hit the Retryable timeout for good and die.

- wait\_timeout

    Controls how long the MySQL server waits for activity from the connection before timing
    out.  While most applications are going to be using the database connection pretty
    frequently, the MySQL default (8 hours) is much much longer than the mere seconds this
    engine would set it to.

Default is off.  Obviously, this setting only makes sense with ["retryable\_timeout"](#retryable_timeout)
turned on.

## warn\_on\_retryable\_error

Boolean that controls whether to warn on retryable failures, as the engine encounters
them.  Many applications don't want spam on their screen for recoverable conditions, but
this may be useful for debugging or CLI tools.

Unretryable failures always generate an exception as normal, regardless of the setting.

This is functionally equivalent to ["PrintError" in DBI](https://metacpan.org/pod/DBI#PrintError), but since ["RaiseError"](https://metacpan.org/pod/DBI#RaiseError)
is already the DBIC-required default, the former option can't be used within DBI.

Default is off.

## enable\_retryable

Boolean that enables the Retryable logic.  This can be turned off to temporarily disable
it, and revert to DBIC's basic "retry once if disconnected" default.  This may be useful
if a process is already using some other retry logic (like [DBIx::OnlineDDL](https://metacpan.org/pod/DBIx%3A%3AOnlineDDL)).

Messing with this setting in the middle of a database action would not be wise.

Default is on.

# METHODS

## dbh\_do

    my $val = $schema->storage->dbh_do(
        sub {
            my ($storage, $dbh, @binds) = @_;
            $dbh->selectrow_array($sql, undef, @binds);
        },
        @passed_binds,
    );

This is very much like ["dbh\_do" in DBIx::Class::Storage::DBI](https://metacpan.org/pod/DBIx%3A%3AClass%3A%3AStorage%3A%3ADBI#dbh_do), except it doesn't require a
connection failure to retry the sub block.  Instead, it will also retry on locks, query
interruptions, and failovers.

Normal users of DBIC typically won't use this method directly.  Instead, any ResultSet
or Result method that contacts the DB will send its SQL through here, and protect it from
retryable failures.

However, this method is recommended over using `$schema->storage->dbh` directly to
run raw SQL statements.

## txn\_do

    my $val = $schema->txn_do(
        sub {
            # ...DBIC calls within transaction...
        },
        @misc_args_passed_to_coderef,
    );

Works just like ["txn\_do" in DBIx::Class::Storage](https://metacpan.org/pod/DBIx%3A%3AClass%3A%3AStorage#txn_do), except it's now protected against
retryable failures.

Calling this method through the `$schema` object is typically more convenient.

## throw\_exception

    $storage->throw_exception('It failed');

Works just like ["throw\_exception" in DBIx::Class::Storage](https://metacpan.org/pod/DBIx%3A%3AClass%3A%3AStorage#throw_exception), but also reports attempt and
timer statistics, in case the transaction was tried multiple times.

# CAVEATS

## Transactions without txn\_do

Retryable is transaction-safe.  Only the outermost transaction depth gets the retry
protection, since that's the only layer that is idempotent and atomic.

However, transaction commands like `txn_begin` and `txn_scope_guard` are NOT granted
retry protection, because DBIC/Retryable does not have a defined transaction-safe code
closure to use upon reconnection.  Only `txn_do` will have the protections available.

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

## (Ab)using $dbh directly

Similar to `txn_begin`, directly accessing and using a DBI database or statement handle
does NOT grant retry protection, even if they are acquired from the storage engine via
`$storage->dbh`.

Instead, use ["dbh\_do"](#dbh_do).  This method is also used by DBIC for most of its active DB
calls, after it has composed a proper SQL statement to run.

# SEE ALSO

[DBIx::Connector::Retry::MySQL](https://metacpan.org/pod/DBIx%3A%3AConnector%3A%3ARetry%3A%3AMySQL) - A similar engine for DBI connections, using [DBIx::Connector::Retry](https://metacpan.org/pod/DBIx%3A%3AConnector%3A%3ARetry) as a base.

[DBIx::Class::Storage::BlockRunner](https://metacpan.org/pod/DBIx%3A%3AClass%3A%3AStorage%3A%3ABlockRunner) - Base module in DBIC that controls how transactional coderefs are ran and retried

# AUTHOR

Grant Street Group <developers@grantstreet.com>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2021 by Grant Street Group.

This is free software, licensed under:

    The Artistic License 2.0 (GPL Compatible)
