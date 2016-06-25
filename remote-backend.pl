#!/usr/bin/perl
use strict;
use warnings;

# PowerDNS Remote Backend (Perl)
# See the project page here: https://github.com/sysadminblog/powerdns-remote-perl/
# Project wiki page here: https://github.com/sysadminblog/powerdns-remote-perl/wiki

# This has been taken from the logfree branch. This branch does not include any logging for a slight performance boost.

######### PDNSRemote Code Start #########

package PDNSRemote;
use strict;
use warnings;
use Carp;
use DBI;
use JSON::Any;

### PDNSRemote->new - Initialise the PDNSRemote package
sub new {
	my $class = shift;
	my $self  = {};

	# Create a JSON encoder/decoder object
	$self->{_json} = JSON::Any->new;

	# Initialize default values
	$self->{_result} = $self->{_json}->false;

	bless $self, $class;

	return $self;
}

### PDNSRemote->run - Run the main loop
sub run {
	my $self = shift;

	# Start the loop for input
	while (<>) {
		chomp;

		# Skip empty
		next if $_ eq '';

		# Decode the JSON request
		my $req = $self->{_json}->decode($_);

		# Validate there is a method and paramaters provided
		if ( !defined $req->{method} && !defined $req->{parameters} ) {
			next;
		}

		# Get the request method
		my $method = 'api_' . $req->{method};

		# Validate the request method exists as a function in this script
		if ( $self->can($method) ) {

			# If the script has already been initialised, connect to the database (if it is not already connected)
			if ( $self->{_dsn} ) {

				# Use cached connections to avoid problems
				$self->{_dbi} =
					DBI->connect_cached( $self->{_dsn}, $self->{_username},
					$self->{_password} )
					or die;
			}

			# Execute the method with the given parameters
			$self->$method( $req->{parameters} );
		}
		else {
			# The request method does not have a function in this script, return error
			$self->returnError;
		}

		# Build the results to return
		my $return = { result => $self->{_result}, log => $self->{_log} };

		# Send the results to PowerDNS
		print $self->{_json}->encode($return), "\r\n";

		# Reset the variables for the next loop
		$self->{_result} = $self->{_json}->false;
		$self->{_log}    = [];
	}
	return;
}

### PDNSRemote->returnSuccess - Return success
sub returnSuccess {
	my $self = shift;
	my $log = shift || undef; # This paramater can be used to send a log to PowerDNS for logging
	$self->{_result} = $self->{_json}->true;
	if ($log) { $self->{_log} = $log; }
	return;
}

### PDNSRemote->returnError - Return error
sub returnError {
	my $self = shift;
	my $log = shift || undef; # This paramater can be used to send a log to PowerDNS for logging
	$self->{_result} = $self->{_json}->false;
	if ($log) { $self->{_log} = $log; }
	return;
}

### PDNSRemote->returnResult - Return a result
sub returnResult {
	my $self   = shift;
	my $result = shift;
	my $log = shift || undef; # This paramater can be used to send a log to PowerDNS for logging
	$self->{_result} = $result;
	if ($log) { $self->{_log} = $log; }
	return;
}

### PDNSRemote->addResultRR - Add a RR to the result to return to PowerDNS
sub addResultRR {
	my $self   = shift;
	my $record = shift;

	# Make sure _result is an array, if not make it one
	$self->{_result} = [] if ( ref $self->{_result} ne 'ARRAY' );
	
	# If the type is MX or SRV, we need to add the priority for the record to the content
	my $content;
	if ($$record->{type} eq 'SRV' || $$record->{type} eq 'MX') {
		$content = int( $$record->{prio} ) . ' ' . $$record->{content};
	} else {
		$content = $$record->{content};
	}

	# Push the result onto the array
	push @{ $self->{_result} },
		{
		'qname'     => $$record->{name},
		'qtype'     => $$record->{type},
		'content'   => $content,
		'ttl'       => int( $$record->{ttl} ),
		'auth'      => int( $$record->{auth} ),
		'domain_id' => int( $$record->{domain_id} )
		};
	return;
}

### PDNSRemote->getDomainID - Retrieve a domain name from the database based off a domain ID
sub getDomainID {
	my $self = shift;
	my $id   = shift;
	my $db   = $self->{_dbi};

	# Get the database name from the database
	my $statement = $db->prepare("SELECT domains.name FROM domains WHERE id = ?");
	my $query     = $statement->execute( ($id) );
	my ($domain)  = $statement->fetchrow;

	return $domain;
}

### PDNSRemote->getDomainName - Retrieve a domain ID from the database based off a domain name
sub getDomainName {
	my $self   = shift;
	my $domain = shift;
	my $db     = $self->{_dbi};

	# Get the database name from the database
	my $statement = $db->prepare("SELECT domains.id FROM domains WHERE name = ?");
	my $query     = $statement->execute( ($domain) );
	my ($id)      = $statement->fetchrow;

	return $id;
}

### PDNSRemote->getRecords - Retrieve records for a specified domain (and optionally type)
sub getRecords {
	my $self      = shift;
	my $domain    = shift;
	my $type      = shift || undef;
	my $statement = undef;
	my $db        = $self->{_dbi};

	# Run the query
	if ( !$type || $type eq 'ANY' ) {
		$statement = $db->prepare( 'SELECT id,domain_id,name,type,content,prio,ttl,auth FROM records WHERE name = ?' );
		$statement->execute($domain);
	}
	else {
		$statement = $db->prepare( 'SELECT id,domain_id,name,type,content,prio,ttl,auth FROM records WHERE name = ? AND type = ?' );
		$statement->execute( $domain, $type );
	}

	# Loop over each result (if any) and call addResultRR to return the results to PowerDNS
	while ( my $row = $statement->fetchrow_hashref ) {
		$self->addResultRR( \$row );
	}

	return;
}

### PDNSRemote->api_initialize - Verify and connect to DB
sub api_initialize {
	my $self  = shift;
	my $param = shift;

	# Ensure that the DB details have been provided
	if ( !defined $param->{dsn}
		|| !defined $param->{username}
		|| !defined $param->{password} )
	{
		$self->returnError( 'PowerDNS remote backend has not been configured correctly.' );
		return;
	}

	# Set the variables for future use
	$self->{_dsn}      = $param->{dsn};
	$self->{_username} = $param->{username};
	$self->{_password} = $param->{password};

	# Open connection to verify it works, it will be cached for future use
	if (
		my $dbi = DBI->connect_cached(
			$self->{_dsn}, $self->{_username}, $self->{_password}
		)
		)
	{
		$self->returnSuccess( 'PowerDNS remote backend has been initialised and connected to the database' );
	}
	else {
		die;
	}

	$self->returnSuccess( 'PowerDNS remote backend has been initialised and connected to the database' );
	return;
}

### PDNSRemote->api_lookup - Lookup records from the database
sub api_lookup {

	# The paramaters should look like this:
	#          'parameters' => {
	#                            'remote' => '127.0.0.1',
	#                            'qname' => '.',
	#                            'local' => '0.0.0.0',
	#                            'real-remote' => '127.0.0.1/32',
	#                            'zone-id' => -1,
	#                            'qtype' => 'SOA'
	#                          }
	my $self  = shift;
	my $param = shift;

	# Get the basic query details
	my $qtype = $param->{qtype} || 'ANY';
	my $qname = $param->{qname};

	# If the query is for '.' or empty, skip it
	if ( $qname eq '.' || $qname eq '' ) {
		return;
	}

	# Strip the trailing . from the qname
	$qname =~ s/\.$//;

	# Get the clients source IP
	my $client;
	if ( $param->{remote} ) {
		$client = $param->{remote};
	}
	elsif ( $param->${'real-remote'} ) {
		$client = $param->${'real-remote'};
	}
	else {
		$client = 'UNKNOWN';
	}

	# Run the query for the records. If there is a response, we will give this back to PowerDNS.
	$self->getRecords( $qname, $qtype );

	return;
}

######### PDNSRemote Code End #########

######### Main Code Start #########

package main;
use strict;
use warnings;

## Start the script and run handler

$| = 1;
my $backend = PDNSRemote->new;

$backend->run;

######### Main Code End #########
