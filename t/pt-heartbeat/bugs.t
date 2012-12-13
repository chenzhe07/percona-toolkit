#!/usr/bin/env perl

BEGIN {
   die "The PERCONA_TOOLKIT_BRANCH environment variable is not set.\n"
      unless $ENV{PERCONA_TOOLKIT_BRANCH} && -d $ENV{PERCONA_TOOLKIT_BRANCH};
   unshift @INC, "$ENV{PERCONA_TOOLKIT_BRANCH}/lib";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;

use POSIX qw( tzset );
use File::Temp qw(tempfile);

use PerconaTest;
use Sandbox;
require "$trunk/bin/pt-heartbeat";

my $dp  = new DSNParser(opts=>$dsn_opts);
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $master_dbh = $sb->get_dbh_for('master');
my $slave1_dbh = $sb->get_dbh_for('slave1');
my $slave2_dbh = $sb->get_dbh_for('slave2');

if ( !$master_dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
elsif ( !$slave1_dbh ) {
   plan skip_all => 'Cannot connect to sandbox slave1';
}
elsif ( !$slave2_dbh ) {
   plan skip_all => 'Cannot connect to sandbox slave2';
}

unlink '/tmp/pt-heartbeat-sentinel';
$sb->create_dbs($master_dbh, ['test']);
$sb->wait_for_slaves();

my $output;
my $base_pidfile = (tempfile("/tmp/pt-heartbeat-test.XXXXXXXX", OPEN => 0, UNLINK => 0))[1];
my $master_port = $sb->port_for('master');

my @exec_pids;
my @pidfiles;

sub start_update_instance {
   my ($port) = @_;
   my $pidfile = "$base_pidfile.$port.pid";
   push @pidfiles, $pidfile;

   my $pid = fork();
   if ( $pid == 0 ) {
      my $cmd = "$trunk/bin/pt-heartbeat";
      exec { $cmd } $cmd, qw(-h 127.0.0.1 -u msandbox -p msandbox -P), $port,
                          qw(--database test --table heartbeat --create-table),
                          qw(--update --interval 0.5 --pid), $pidfile;
      exit 1;
   }
   push @exec_pids, $pid;
   
   PerconaTest::wait_for_files($pidfile);
   ok(
      -f $pidfile,
      "--update on $port started"
   );
}

sub stop_all_instances {
   my @pids = @exec_pids, map { chomp; $_ } map { slurp_file($_) } @pidfiles;
   diag(`$trunk/bin/pt-heartbeat --stop >/dev/null`);

   waitpid($_, 0) for @pids;
   PerconaTest::wait_until(sub{ !-e $_ }) for @pidfiles;
}

# ############################################################################
# pt-heartbeat handles timezones inconsistently
# https://bugs.launchpad.net/percona-toolkit/+bug/886059
# ############################################################################

start_update_instance( $master_port );

my $slave1_dsn = $sb->dsn_for('slave1');
# Using full_output here to work around a Perl bug: Only the first explicit
# tzset works.
($output) = full_output(sub {
   local $ENV{TZ} = '-09:00';
   tzset();
   pt_heartbeat::main($slave1_dsn, qw(--database test --table heartbeat),
                        qw(--check --master-server-id), $master_port)
});

like(
   $output,
   qr/\A\d.\d{2}$/,
   "Bug 886059: pt-heartbeat doesn't get confused with differing timezones"
);

stop_all_instances();

# ############################################################################
# Done.
# ############################################################################
$sb->wipe_clean($master_dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
done_testing;
