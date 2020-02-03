#!/usr/bin/perl

use lib qw(t/lib);
use strict;
use warnings;

use Test2::Bundle::More;
use Test2::Tools::Compare;
use Test2::Tools::Exception;
use Test2::Tools::Explain;

use DBIx::Class::Storage::DBI::mysql::Retryable;

use Env         qw< CDTEST_DSN >;
use Time::HiRes qw< time sleep >;

use CDTest;

############################################################

CDTest::Schema->storage_type('::DBI::mysql::Retryable');

### DEBUG
#DBIx::Class::Storage::DBI::mysql::Retryable->warn_on_retryable_error(1);

my $schema = CDTest->init_schema(
    no_deploy   => 1,
    no_preclean => 1,
    no_populate => 1,
);
my $storage = $schema->storage;

# The SQL and the lack of a real database doesn't really matter, since the sole purpose
# of this engine is to handle certain exceptions and react to them.  However,
# running this with a proper MySQL CDTEST_DSN would grant some additional $dbh checks.

our $EXEC_COUNTER    = 0;
our $EXEC_SUCCESS_AT = 4;
our $EXEC_SLEEP_TIME = 0.5;
our @EXEC_ERRORS     = (
    'Deadlock found when trying to get lock; try restarting transaction',
    'Lock wait timeout exceeded; try restarting transaction',
    'MySQL server has gone away',
    'Lost connection to MySQL server during query',
    'WSREP has not yet prepared node for application use',
    'Server shutdown in progress',
);

no warnings 'redefine';
*DBIx::Class::Storage::DBI::_dbh_execute = sub {
    my ($self, $dbh, $sql, $bind, $bind_attrs) = @_;

    # The SQL is always SELECT 1 for the UPDATEs, but not for SET SESSION commands
    $sql = 'SELECT 1' if $sql =~ /UPDATE/i;

    my $sth = $self->_bind_sth_params(
        $self->_prepare_sth($dbh, $sql),
        [],
        {},
    );

    sleep $EXEC_SLEEP_TIME if $EXEC_SLEEP_TIME;

    # Zero-based error, then one-based counter MOD check
    my $error = $EXEC_ERRORS[ $EXEC_COUNTER % @EXEC_ERRORS ];

    $EXEC_COUNTER++;
    $self->throw_exception(
        "DBI Exception: DBD::mysql::st execute failed: $error"
    ) if $EXEC_COUNTER % $EXEC_SUCCESS_AT;  # only success at exact divisors

    my $rv = '0E0';

    return (wantarray ? ($rv, $sth, @$bind) : $rv);
};
use warnings 'redefine';

sub run_update_test {
    my %args = @_;

    # Defaults
    $args{duration} //= 0;   # assume complete success
    $args{attempts} //= 1;
    $args{timeout}  //= 25;  # half of 50s timeout

    SKIP: {
        # SQLite does not recognize SET SESSION commands
        skip "CDTEST_DSN not set to a MySQL DB for a retryable_timeout test", 12
            if $storage->retryable_timeout && !($CDTEST_DSN && $CDTEST_DSN =~ /^dbi:mysql:/);

        # Changing storage variables may require some resetting
        $storage->connect_info( $storage->_connect_info );
        $storage->disconnect;

        my $start_time = time;

        if ($args{exception}) {
            like(
                dies {
                    $schema->resultset('Track')->update({ track_id => 1 });
                },
                $args{exception},
                'SQL dies with proper exception',
            );
        }
        else {
            try_ok {
                $schema->resultset('Track')->update({ track_id => 1 });
            }
            'SQL successful';
        }

        # Always add two seconds for lag and code runtimes
        my $duration = time - $start_time;
        note sprintf "Duration: %.2f seconds (range: %u-%u)", $duration, $args{duration}, $args{duration} + 2;
        cmp_ok $duration, '>=', $args{duration},     'expected duration (>=)';
        cmp_ok $duration, '<=', $args{duration} + 2, 'expected duration (<=)';

        is $EXEC_COUNTER,      $args{attempts}, 'expected attempts counter';

        SKIP: {
            skip "CDTEST_DSN not set to a MySQL DB",           8 unless $CDTEST_DSN && $CDTEST_DSN =~ /^dbi:mysql:/;
            skip "Retryable timeouts are not on in this test", 8 unless $storage->retryable_timeout;
            skip "Retryable is disabled",                      8 if     $storage->disable_retryable;

            my $dbh           = $storage->_dbh;
            my $connect_attrs = $storage->_dbi_connect_info->[3];
            is $connect_attrs->{$_}, $args{timeout}, "$_ (attr) was reset" for map { "mysql_${_}_timeout" } qw< connect read write >;

            my $timeout_vars = $dbh->selectall_hashref("SHOW VARIABLES LIKE '%_timeout'", 'Variable_name');
            is $timeout_vars->{$_}{Value}, $args{timeout}, "$_ (session var) was reset" for map { "${_}_timeout" } qw<
                wait lock_wait innodb_lock_wait net_read net_write
            >;
        };
    };
}

############################################################

subtest 'clean_test' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 1;

    run_update_test;
};

subtest 'clean_test_with_retryable_timeout' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 1;

    $storage->retryable_timeout(50);

    run_update_test;

    $storage->retryable_timeout(0);
};

subtest 'clean_test_with_disable_retryable' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 1;

    $storage->disable_retryable(1);

    run_update_test;

    $storage->disable_retryable(0);
};

subtest 'recoverable_failures' => sub {
    local $EXEC_COUNTER    = 0;

    run_update_test(
        duration => 1.41 + 2 + 2.83,  # hitting minimum exponential timeouts each time
        attempts => $EXEC_SUCCESS_AT,
    );
};

subtest 'recoverable_failures_with_longer_pauses' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SLEEP_TIME = 3;

    run_update_test(
        duration => $EXEC_SUCCESS_AT * $EXEC_SLEEP_TIME,
        attempts => $EXEC_SUCCESS_AT,
    );
};

subtest 'non_retryable_failure' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SLEEP_TIME = 3;
    local @EXEC_ERRORS     = (
        'MySQL server has gone away',
        "Duplicate entry '1-1' for key 'PRIMARY'",
    );

    run_update_test(
        duration  => 2 * $EXEC_SLEEP_TIME,
        attempts  => 2,
        exception => qr/Duplicate entry .+ for key/,
    );
};

subtest 'ran_out_of_attempts' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 8;
    local $EXEC_SLEEP_TIME = 2;

    $storage->max_attempts(4);

    run_update_test(
        duration  => 4 * $EXEC_SLEEP_TIME,
        attempts  => 4,
        exception => qr/Reached max_attempts amount of 4, latest exception:.+DBI Exception: DBD::mysql::st execute failed: Lost connection to MySQL server during query/,
    );

    $storage->max_attempts(8);
};

subtest 'recoverable_failures_with_retryable_timeout' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SLEEP_TIME = 2;

    $storage->retryable_timeout(20);

    run_update_test(
        duration => $EXEC_SUCCESS_AT * $EXEC_SLEEP_TIME,
        attempts => $EXEC_SUCCESS_AT,
        timeout  => 10,  # half of 20s timeout
    );

    $storage->retryable_timeout(0);
};

subtest 'ran_out_of_time' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 8;
    local $EXEC_SLEEP_TIME = 5;

    $storage->retryable_timeout(22);

    run_update_test(
        duration  => 25,  # should get a 5s timeout after the fourth attempt
        attempts  => 5,
        timeout   => 11,  # half of 22s timeout
        exception => qr/DBI Exception: DBD::mysql::st execute failed: WSREP has not yet prepared node for application use/,
    );

    $storage->retryable_timeout(0);
};

subtest 'failure_with_disable_retryable' => sub {
    local $EXEC_COUNTER    = 0;
    local $EXEC_SUCCESS_AT = 8;
    local $EXEC_SLEEP_TIME = 5;

    $storage->disable_retryable(1);

    run_update_test(
        duration  => 5,
        attempts  => 1,
        exception => qr/DBI Exception: DBD::mysql::st execute failed: Deadlock found when trying to get lock; try restarting transaction/,
    );

    $storage->disable_retryable(0);
};

############################################################

done_testing;
