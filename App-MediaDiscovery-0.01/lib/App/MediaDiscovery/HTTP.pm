use strict;

package App::MediaDiscovery::HTTP;

use Carp;
use LWP::UserAgent;

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

sub new {
	my $class  = shift;
	my %params = @_;

	my $self = bless( \%params, $class );

	return $self;
}

sub sleep_time {
	return 5;
}

sub get {
	my $self   = shift;
	my %params = @_;

	my $http_file = $params{http_file} or confess "No http file to get";

	my $ua = LWP::UserAgent->new();
	$ua->timeout(10);

	#$ua->agent('zombio');

	my $sleep_time = $self->sleep_time();
	sleep $sleep_time;    # we are not respecting robots.txt at this time, so do this to be at least a little polite
	my $response = $ua->get($http_file);
	$self->output( $http_file . ' ' . $response->status_line() );
	sleep $sleep_time;    # we are not respecting robots.txt at this time, so do this to be at least a little polite

	my $content;
	if ( $response->is_success() ) {
		$content = $response->decoded_content();
	} else {
		$self->output( $response->as_string() );
	}

	return $content;
}

sub getstore {
	my $self   = shift;
	my %params = @_;

	my $http_file = $params{http_file} or confess "No http file to get";
	my $disk_file = $params{disk_file} or confess "No disk file to get";
	( -f $disk_file ) and confess "Disk file '$disk_file' exists; cannot overwrite";

	my $ua = LWP::UserAgent->new();
	$ua->timeout(10);

	$self->output( "Getting '$http_file' and storing to '$disk_file'" );
	my $sleep_time = $self->sleep_time();
	sleep $sleep_time;    #i am not respecting robots.txt at this time, so do this to be at least a little polite
	my $request = HTTP::Request->new( 'GET', $http_file );
	my $response = $ua->request( $request, $disk_file );
	sleep $sleep_time;    #i am not respecting robots.txt at this time, so do this to be at least a little polite

	if ( $response->is_success ) {
		$self->output( $response->status_line() );
	} else {
		$self->output( $response->status_line() );
	}

	return;
}

sub output {
	my $self = shift;
	my ($message) = @_;
	if ( $self->{verbose} ) {
		print "$message\n";
	}
	return;
}

1;
