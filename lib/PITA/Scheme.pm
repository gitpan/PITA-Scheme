package PITA::Scheme;

=pod

=head1 NAME

PITA::Scheme - PITA Testing Schemes

=head1 SYNOPSIS

  # Have the scheme load up from the provided config
  my $scheme = PITA::Scheme->new(
	injector => $injector,
	workarea => $workarea,
	);
  
  # Prepare to run the tests
  $scheme->prepare_all;
  
  # Run the tests
  $scheme->execute_all;
  
  # Send the results back to the server
  $scheme->put_report;

=head1 DESCRIPTION

While most of the PITA system exists outside the guest testing images and
tries to have as little interaction with them as possible, there is one
part that needs to be run from inside it.

PITA::Scheme objects live inside the image and does three main tasks.

1. Unpack the package and prepare the testing environment

2. Run the sequence of commands to execute the tests and capture
the results.

3. Package the results as a L<PITA::Report> and send it to the
L<PITA::Host::ResultServer>.

This functionality is implemented in a module structure that is highly
subclassable. In this way, L<PITA> can support multiple different
testing schemes for multiple different languages and installer types.

=head1 Setting up a Testing Image

Each image that will be set up will require a bit of customisation,
as the entire point of this type of testing is that every environment
is different.

However, by keeping most of the functionality in the L<PITA::Scheme>
objects, all you should need to do is to arrange for a simple Perl
script to be launched, that feeds some initial configuration to the
L<PITA::Scheme> object.

And it should do the rest. Or die... but we'll cover that later.

=head1 METHODS

Please excuse the lack of details for now...

TO BE COMPLETED

=cut

use 5.005;
use strict;
use Carp                  ();
use URI                   ();
use IPC::Cmd              ();
use File::Spec            ();
use File::Temp            ();
use Params::Util          '_HASH',
                          '_CLASS',
                          '_INSTANCE';
use Config::Tiny          ();
use LWP::UserAgent        ();
use HTTP::Request::Common 'PUT';
use PITA::Report          ();

use vars qw{$VERSION};
BEGIN {
	$VERSION = '0.06';
}





#####################################################################
# Constructor and Accessors

