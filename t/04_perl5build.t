#!/usr/bin/perl -w

# Testing the perl5.build scheme

use strict;
use lib ();
use File::Spec::Functions ':ALL';
BEGIN {
	$| = 1;
	unless ( $ENV{HARNESS_ACTIVE} ) {
		require FindBin;
		$FindBin::Bin = $FindBin::Bin; # Avoid a warning
		chdir catdir( $FindBin::Bin, updir() );
		lib->import(
			catdir('blib', 'lib'),
			catdir('blib', 'arch'),
			'lib',
			);
	}
}

use Cwd;
use File::Remove;
use PITA::Scheme;
use Test::More tests => 29;

# Locate the injector directory
my $injector = catdir( 't', '04_perl5build', 'injector' );
ok( -d $injector, 'Test injector exists' );

# Create the workarea directory
my $cwd      = cwd();
my $workarea = catdir( 't', '04_perl5build', 'workarea' );
File::Remove::remove( \1, $workarea ) if -d $workarea;
END {
	chdir $cwd;
	File::Remove::remove( \1, $workarea ) if -d $workarea;
}
ok( mkdir( $workarea ), 'Created workarea' );
ok( -d $workarea, 'Test workarea exists' );





#####################################################################
# Prepare

my $scheme = PITA::Scheme->new(
	injector => $injector,
	workarea => $workarea,
	);
isa_ok( $scheme, 'PITA::Scheme' );

# Rerun the prepare stuff in one step
ok( $scheme->prepare_all, '->prepare_all runs ok' );
ok( $scheme->extract_path, '->extract_path gets set'  );
ok( -d $scheme->extract_path, '->extract_path exists' );
ok( $scheme->workarea_file('Build.PL'), '->workarea_file returns a value' );
like( $scheme->workarea_file('Build.PL'), qr/\bBuild\.PL$/,
	'->workarea_file return a right-looking string' );
ok( -f $scheme->workarea_file('Build.PL'),
	'Build.PL exists in the extract package' );
ok( -f 'Build.PL', 'Changed to package directory, found Build.PL' );
isa_ok( $scheme->request, 'PITA::Report::Request'   );
is( $scheme->request_id, 1234, 'Got expected ->request_id value' );
isa_ok( $scheme->platform, 'PITA::Report::Platform' );
isa_ok( $scheme->install, 'PITA::Report::Install'   );
isa_ok( $scheme->report, 'PITA::Report'             );
isa_ok( $scheme->put_uri, 'URI' );
is( $scheme->put_uri, 'http://10.0.2.2/1234', '->put_uri correct' );




#####################################################################
# Execute

# Run the execution
ok( $scheme->execute_all, '->execute_all runs ok' );

# Does the install object contain things
is( scalar($scheme->install->commands), 3,
	'->execute_all added three commands to the report' );
my @commands = $scheme->install->commands;
isa_ok( $commands[0], 'PITA::Report::Command' );
isa_ok( $commands[1], 'PITA::Report::Command' );
isa_ok( $commands[2], 'PITA::Report::Command' );
is( $commands[0]->cmd, 'perl Build.PL',
	'Command 1 contains the expected command' );
like( $commands[1]->cmd, qr/Build$/,
	'Command 2 contains the expected command' );
like( $commands[2]->cmd, qr/Build test$/,
	'Command 3 contains the expected command' );
like( ${$commands[2]->stdout}, qr/All tests successful./,
	'Command 3 contains "all tests pass"' );
ok( -f $scheme->workarea_file('Build'),
	'Build actually got created' );
ok( -d $scheme->workarea_file('blib'),
	'blib directory actually got created' );

exit(0);