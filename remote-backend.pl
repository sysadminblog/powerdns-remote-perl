#!/usr/bin/perl
use strict;
use warnings;

# PowerDNS Remote Backend (Perl)
# See the project page here: https://github.com/sysadminblog/powerdns-remote-perl/
# Project wiki page here: https://github.com/sysadminblog/powerdns-remote-perl/wiki

######### Configuration Settings Start #########

# The directory in which log files will be stored.
# Must be writable by the user PowerDNS runs as.
my $log_path = '/var/log/pdns_remote';

# Enable debug logging. 0 will disable, 1 will enable.
# This setting only affects the log files that get written into $log_path.
# When running the script ont he command line debugging will always be enabled by default but
# debug logs will not be written to the log files, only printed to STDOUT.
my $debug = 1;

######### PDNSRemote Code Start #########

package PDNSRemote;
use strict;
use warnings;
use Carp;
use Data::Dumper;
use DBI;
use JSON::Any;
use Log::Log4perl qw(get_logger);

### PDNSRemote->new - Initialise the PDNSRemote package
sub new {
	my $class = shift;
	my $self  = {};

	# Check if this is running via the command line. If so, debug logging will be enabled to STDOUT
	if   ( $ENV{'USER'} ) { $self->{_running_interactive} = 1; }
	else                  { $self->{_running_interactive} = 0; }

	# Create a JSON encoder/decoder object
	$self->{_json} = JSON::Any->new;

	# Initialize default values
	$self->{_result} = $self->{_json}->false;
	$self->{_log}    = [];

	bless $self, $class;

	# Set up the logging
	$self->logSetup;
	return $self;
}

### PDNSRemote->start_log - Set up logging
sub logSetup {
	my $self = shift;

	# Validate a log path was provided and can be written to
	if ( !defined $log_path || $log_path eq '' ) {
		croak "The $log_path setting has not been set. A valid directory for logging must be supplied.";
	}
	else {
		# Validate log directory exists
		if ( !-d $log_path || !-w $log_path ) {
			croak "The directory '${log_path}' does not exist or the permissions for it do not allow this script to write log files. Please verify the directory and permissions.";
		}
		else {
			# If there is already an existing log file, verify its writable
			if ( -f "${log_path}/pdns_remote.log" ) {
				if ( !-w "${log_path}/pdns_remote.log" ) {
					if ( $self->{_running_interactive} ) {
						carp "The log file '${log_path}/pdns_remote.log' already exists but cannot be written to. The script appears to be running interactively so this is not required.";
					}
					else {
						croak "The log file '${log_path}/pdns_remote.log' cannot be written to, please check permissions";
					}
				}
			}
		}
	}

	# Set up variable for the log config set next
	my $rootlogger;

	# Check if this is running interactive. If so, set the root log targets to DEBUG and Screen - no log files will get written to disk.
	# If not running interactive, the logs will only be configured
	if ( $self->{_running_interactive} ) { $rootlogger = 'DEBUG, Screen'; }
	elsif ($debug) { $rootlogger = 'DEBUG, AppInfo, AppError, AppDebug'; }
	else           { $rootlogger = 'DEBUG, AppInfo, AppError'; }

	my $log_conf = "
    log4perl.rootLogger                 = $rootlogger

    log4perl.appender.AppInfo              = Log::Dispatch::FileRotate
    log4perl.appender.AppInfo.filename     = ${log_path}/pdns_remote.log
    log4perl.appender.AppInfo.mode         = append
    log4perl.appender.AppInfo.autoflush    = 1
    log4perl.appender.AppInfo.size         = 10485760
    log4perl.appender.AppInfo.max          = 10
    log4perl.appender.AppInfo.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppInfo.recreate     = 1
    log4perl.appender.AppInfo.Threshold    = INFO
    log4perl.appender.AppInfo.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.AppDebug              = Log::Dispatch::FileRotate
    log4perl.appender.AppDebug.filename     = ${log_path}/pdns_remote-debug.log
    log4perl.appender.AppDebug.mode         = append
    log4perl.appender.AppDebug.autoflush    = 1
    log4perl.appender.AppDebug.size         = 10485760
    log4perl.appender.AppDebug.max          = 10
    log4perl.appender.AppDebug.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppDebug.recreate     = 1
    log4perl.appender.AppDebug.Threshold    = DEBUG
    log4perl.appender.AppDebug.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.AppError              = Log::Dispatch::FileRotate
    log4perl.appender.AppError.filename     = ${log_path}/pdns_remote-error.log
    log4perl.appender.AppError.mode         = append
    log4perl.appender.AppError.autoflush    = 1
    log4perl.appender.AppError.size         = 10485760
    log4perl.appender.AppError.max          = 10
    log4perl.appender.AppError.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppError.recreate     = 1
    log4perl.appender.AppError.Threshold    = ERROR
    log4perl.appender.AppError.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.Screen                = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr         = 0
    log4perl.appender.Screen.layout         = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.Threshold      = DEBUG
    log4perl.appender.Screen.layout.ConversionPattern = %d %P %p %m %n
  ";
	Log::Log4perl::init( \$log_conf );

	$self->{_logger} = Log::Log4perl->get_logger();
	return;
}