sub new {
	my $class  = shift;
	my %p      = @_; # p for params
	unless ( $class eq __PACKAGE__ ) {
		Carp::croak("Scheme class $_[0] does not implement a new method");
	}

	# Check some params
	unless ( $p{injector} ) {
		Carp::croak("Scheme 'injector' was not provided");
	}
	### Might not be needed now we don't write back to it
	#unless ( File::Spec->file_name_is_absolute($p{injector}) ) {
	#	Carp::croak("Scheme 'injector' is not an absolute path");
	#}
	unless ( -d $p{injector} ) {
		Carp::croak("Scheme 'injector' does not exist");
	}
	unless ( -r $p{injector} ) {
		Carp::croak("Scheme 'injector' cannot be read, insufficient permissions");
	}

	# Find a temporary directory to use for the testing
	$p{workarea} ||= File::Temp::tempdir();
	unless ( $p{workarea} ) {
		Carp::croak("Scheme 'workarea' not provided and automatic detection failed");
	}
	unless ( -d $p{workarea} ) {
		Carp::croak("Scheme 'workarea' directory does not exist");
	}
	unless ( -r $p{workarea} and -w _ ) {
		Carp::croak("Scheme 'workarea' insufficient permissions");
	}

	# Find the scheme config file
	my $scheme_conf = File::Spec->catfile(
		$p{injector}, 'scheme.conf',
		);
	unless ( -f $scheme_conf ) {
		Carp::croak("Failed to find scheme.conf in the injector");
	}
	unless ( -r $scheme_conf ) {
		Carp::croak("No permissions to read scheme.conf");
	}

	# Load the config file
	my $config = Config::Tiny->read( $scheme_conf );
	unless ( _INSTANCE($config, 'Config::Tiny') ) {
		Carp::croak("Failed to load scheme.conf config file");
	}

	# Split out instance-specific options
	my $instance = delete $config->{instance};
	unless ( _HASH($instance) ) {
		Carp::croak("No instance-specific options in scheme.conf");
	}

	# If provided, apply the optional lib path so some libraries
	# can be upgraded in a pince without upgrading all the images
	if ( $instance->{lib} ) {
		my $libpath = File::Spec->catdir( $p{injector}, split( /\//, $instance->{lib}) );
		unless ( -d $libpath ) {
			Carp::croak("Injector lib directory does not exist");
		}
		unless ( -r $libpath ) {
			Carp::croak("Injector lib directory has no read permissions");
		}
		require lib;
		lib->import( $libpath );
	}

	# Build a ::Request object from the config
	require PITA::Report;
	my $request = PITA::Report::Request->__from_Config_Tiny($config);
	unless ( _INSTANCE($request, 'PITA::Report::Request') ) {
		Carp::croak("Failed to create report Request object from scheme.conf");
	}

	# Resolve the specific schema class for this test run
	my $scheme = $request->scheme;
	my $driver = join( '::', 'PITA', 'Scheme', map { ucfirst $_ } split /\./, lc($scheme || '') );
	unless ( $scheme and _CLASS($driver) ) {
		Carp::croak("Request contains an invalid scheme name '$scheme'");
	}

	# Load the scheme class
	eval "require $driver;";
	if ( $@ =~ /^Can\'t locate PITA/ ) {
		Carp::croak("Scheme driver $driver does not exist on this Guest");
	} elsif ( $@ ) {
		Carp::croak("Error loading scheme driver $driver: $@");
	}

	# Hand off ALL those params to the scheme class constructor
	my $self = $driver->new( %p,
		scheme_conf => $scheme_conf,
		config      => $config,
		instance    => $instance,
		request     => $request,
		);

	# Make sure we know where to get CPAN files from
	unless ( _INSTANCE($self->support_server, 'URI') ) {
		Carp::croak('scheme.conf did not provide a support_server');
	}

	# Make sure we know where to send the results to
	unless ( _INSTANCE($self->put_uri, 'URI') ) {
		Carp::croak('Could not create a put_uri for the results');
	}

	$self;
}

sub injector {
	$_[0]->{injector};
}

sub workarea {
	$_[0]->{workarea};
}

sub scheme_conf {
	$_[0]->{scheme_conf};
}

sub support_server {
	URI->new($_[0]->instance->{support_server});
}

sub config {
	$_[0]->{config};
}

sub instance {
	$_[0]->{instance};
}

sub request {
	$_[0]->{request};
}

sub request_id {
	my $self = shift;
	if ( $self->request and $self->request->can('id') ) {
		# New style request objects
		return $self->request->id;
	} elsif ( $self->instance ) {
		# Manually passed job_id
		return $self->instance->{job_id};
	}

	undef;
}

sub install {
	$_[0]->{install};	
}

sub report {
	$_[0]->{report};
}





#####################################################################
# PITA::Scheme Methods

sub load_config {
	my $self = shift;

	# Load the config file
	$self->{config} = Config::Tiny->new( $self->{config_file} )
		or Carp::croak("Failed to load config file: "
			. Config::Tiny->errstr);

	# Validate some basics

	1;
}

# Do the various preparations
sub prepare_all {
	my $self = shift;
	return 1 if $self->install;

	# Prepare the package
	$self->prepare_package;

	# Prepare the environment
	$self->prepare_environment;

	# Prepare the report
	$self->prepare_report;

	1;
}

# Nothing, yet
sub prepare_package {
	my $self = shift;
	1;
}

sub prepare_report {
	my $self = shift;
	return 1 if $self->install;

	# Create the install object
	$self->{install} = PITA::Report::Install->new(
		request  => $self->request,
		platform => $self->platform,
		);

	# Create the main report object
	$self->{report} ||= PITA::Report->new();
	$self->report->add_install( $self->install );

	1;
}

sub execute_command {
	my ($self, $cmd) = @_;

	# Execute the command
	my ($success, $error_code, undef, $stdout_buf, $stderr_buf )
		= IPC::Cmd::run( command => $cmd, verbose => 0 );

	# Turn the results into a Command object
	my $command = PITA::Report::Command->new(
		cmd    => $cmd,
		stdout => $stdout_buf,
		stderr => $stderr_buf,
		);
	unless ( _INSTANCE($command, 'PITA::Report::Command') ) {
		Carp::croak("Error creating ::Command");
	}

	# If we have a PITA::Report::Install object available,
	# automatically add to it.
	if ( $self->install ) {
		$self->install->add_command( $command );
	}

	$command;
}

# Save the report to somewhere
sub write_report {
	my $self = shift;
	unless ( $self->report ) {
		Carp::croak("No Report created to write");
	}
	$self->report->write( shift );
}

# Upload the report to the results server
sub put_report {
	my $self = shift;
	unless ( $self->report ) {
		Carp::croak("No Report created to PUT");
	}

	# Serialise the data for sending
	my $xml = '';
	$self->write_report( \$xml );
	unless ( length($xml) ) {
		Carp::croak("Failed to serialize report file");
	}

	# Send the file
	my $agent    = LWP::UserAgent->new;
	my $response = $agent->request(PUT $self->put_uri,
		content_type   => 'application/xml',
		content_length => length($xml),
		content        => $xml,
		);
	unless ( $response and $response->success ) {
		Carp::croak("Failed to send result report to server");
	}

	1;
}

# The location to put to
sub put_uri {
	my $self = shift;
	my $uri  = $self->support_server;
	my $job  = $self->request_id or return undef;
	my $path = File::Spec->catfile( $uri->path || '/', $job );
	$uri->path( $path );
	$uri;
}

1;

=pod

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=PITA-Scheme>

For other issues, contact the author.

=head1 AUTHOR

Adam Kennedy E<lt>cpan@ali.asE<gt>, L<http://ali.as/>

=head1 SEE ALSO

The Perl Image Testing Architecture (L<http://ali.as/pita/>)

L<PITA>, L<PITA::Report>, L<PITA::Host::ResultServer>

=head1 COPYRIGHT

Copyright 2005 Adam Kennedy. All rights reserved.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut