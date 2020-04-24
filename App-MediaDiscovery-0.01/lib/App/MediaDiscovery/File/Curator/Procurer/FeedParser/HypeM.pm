#API Docs: https://api.hypem.com/api-docs
#Username: zombieite
#Password: %oNF;6m,ej3k
#API Key: zombieitef4cc530d9e8ea03decf6b51
#You can use the key by appending it to API requests: ?key=XXX or &key=XXX (as appropriate)

use strict;
use warnings;

package App::MediaDiscovery::File::Curator::Procurer::FeedParser::HypeM;
use base('App::MediaDiscovery::File::Curator::Procurer::FeedParser');

use JSON::XS;
use Carp;
use Data::Dumper;

use App::MediaDiscovery::HTTP::GetAll;

sub get_source_list {
	my $self   = shift;
	my %params = @_;

	my $getter = App::MediaDiscovery::HTTP::GetAll->new();
	my @sources;

	# https://api.hypem.com/api-docs/
	# zoya@hypem.com
	my $url = "https://api.hypem.com/v2/blogs?key=zombieitef4cc530d9e8ea03decf6b51";

	my $content = $getter->get( http_file => $url );
	if ($content) {
		$self->output("Got blog list from '$url'.");
	} else {
		confess "Couldn't get blog list from '$url'.";
	}
	#$self->output($content);

	my $ref = decode_json($content);
	ref $ref eq 'ARRAY' or die 'Could not get arrayref from JSON';
	#$self->output(Dumper($ref));

	BLOG: for my $blog ( @$ref ) {

		my $url = $blog->{siteurl};
		$self->output($url);
		push(@sources, $url);

	}
	$self->output('Found ' . scalar(@$ref) . ' blogs.');

	return \@sources;
}

1;