### PDNSRemote->logInfo - Log a new info event
sub logInfo {
	my $self    = shift;
	my $message = shift;
	$self->{_logger}->info($message);
}

### PDNSRemote->logDebug - Log a new debug event
sub logDebug {
	my $self    = shift;
	my $message = shift;
	$self->{_logger}->debug($message);
}

### PDNSRemote->logError - Log a new error event
sub logError {
	my $self    = shift;
	my $message = shift;
	$self->{_logger}->error($message);
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

		# Debugging
		$self->logDebug('Start processing new request:');
		$self->logDebug( Dumper($req) );

		# Validate there is a method and paramaters provided
		if ( !defined $req->{method} && !defined $req->{parameters} ) {
			$self->logError( 'Invalid request received from PowerDNS - missing method or parameters. Check the debug log (if enabled) for the request that failed.' );
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
			$self->logDebug("Executing method $method");
			$self->$method( $req->{parameters} );
		}
		else {
			# The request method does not have a function in this script, log and return error
			$self->logError( 'The request received from PowerDNS does not have a method in this script (it has not been implemented most likely). The request method was: '
				. $req->{method}
			);
			$self->returnError;
		}

		# Build the results to return
		my $return = { result => $self->{_result}, log => $self->{_log} };

		# Send the results to PowerDNS
		print $self->{_json}->encode($return), "\r\n";

		# Log the results for debugging
		$self->logDebug('Sent results to PowerDNS:');
		$self->logDebug( Dumper($return) );

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

	# Log some info
	if ($domain) {
		$self->logDebug("SQL - getDomainID: ${id} = ${domain}");
	}
	else {
		$self->logDebug("SQL - getDomainID: NO RESULT");
	}

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

	# Log some info
	if ($id) {
		$self->logDebug("SQL - getDomainName: ${domain} = ${id}");
	}
	else {
		$self->logDebug("SQL - getDomainName: NO RESULT");
	}

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
		$self->logDebug("Running getRecords: ${domain}");
	}
	else {
		$statement = $db->prepare( 'SELECT id,domain_id,name,type,content,prio,ttl,auth FROM records WHERE name = ? AND type = ?' );
		$statement->execute( $domain, $type );
		$self->logDebug("Running getRecords: ${domain} (${type})");
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
		$self->error( 'Missing paramaters to connect to the database, please ensure the remote-connection-string in pdns.conf has been set correctly. The script will not work until you do this.' );
		$self->returnError( 'PowerDNS remote backend has not been configured correctly. Check the error log for more information.' );
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
		$self->logError('MySQL connection failed');
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

	# Log the query
	$self->logDebug( "Executing method getRecords for name $qname of type $qtype for $client");

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
