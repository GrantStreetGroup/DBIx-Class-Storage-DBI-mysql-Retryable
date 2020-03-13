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

my $schema = CDTest->init_schema(
    no_deploy   => 1,
    no_preclean => 1,
    no_populate => 1,
);
my $storage = $schema->storage;

my %isa_checks = (
    dbh_do => [qw<
        DBIx::Class::Storage::DBI::mysql::Retryable
        DBI::db
        CDTest::Track
    >,  ''
    ],
    txn_do => [ 'CDTest::Track', '' ],
    _connect => ['DBIx::Class::Storage::DBI::mysql::Retryable'],
);

no warnings 'redefine';
*DBIx::Class::Storage::DBI::_dbh_execute = sub {
    my ($self, $dbh, $sql, $bind, $bind_attrs) = @_;

    my $sth = $self->_bind_sth_params(
        $self->_prepare_sth($dbh, $sql),
        [],
        {},
    );

    my $rv = '0E0';
    return (wantarray ? ($rv, $sth, @$bind) : $rv);
};

my $orig__connect = \&DBIx::Class::Storage::DBI::_connect;
*DBIx::Class::Storage::DBI::_connect = sub {
    my ($self) = @_;

    my $i = 0;
    foreach my $ref (@{ $isa_checks{_connect} }) {
        is(ref $_[$i], $ref, "arg $i isa $ref");
        $i++;
    }

    return $orig__connect->($self);
};

*CDTest::Schema::Result::Track::test_dbh_do_vars = sub {
    return $_[0]->result_source->schema->storage->dbh_do(
        sub {
            my $i = 0;
            foreach my $ref (@{ $isa_checks{dbh_do} }) {
                is(ref $_[$i], $ref, "arg $i isa $ref");
                $i++;
            }
        }, @_
    );
};

*CDTest::Schema::Result::Track::test_txn_do_vars = sub {
    return $_[0]->result_source->schema->txn_do(
        sub {
            my $i = 0;
            foreach my $ref (@{ $isa_checks{txn_do} }) {
                is(ref $_[$i], $ref, "arg $i isa $ref");
                $i++;
            }
        }, @_
    );
};
use warnings 'redefine';

my $result = $schema->resultset('Track')->new_result({ trackid => 999 });

subtest 'result_passing_to_dbh_do' => sub {
    $result->test_dbh_do_vars(12345);
};

subtest 'result_passing_to_txn_do' => sub {
    $result->test_txn_do_vars(12345);
};

subtest '_connect_passing' => sub {
    $storage->disconnect;
    $storage->ensure_connected;
};

############################################################

done_testing;
