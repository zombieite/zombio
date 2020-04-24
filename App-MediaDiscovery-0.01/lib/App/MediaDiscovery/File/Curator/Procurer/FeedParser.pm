use strict;
use warnings;

package App::MediaDiscovery::File::Curator::Procurer::FeedParser;

use Carp;
use Data::Dumper;

sub new {
	my $class  = shift;
	my %params = @_;

	my $self = bless( \%params, $class );

	return $self;
}

sub file_type {
	return 'mp3';
}

sub get_latest_source_artist_works {
	die 'Must override this function in subclass';
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
