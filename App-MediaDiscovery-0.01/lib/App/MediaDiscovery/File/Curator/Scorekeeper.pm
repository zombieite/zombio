use strict;

# This is the module that connects the Curator module with the zombio_get script. When a zombio_curate says that a user likes a work, this module hears about it and does stuff with that information. Or, when zombio_get is wondering what kind of works a user likes, it asks this module.

package App::MediaDiscovery::File::Curator::Scorekeeper;

use Data::Dumper;
use Carp;
use List::Util;
use DBI;
use DBD::SQLite;
use Config::General;
use File::Spec;
use File::Path qw(make_path);
use IO::Prompter;
use Term::ANSIColor;

use App::MediaDiscovery::File::Curator::Secretary;

my $color_1 = 'blue';

sub new {
	my $class = shift;
	my %args  = @_;
	my $self  = bless( \%args, $class );

	my $config_file = File::Spec->catfile( $ENV{HOME}, 'zombio', 'config', split( /::/, __PACKAGE__ ) ) . '.conf';
	if ( -f $config_file ) {
		my %file_config;
		my $conf = Config::General->new($config_file);
		%file_config = $conf->getall();
		$self->{config} = \%file_config;
	}

	my %required_configs = (
		type                                 => 'mp3',
		love                                 => 20,                                                      # how many points do we give the artist/source if we curate a work
		like                                 => 2,                                                       # how many points do we give the artist/source if we like but delete a file
		dislike                              => -1,                                                      # how many points do we take from an artist/source if we delete a file
		hate                                 => -10,                                                     # how many points do we take from an artist/source if we hate a file
		min_files_to_collect                 => 1000,                                                    # if we have less than this, download anything we don't actively dislike
		max_files_to_collect                 => 5000,                                                    # hard limit on number of files
		low_enough_rating_to_delete          => -40,                                                     # if we download a work by an artist with lower than this rating, delete immediately
		recommendation_rating                => 20,                                                      # if someone recommends an artist to us, how much faith do we put in that
		max_files_to_get_from_source_at_once => 50,                                                      # don't get more than this number from a single source in a single run
		min_length_for_artist_match          => 7,                                                       # how many characters must match to consider an artist name a match
		min_file_mb                          => 2,                                                       # if we download a file smaller than this, delete immediately
		max_file_mb                          => 20,                                                      # if we download a file larger than this, delete immediately
		good_enough_score_to_count_in_genre  => 70,                                                      # what percent of works have to fall into a genre to consider a source/artist to be of that genre
		minimum_count_of_liked_artists       => 20,                                                      # how many artists should we have in the database with positive scores before we stop bugging the user to give us some more data to work with
		threshold_to_acquire                 => -100,                                                    # how low will we sink before we refuse to download
		unwanted_title_words                 => 'santa,xmas,christmas,rudolph,snowman',                  # throw away all works with these words in title
		database                             => "dbi:SQLite:dbname=$ENV{HOME}/zombio/data/zombio.db",    # DBI connect string
		username                             => undef,                                                   # SQLite doesn't need this
		password                             => undef,                                                   # SQLite doesn't need this
	);
	for my $required_config ( keys %required_configs ) {
		if ( !defined $self->{config}->{$required_config} ) {
			$self->{config}->{$required_config} = $required_configs{$required_config};
		}
	}

	$self->prepare_database();

	return $self;
}

# this is the only module that connects to the database.
# its job is to connect to the media database and know
# how to update it.
sub get_dbh {
	my $self = shift;

	$self->{dbh} and return $self->{dbh};
	$self->{dbh} = DBI->connect( $self->{config}->{database}, $self->{config}->{username}, $self->{config}->{password} );
	$self->{dbh}->{RaiseError} = 1;
	$self->{dbh}->{AutoCommit} = 1;

	return $self->{dbh};
}

sub rate_source_acquisition_artist_work {
	my $self = shift;
	my %args = @_;

	my $file                        = $args{file}        or confess 'Must provide file to rate';
	my $file_thinks_its_source_name = $args{source_name} or confess "No source name provided";
	my $rating                      = $args{rating};
	my $genre_name                  = $args{genre_name};
	my $clean_artist                = $args{clean_artist};
	my $clean_title                 = $args{clean_title};
	my $published                   = $args{published};

	defined $rating or confess 'Rating not defined';

	my $artist_id;
	my $work_id;
	my $previous_source_rating;
	my $source_id;
	my $source_name = $file_thinks_its_source_name;
	my $dbh         = $self->get_dbh();

	# take the source the file thinks it's from (based on its file system path) and add that source
	my $source = $self->lookup_source( source_name => $file_thinks_its_source_name );
	$source_id = $source->{source_id};
	if ($source_id) {
		$previous_source_rating = $source->{rating};
	} else {
		$self->output("Could not find source '$file_thinks_its_source_name'; adding.");
		$source_id = $self->add_source( source_name => $file_thinks_its_source_name );
		$previous_source_rating = 0;
	}
	$source_id or confess "No source id established for '$file' which thinks its source name is '$file_thinks_its_source_name'";

	# lookup the acquisition row for the file, or add an acquisition row if none exists
	my $acquisition = $self->lookup_acquisition( file => $file );
	my $acquisition_id = $acquisition->{acquisition_id};
	if ( !$acquisition_id ) {
		$self->output("No acquisition row found for file '$file'. It was probably aquired outside of the automated system, or moved to the trash before rating.");
		$acquisition_id = $self->add_acquisition(
			file      => $file,
			source_id => $source_id,
		);
		$acquisition = $self->lookup_acquisition( id => $acquisition_id );
	}
	$acquisition_id or confess "No acquisition id established for '$file' which thinks its source name is '$file_thinks_its_source_name'";

	# trust the database over the file system when determining source ($file_thinks_its_source_name
	# comes from a directory path). who knows how the file got there. usually we'll have put it
	# there with the right source/path, but a user could have moved it there or something.
	if ( $acquisition->{source_name} ) {
		if ( $file_thinks_its_source_name ne $acquisition->{source_name} ) {
			$self->output("File thinks its source name is '$file_thinks_its_source_name' but acquisition row indicates its source is '$acquisition->{source_name}'.");
		}
		$source_name            = $acquisition->{source_name};
		$previous_source_rating = $acquisition->{source_rating};
	}
	$source_name or confess "No source name established for '$file'";
	defined $previous_source_rating or confess "No source rating established for '$file'";

	# keep track of how we found this acquisition, if we know
	my $based_on_interest_in_source_id = $acquisition->{based_on_interest_in_source_id};
	my $based_on_interest_in_artist_id = $acquisition->{based_on_interest_in_artist_id};

	# update source rating with new score
	my $new_source_rating        = $previous_source_rating + $rating;
	my $update_source_rating_sth = $dbh->prepare("update source set rating = ? where source_id = ?");
	$update_source_rating_sth->execute( $new_source_rating, $source_id );
	$self->output("Source '$source_name' id '$source_id' rating moved from '$previous_source_rating' to '$new_source_rating'.");

	# update source with how we found it, if we like it and it's not updated already
	if ( $rating > 0 ) {
		$self->update_source_discovered_based_on(
			source_id                      => $source_id,
			based_on_interest_in_artist_id => $based_on_interest_in_artist_id,
		);
	}

	# if we have an artist name, rate the artist. if artist doesn't exist, insert and then rate.
	if ($clean_artist) {

		# we do allow hyphens in the artist name. that's because we use them to separate
		# artists when more than one artist is involved with a work. rather than make
		# separate artist entries in that case, we make a joint entry for the artist
		# combination.
		#
		# i'm not sure if this is the best system or not. i'm now kind of leaning toward
		# the idea of only giving the first artist credit. i always choose the first
		# artist as the one that i think contributed most to why i like the song. for
		# instance, sometimes a remixer i like remixes an artist i don't like, but i like
		# the end result a lot.
		#
		# this also means that we allow single artists with hyphens in their
		# names through here, also. that will happen when an artist name is not manually
		# reviewed and the work is rated negatively, for instance.
		$clean_artist =~ /^[a-z0-9 \-]+$/ or confess "Artist name is dirty: '$clean_artist'";

		my $artist = $self->lookup_artist( artist_name => $clean_artist );
		$artist_id = $artist->{artist_id};
		my $previous_artist_rating = $artist->{rating} || 0;
		my $artist_rating = $previous_artist_rating + $rating;

		if ( !$artist_id ) {
			$artist_id = $self->add_artist(
				artist_name                    => $clean_artist,
				based_on_interest_in_source_id => $based_on_interest_in_source_id,
				based_on_interest_in_artist_id => $based_on_interest_in_artist_id,
			);
			$artist_rating = $rating;
			$self->output("Not found; added artist id '$artist_id'.");
		}
		$artist_id or confess "Could not establish artist id for '$clean_artist'";

		# rate the artist
		my $artist_update_sth = $dbh->prepare("update artist set rating=? where artist_id=?");
		$artist_update_sth->execute( $artist_rating, $artist_id );
		$self->output("Artist '$clean_artist' id '$artist_id' rating moved from '$previous_artist_rating' to '$artist_rating'.");

		# update artist with how we found them, if we like them and they're not updated already
		if ( $rating > 0 ) {
			$self->update_artist_discovered_based_on(
				artist_id                      => $artist_id,
				based_on_interest_in_artist_id => $based_on_interest_in_artist_id,
				based_on_interest_in_source_id => $based_on_interest_in_source_id,
			);
		}

		# update or create work
		if ($clean_title) {

			# we're allowing hyphens in work titles here because i'm lazy. we don't clean them
			# from artist names. we're supposed to clean them from work names, but it doesn't
			# really matter here.
			#$self->output( "Checking clean title" );
			if ( $clean_title !~ /^[a-z0-9 \-]+$/ || $clean_title =~ /\s\s+/ )    #had some messy ones getting through
			{
				$self->output("Supposedly clean title is dirty: '$clean_title'.");
				confess "Supposedly clean title is dirty: '$clean_title'";
			}

			#$self->output( "Selecting work information" );
			my $work_sth = $dbh->prepare("select work_id,rating from work where work_name=?");
			$work_sth->execute($clean_title);
			my $previous_work_rating;
			( $work_id, $previous_work_rating ) = $work_sth->fetchrow_array();
			my $work_rating = $previous_work_rating + $rating;
			if ( !$work_id ) {
				$work_id = $self->add_work( work_name => $clean_title, artist_id => $artist_id );
				$work_rating = $rating;
			}
			$work_id or confess "Could not establish work id for '$clean_artist' - '$clean_title'";

			#$self->output( "Updating work info" );
			my $work_update_sth = $dbh->prepare("update work set rating = ?, published = ?, source_id = ? where work_id = ?");
			$work_update_sth->execute( $work_rating, $published, $source_id, $work_id );
			$self->output("Work is '$clean_title' id '$work_id'.");
			$self->output("Rating moved from '$previous_work_rating' to '$work_rating'.");
			if ($published) {
				$self->output("Marked as published.");
			}
			if ($source_id) {
				$self->output("Connected to source '$source_id'.");
			}
		} else {
			$self->output("Could not update work; no clean title.");
		}
	} else {
		$self->output("Could not update artist; no clean artist name.");
	}

	# update the acquisition's rating and information, now that we have it
	my $update_acquisition_rating_sth = $dbh->prepare("update acquisition set rating = ?, artist_id = ?, work_id = ? where acquisition_id = ?");
	$update_acquisition_rating_sth->execute( $rating, $artist_id, $work_id, $acquisition_id );
	$self->output("Acquisition '$file' id '$acquisition_id' rated '$rating' and connected to artist id '$artist_id' and work id '$work_id'.");

	# if we have a genre, connect the artist and source to that genre
	if ($genre_name) {
		$source_id or confess 'No source id';
		$artist_id or confess 'No artist id';
		my $genre_id = $self->lookup_or_add_genre( genre_name => $genre_name );
		$self->connect_artist_and_source_to_genre( genre_id => $genre_id, artist_id => $artist_id, source_id => $source_id );
		$self->output("Connecting artist '$artist_id' and source '$source_id' to genre '$genre_name', id '$genre_id'.");
	}

	return;
}

sub update_source_discovered_based_on {
	my $self = shift;
	my %args = @_;

	my $source_id = $args{source_id} or confess "Must provide source id";
	my $based_on_interest_in_artist_id = $args{based_on_interest_in_artist_id};

	my $dbh = $self->get_dbh();
	my $source = $self->lookup_source( source_id => $source_id );

	# update how we found this source, if it's not known already
	if ( !$source->{based_on_interest_in_artist_id} && $based_on_interest_in_artist_id ) {
		my $sth = $dbh->prepare('update source set based_on_interest_in_artist_id=? where source_id=?');
		$sth->execute( $based_on_interest_in_artist_id, $source_id );
		$self->output("Updating source '$source_id' to indicate it was discovered based on interest in artist '$based_on_interest_in_artist_id'.");
	}

	# we're not using other sources to discover a source at this point.
	# the $based_on_interest_in_source_id will always be empty
	# (if we don't really like this source usually) or the same
	# as the source id (if we usually like this source). someday it
	# may be possible to discover a source based on other sources,
	# such as via a blogroll link or something.

	return;
}

sub update_artist_discovered_based_on {
	my $self = shift;
	my %args = @_;

	my $artist_id                      = $args{artist_id} or confess "Must provide artist id";
	my $based_on_interest_in_artist_id = $args{based_on_interest_in_artist_id};
	my $based_on_interest_in_source_id = $args{based_on_interest_in_source_id};

	my $dbh = $self->get_dbh();
	my $artist = $self->lookup_artist( artist_id => $artist_id );

	# update what artist led us to this artist, if it's not known already
	if ( !$artist->{based_on_interest_in_artist_id} && $based_on_interest_in_artist_id ) {
		my $sth = $dbh->prepare('update artist set based_on_interest_in_artist_id=? where artist_id=?');
		$sth->execute( $based_on_interest_in_artist_id, $artist_id );
		$self->output("Updating artist '$artist_id' to indicate they were discovered based on interest in artist '$based_on_interest_in_artist_id'.");
	}

	# update what source led us to this artist, if it's not known already
	if ( !$artist->{based_on_interest_in_source_id} && $based_on_interest_in_source_id && ( $artist->{based_on_interest_in_source_id} != $based_on_interest_in_source_id ) ) {
		my $sth = $dbh->prepare('update artist set based_on_interest_in_source_id=? where artist_id=?');
		$sth->execute( $based_on_interest_in_source_id, $artist_id );
		$self->output("Updating artist '$artist_id' to indicate they were discovered based on interest in source '$based_on_interest_in_source_id'.");
	}

	return;
}

sub connect_artist_and_source_to_genre {
	my $self = shift;
	my %args = @_;

	my $source_id = $args{source_id} or confess 'Must provide source_id';
	my $artist_id = $args{artist_id} or confess 'Must provide artist_id';
	my $genre_id  = $args{genre_id}  or confess 'Must provide genre_id';

	$self->lookup_or_add_then_increment_artist_genre( artist_id => $artist_id, genre_id => $genre_id );
	$self->lookup_or_add_then_increment_source_genre( source_id => $source_id, genre_id => $genre_id );

	return;
}

sub lookup_or_add_then_increment_artist_genre {
	my $self = shift;
	my %args = @_;

	my $artist_id = $args{artist_id} or confess 'Must provide artist_id';
	my $genre_id  = $args{genre_id}  or confess 'Must provide genre_id';

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('select artist_genre_id from artist_genre where artist_id=? and genre_id=?');
	$sth->execute( $artist_id, $genre_id );
	my ($id) = $sth->fetchrow_array();

	if ($id) {
		$sth = $dbh->prepare('update artist_genre set count=count+1 where artist_genre_id=?');
		$sth->execute($id);
	} else {
		$sth = $dbh->prepare('insert into artist_genre (artist_id, genre_id, count) values (?, ?, ?)');
		$sth->execute( $artist_id, $genre_id, 1 );
		$id = $dbh->last_insert_id( '', '', '', '' );
	}

	return $id;
}

sub lookup_or_add_then_increment_source_genre {
	my $self = shift;
	my %args = @_;

	my $source_id = $args{source_id} or confess 'Must provide source_id';
	my $genre_id  = $args{genre_id}  or confess 'Must provide genre_id';

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('select source_genre_id from source_genre where source_id=? and genre_id=?');
	$sth->execute( $source_id, $genre_id );
	my ($id) = $sth->fetchrow_array();

	if ($id) {
		$sth = $dbh->prepare('update source_genre set count=count+1 where source_genre_id=?');
		$sth->execute($id);
	} else {
		$sth = $dbh->prepare('insert into source_genre (source_id, genre_id, count) values (?, ?, ?)');
		$sth->execute( $source_id, $genre_id, 1 );
		$id = $dbh->last_insert_id( '', '', '', '' );
	}

	return $id;
}

sub recommendation_rating {
	return shift->{config}->{recommendation_rating};
}

sub should_we_acquire_all_works_from_source {
	my $self = shift;
	my %args = @_;

	my $source_name = $args{source_name} or confess "No source name";
	my $artist_name = $args{artist_name};

	my $new_acquisitions_directory = $args{new_acquisitions_directory} or confess "No get to directory";
	$self->{config}->{max_files_to_collect} or confess "No max files to collect";

	# lookup or add source
	my $source_hashref = $self->lookup_source( source_name => $source_name );
	my $source_id;
	if ($source_hashref) {
		$source_id = $source_hashref->{source_id};

		#$self->output( "Source '$source_id', '$source_name' has been seen before.\n" );
	} else {
		$self->output("We haven't seen '$source_name' before; adding.");
		$source_id = $self->add_source( source_name => $source_name );
		$self->output("Added source '$source_name', id '$source_id'.");
	}
	$source_id or confess "Could not establish source id for '$source_name'";

	#check if source is blacklisted for having no useful content
	if ($source_hashref->{blacklist}) {
		return;
	}

	#check to see if we have too much to review already. TODO XXX FIXME add a disk usage check as well.
	my $existing_files_count = `find -L $new_acquisitions_directory -type f | wc -l`;
	$existing_files_count =~ s/\s+//g;
	if ( $existing_files_count > $self->{config}->{max_files_to_collect} ) {
		$self->output("Found '$existing_files_count' files which is more than '$self->{config}->{max_files_to_collect}' so not acquiring any more.");
		return;
	}

	my $response;
	my $artist_rating_hashref = $artist_name ? $self->artist_rating( artist_name => $artist_name ) : undef;
	my $artist_rating         = $artist_name ? $artist_rating_hashref->{rating}                    : 0;
	my $artist_name_matches   = $artist_name ? $artist_rating_hashref->{matches}                   : [];
	my @artist_ids = map { $_->{artist_id} } @$artist_name_matches;
	my $source_rating = $source_hashref->{rating};

	#set threshold according to how many files we have compared to the maximum number of files we'd like to ever have
	my $threshold_to_acquire;

	#unless we have the minimum number of files. in that case, be more picky.
	if ( $existing_files_count < $self->{config}->{min_files_to_collect} ) {
		$threshold_to_acquire = $self->{config}->{threshold_to_acquire} || -20;    # acquire anything we don't actively dislike
		$self->output("We only have '$existing_files_count' files, which is less than the minimum of '$self->{config}->{min_files_to_collect}'. We will acquire anything we don't actively dislike.");
	} else {
		my $max_threshold_to_acquire = $self->max_threshold_to_acquire();
		my $min_files_to_collect     = $self->{config}->{min_files_to_collect} or confess 'No min files to collect is configured';
		my $max_files_to_collect     = $self->{config}->{max_files_to_collect} or confess 'No max files to collect is configured';
		$threshold_to_acquire = int( ( ( $existing_files_count - $min_files_to_collect ) * $max_threshold_to_acquire / $max_files_to_collect ) + 0.5 );
	}

	my $never_downloaded_anything_from_source = $self->never_downloaded_anything_from_source( source_id => $source_id );

	my $source_and_artist_score = $artist_rating + $source_rating;
	$self->output("Artist '$artist_name' has a rating of '$artist_rating' and source '$source_name' has a rating of '$source_rating' for a source/artist score of '$source_and_artist_score'.");

	#the essence of the algorithm for guessing if the user will like something
	if (   ( $source_and_artist_score > $threshold_to_acquire )
		|| ( $never_downloaded_anything_from_source && $source_and_artist_score > -1 ) )
	{
		if ( ( $source_and_artist_score > $threshold_to_acquire ) ) {
			$self->output("Combined score '$source_and_artist_score' is larger than current threshold '$threshold_to_acquire' which means that this source and artist posting are interesting enough to acquire everything posted on '$source_name'.");
		} elsif ($never_downloaded_anything_from_source) {
			$self->output("Never downloaded anything from '$source_name', so maybe we should give it a try.");
		}

		$response = {
			artist_name                           => $artist_name,
			artist_name_matches                   => $artist_name_matches,
			artist_rating                         => $artist_rating,
			source_name                           => $source_name,
			source_id                             => $source_id,
			source_rating                         => $source_rating,
			combined_rating                       => $source_and_artist_score,
			current_threshold                     => $threshold_to_acquire,
			never_downloaded_anything_from_source => $never_downloaded_anything_from_source,
		};
		return $response;
	} else {
		$self->output("Combined score '$source_and_artist_score' is not larger than current threshold '$threshold_to_acquire' which means that this source and artist posting are not interesting enough to acquire everything posted on '$source_name'.");
	}

	return;
}

# how much should we restrain ourselves when it comes to acquiring new works?
# a higher number means restrain ourselves more.
sub max_threshold_to_acquire {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();

	my $sth = $dbh->prepare('select max(rating) from source');
	$sth->execute();
	my ($max_source_rating) = $sth->fetchrow_array();

	#$sth = $dbh->prepare('select max(rating) from artist');
	#$sth->execute();
	#my ($max_artist_rating) = $sth->fetchrow_array();

	# i was including max_artist_rating in this, but it was seeming a bit too
	# conservative in deciding what to download. i think it's because blogs
	# post so many new artists that the blog score is more important than the
	# blog + artist score. rarely does any posting of a new file on a
	# blog ever even come close to the max source rating + max artist rating.
	# so just using the max source rating gives us a lower threshold and a
	# better chance of downloading.
	my $max_threshold_to_acquire = $max_source_rating;    #+ $max_artist_rating;

	return $max_threshold_to_acquire;
}

sub ok_to_acquire {
	my $self = shift;
	my %args = @_;

	my $source_name       = $args{source_name}       or confess "No source_name";
	my $destination       = $args{save_destination}  or confess "No destination";
	my $acquisition_count = $args{acquisition_count};

	defined $acquisition_count or confess "No acquisition count";

	# if we've downloaded to many files from this source, stop
	if ( $acquisition_count >= $self->{config}->{max_files_to_get_from_source_at_once} ) {
		$self->output("Reached or exceeded maximum acquisition count of '$self->{config}->{max_files_to_get_from_source_at_once}' files to get from source '$source_name'. Counter is at '$acquisition_count' acquisitions. Not ok to acquire more.");
		return;
	}

	my $dbh = $self->get_dbh();

	#if it already exists on disk, don't acquire it again
	if ( -f $destination ) {
		$self->output("File '$destination' exists. No need to acquire.");
		return;
	}

	#see if we've already acquisitioned it at some point. even if it's not on disk anymore, we still
	#don't want to acquisition it if we once did long ago.
	my $acquisition = $self->lookup_acquisition( file => $destination );
	if ( my $acquisition_id = $acquisition->{acquisition_id} ) {
		$self->output("'$destination' was found in acquisition table, id '$acquisition_id'. It appears to have been acquired already.");
		if ( -f $destination ) {
			$self->output("File was found on disk, so it must not have been evaluated yet.");
		} else {
			$self->output("File was not found on disk.");
			my $rating = $acquisition->{rating};
			if ($rating) {
				$self->output("File was evaluated and rated '$rating'.");
			} elsif ( !$acquisition->{wanted} ) {
				$self->output("File was downloaded, but removed because it was not wanted after download checks (possibly a duplicate, or unwanted file size).");
			} else {
				$self->output("File appears to have been downloaded and removed, but not rated for some reason.");
			}
		}
		return;
	} else {
		$self->output("'$destination' was not found in acquisition table.");
	}

	#we're going to acquisition it, so make some db entries for it
	my $source_hashref = $self->lookup_source( source_name => $source_name );
	my $source_id;
	if ($source_hashref) {
		$source_id = $source_hashref->{source_id};

		#$self->output( "Source '$source_id' '$source_name' has been seen before.\n" );
	} else {
		$self->output("We haven't seen '$source_name' before. Creating new source.");
		$source_id = $self->add_source( source_name => $source_name );
		$self->output("Added source id '$source_id' for source '$source_name'.");
	}

	return 1;
}

sub add_acquisition_and_decide_if_work_is_worth_evaluating {
	my $self = shift;
	my %args = @_;

	my $file = $args{file}           or confess "No file";
	my $why  = $args{why_downloaded} or confess "No reason why downloaded given";

	# we need to store the fact that we've downloaded the file, even if we decide not to keep it.
	# that way if we don't keep it, we won't make the mistake of downloading it again and deleting
	# it again. we'll mark it as unwanted initially, then if we want it we'll update it.
	my $acquisition_id = $self->add_acquisition( file => $file, why => $why, wanted => 0, );

	if ( !-f $file ) {
		$self->output("'$file' downloaded but was not found.");
		return;
	}

	my $class = $self->get_class_name();
	my $work = $class->existing( file_location => $file );

	#check file size
	$self->{config}->{max_file_mb} or confess 'No max file size configured';
	$self->{config}->{min_file_mb} or confess 'No min files size configured';
	my $mb = $work->mb();
	if ( $mb > $self->{config}->{max_file_mb} ) {
		$self->output("'$file' is '$mb' MB. It is larger than '$self->{config}->{max_file_mb}' so it is not worth evaluating.");
		return;
	} else {

		#$self->output( "'$file' is not too big.\n" );
	}
	if ( $mb < $self->{config}->{min_file_mb} ) {
		$self->output("'$file' is '$mb' MB. It is smaller than '$self->{config}->{min_file_mb}' so it is not worth evaluating.");
		return;
	} else {

		#$self->output( "'$file' is not too small.\n" );
	}

	# check to see if we have seen this work already. it could have been another file from another source,
	# but if we've seen this work by this artist before, we're not interesting in evaluating it again.
	my $artist = $work->clean_with_spaces( $work->artist() );
	my $title  = $work->clean_with_spaces( $work->title() );
	if ($artist) {
		$self->output("Checking artist '$artist'.");
		my $artist_row = $self->lookup_artist( artist_name => $artist );
		if ($artist_row) {
			$self->output("Found artist $artist_row->{artist_id} '$artist'.");

			my $too_low_rating = $self->{config}->{low_enough_rating_to_delete};
			defined $too_low_rating or confess 'No too low rating configured';
			if ( $artist_row->{rating} <= $too_low_rating ) {
				$self->output("Artist rating '$artist_row->{rating}' is below too low rating '$too_low_rating'. It's so low that we will not bother evaluating this work.");
				return;
			}

			my $artist_id = $artist_row->{artist_id};
			my $work_row;
			if ($title) {
				if ( $self->{config}->{unwanted_title_words} ) {
					my $exclude_words_string = $self->{config}->{unwanted_title_words};
					my @exclude_words = split( /,/, $exclude_words_string );
					scalar @exclude_words or confess 'No unwanted words configured';
					for my $unwanted_word (@exclude_words) {
						if ( $title =~ /$unwanted_word/i ) {
							$self->output("Title '$title' matches unwanted word '$unwanted_word', so we will not keep this work.");
							return;
						}
					}
				}

				$work_row = $self->lookup_work( artist_id => $artist_id, work_name => $title );
			}

			if ($work_row) {
				$self->output("We have work '$title' by '$artist' in database, so not worth evaluating again.");
				return;
			} else {
				$self->output("We don't have work '$title' by '$artist' in database. Adding work to database.");

				#this will keep us from having to evaluate the same work twice, acquisitioned
				#from different sources and possibly with different filenames. we'll add
				#this work to our database using the artist and title in the tags.
				#even if the tags are screwed up, they should still work to semi-uniquely
				#identify this work so we don't acquisition it again.
				if ($title) {
					$self->add_work( artist_id => $artist_id, work_name => $title );
				} else {
					$self->output("No title; cannot add work to database.");
				}
			}
		} else {
			$self->output("Could not find artist '$artist' in database, so we probably don't have this work already. Adding artist and work to database.");
			my $artist_id = $self->add_artist( artist_name => $artist );
			if ( $artist_id && $title ) {
				$self->add_work( artist_id => $artist_id, work_name => $title );
			} else {
				$self->output("Cannot add work. Need an artist id and title to add work. Artist id is '$artist_id' and title is '$title'.");
			}
		}
	} else {
		"Could not get a clean artist name from '" . $work->artist() . "' so we could not determine if we have this work already. Must be evaluated manually.";
	}

	$self->output("It looks like file '$file' ('$artist'-'$title') is worth evaluating.");
	$self->make_acquisition_wanted( acquisition_id => $acquisition_id );

	return 1;
}

sub all_artists {
	my $self = shift;
	my %args = @_;

	my $dbh         = $self->get_dbh();
	my $artists_sth = $dbh->prepare("select * from artist");
	$artists_sth->execute();
	my $all_artists = $artists_sth->fetchall_arrayref( {} );

	return $all_artists;
}

# the weird thing going on here is that it's impossible to
# identify an artist just by their name. we try to canonicalize
# the artist name as much as possible but there are still
# potential ambiguities. also, what if an artist collaborated
# on a work? what if an artist remixed a work? for these
# reasons, we are a little fuzzy about how we identify artists
# when we are given only a name to work with. we may average
# together the ratings of multiple artist rows to determine the
# "rating" of the "artist name" you provide.
sub artist_rating {
	my $self = shift;
	my %args = @_;

	my $artist_name = $args{artist_name} or confess 'No artist name';
	my $escaped_artist_name = quotemeta $artist_name;

	my $artists = $self->all_artists();
	my @ratings;

ARTIST: for my $artist_row (@$artists) {
		if ( $artist_name eq $artist_row->{artist_name} ) {

			#$self->output( "Artist name '$artist_name' is an exact match for artist id '$artist_row->{artist_id}' rating '$artist_row->{rating}'.\n" );
			@ratings = ( { artist_id => $artist_row->{artist_id}, rating => $artist_row->{rating}, } );
			last ARTIST;
		}

		# look for the provided artist name within the names of known artists
		elsif ( ( length($artist_name) >= $self->{min_length_for_artist_match} ) && ( $artist_row->{artist_name} =~ /$escaped_artist_name/i ) ) {

			#$self->output( "Artist name '$artist_name' is a partial match to longer artist name '$artist_row->{artist_name}' id '$artist_row->{artist_id}' rating '$artist_row->{rating}'.\n" );
			push( @ratings, { artist_id => $artist_row->{artist_id}, rating => $artist_row->{rating}, } );
		}

		# look for the names of known artists within the provided artist name
		elsif ( ( length( $artist_row->{artist_name} ) >= $self->{min_length_for_artist_match} ) && ( $artist_name =~ /$artist_row->{artist_name}/i ) ) {

			#$self->output( "Artist name '$artist_name' is partially matched by shorter artist name '$artist_row->{artist_name}' id '$artist_row->{artist_id}' rating '$artist_row->{rating}'.\n" );
			push( @ratings, { artist_id => $artist_row->{artist_id}, rating => $artist_row->{rating}, } );
		}
	}

	if ( !@ratings ) {
		return { rating => 0, matches => [] };
	}

	#we need to get the rating of the artist. however, there may be more than one artist name
	#matched, so let's give the average rating of the matched artists.
	my $average_rating = List::Util::sum( map { $_->{rating} } @ratings ) / scalar @ratings;
	$average_rating = int( $average_rating + 0.5 );    # round it

	return { rating => $average_rating, matches => \@ratings };
}

sub rate_artist {
	my $self = shift;
	my %args = @_;

	my $artist_id = $args{artist_id} or confess "No artist id";
	my $rating = $args{rating};

	defined $rating or confess "No rating defined";

	my $dbh               = $self->get_dbh();
	my $artist_update_sth = $dbh->prepare("update artist set rating=? where artist_id=?");
	$artist_update_sth->execute( $rating, $artist_id );

	return;
}

sub rate_source {
	my $self = shift;
	my %args = @_;

	my $source_id = $args{source_id} or confess "No source id";
	my $rating = $args{rating};

	defined $rating or confess "No rating defined";

	my $dbh               = $self->get_dbh();
	my $source_update_sth = $dbh->prepare("update source set rating=? where source_id=?");
	$source_update_sth->execute( $rating, $source_id );

	return;
}

sub source_rating {
	my $self = shift;
	my %args = @_;

	my $source_id   = $args{source_id};
	my $source_name = $args{source_name};

	( $source_id || $source_name ) or return;

	my $source = $self->lookup_source( source_id => $source_id, source_name => $source_name );
	if ($source) {

		#$self->output( "Found rating '$source->{rating}' for source '$source_name'\n" );
		return $source->{rating};
	} else {

		#$self->output( "Could not find rating for source '$source_name'\n" );
	}

	return 0;
}

sub lookup_genre {
	my $self = shift;
	my %args = @_;

	my $genre_id   = $args{genre_id};
	my $genre_name = $args{genre_name};

	my $dbh = $self->get_dbh();

	my $sth;
	if ($genre_name) {
		$sth = $dbh->prepare("select * from genre where genre_name=?");
		$sth->execute($genre_name);
	} elsif ($genre_id) {
		$sth = $dbh->prepare("select * from genre where genre_id=?");
		$sth->execute($genre_id);
	} else {
		confess "No genre id or name";
	}

	my $genre = $sth->fetchrow_hashref();

	return $genre;
}

sub lookup_artist {
	my $self = shift;
	my %args = @_;

	my $artist_id   = $args{artist_id};
	my $artist_name = $args{artist_name};

	my $dbh = $self->get_dbh();

	my $sth;
	if ($artist_name) {
		$sth = $dbh->prepare("select * from artist where artist_name=?");
		$sth->execute($artist_name);
	} elsif ($artist_id) {
		$sth = $dbh->prepare("select * from artist where artist_id=?");
		$sth->execute($artist_id);
	} else {
		confess "No artist id or name";
	}

	my $artist = $sth->fetchrow_hashref();
	return $artist;
}

sub lookup_work {
	my $self = shift;
	my %args = @_;

	my $artist_id = $args{artist_id} or confess "No artist id; there is no way to be sure if we have a work without knowing the artist as well as the work name";
	my $work_name = $args{work_name} or confess "No work name";

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare("select * from work where artist_id=? and work_name=?");
	$sth->execute( $artist_id, $work_name );
	my $work = $sth->fetchrow_hashref();

	return $work;
}

sub lookup_acquisition {
	my $self = shift;
	my %args = @_;

	my $id   = $args{id};
	my $file = $args{file};

	my $where;
	my $bind;
	if ($id) {
		$where = 'where acquisition_id=?';
		$bind  = $id;
	} elsif ($file) {
		$where = 'where acquisition_destination=?';
		$bind  = $file;
	} else {
		die 'Must provide id or file';
	}

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( "
        select 
            acquisition.acquisition_id,
            acquisition.source_id,
            source.source_name,
            source.rating source_rating,
            acquisition.acquisition_destination,
            acquisition.rating,
            acquisition.artist_id,
            artist.artist_name,
            acquisition.work_id,
            work.work_name,
            acquisition.based_on_interest_in_source_id,
            acquisition.based_on_interest_in_artist_id,            
            acquisition.marked_for_removal,
            acquisition.skipped,
            genre.genre_name,
            acquisition.publish,
            acquisition.curated_filename,
            acquisition.wanted
        from 
            acquisition 
            left join genre using (genre_id)
            left join source using (source_id) 
            left join artist using (artist_id)
            left join work using (work_id)
        $where
    " );
	$sth->execute($bind);
	my $acquisition = $sth->fetchrow_hashref();

	return $acquisition;
}

sub lookup_source {
	my $self = shift;
	my %args = @_;

	my $source_id   = $args{source_id};
	my $source_name = $args{source_name};

	my $dbh = $self->get_dbh();

	my $sth;
	if ($source_name) {
		$sth = $dbh->prepare("select * from source where source_name=?");
		$sth->execute($source_name);
	} elsif ($source_id) {
		$sth = $dbh->prepare("select * from source where source_id=?");
		$sth->execute($source_id);
	} else {
		confess "No source id or name";
	}

	my $source = $sth->fetchrow_hashref();

	return $source;
}

sub blacklist_source {
	my $self = shift;
	my %args = @_;

	my $source_id   = $args{source_id};
	my $source_name = $args{source_name};

	my $dbh = $self->get_dbh();

	my $sth;
	if ($source_name) {
		$sth = $dbh->prepare("update source set blacklist=1 where source_name=?");
		$sth->execute($source_name);
	} elsif ($source_id) {
		$sth = $dbh->prepare("update source set blacklist=1 where source_id=?");
		$sth->execute($source_id);
	} else {
		confess "No source id or name";
	}

	return;
}

sub add_source {
	my $self = shift;
	my %args = @_;

	my $source_name = $args{source_name} or confess "No source name";
	my $rating                         = $args{rating} || 0;
	my $based_on_interest_in_source_id = $args{based_on_interest_in_source_id};
	my $based_on_interest_in_artist_id = $args{based_on_interest_in_artist_id};

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare("insert into source (source_name,rating,based_on_interest_in_source_id,based_on_interest_in_artist_id) values (?,?,?,?)");
	$sth->execute( $source_name, $rating, $based_on_interest_in_source_id, $based_on_interest_in_artist_id );

	my $source_id = $dbh->last_insert_id( '', '', '', '' );
	$self->output("Added source '$source_name' id '$source_id', rated initially at '$rating'.");

	if ($based_on_interest_in_source_id) {
		$self->output("Source '$source_name' was discovered based on interest in source '$based_on_interest_in_source_id'.");
	}
	if ($based_on_interest_in_artist_id) {
		$self->output("Source '$source_name' was discovered based on interest in artist '$based_on_interest_in_artist_id'.");
	}

	return $source_id;
}

sub add_artist {
	my $self = shift;
	my %args = @_;

	my $artist_name = $args{artist_name} or confess "No artist name";
	my $rating                         = $args{rating} || 0;
	my $based_on_interest_in_source_id = $args{based_on_interest_in_source_id};
	my $based_on_interest_in_artist_id = $args{based_on_interest_in_artist_id};

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare("insert into artist (artist_name,rating,based_on_interest_in_source_id,based_on_interest_in_artist_id) values (?,?,?,?)");
	$sth->execute( $artist_name, $rating, $based_on_interest_in_source_id, $based_on_interest_in_artist_id );
	my $artist_id = $dbh->last_insert_id( '', '', '', '' );
	$self->output("Added artist '$artist_name' id '$artist_id' with a rating of '$rating'.");

	if ($based_on_interest_in_source_id) {
		$self->output("Artist '$artist_name' was discovered based on interest in source '$based_on_interest_in_source_id'.");
	}
	if ($based_on_interest_in_artist_id) {
		$self->output("Artist '$artist_name' was discovered based on interest in artist '$based_on_interest_in_artist_id'.");
	}

	return $artist_id;
}

sub add_work {
	my $self = shift;
	my %args = @_;

	my $work_name = $args{work_name} or confess "No work name";
	my $artist_id = $args{artist_id} or confess "No artist id";
	my $source_id = $args{source_id};
	my $rating = $args{rating} || 0;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare("insert into work (work_name,artist_id,source_id,rating) values (?,?,?,?)");
	$sth->execute( $work_name, $artist_id, $source_id, $rating );
	my $work_id = $dbh->last_insert_id( '', '', '', '' );
	$self->output("Added work '$work_name' id '$work_id' by artist id '$artist_id'.");

	return $work_id;
}

sub add_acquisition {
	my $self = shift;
	my %args = @_;

	my $file               = $args{file} or confess "No file";
	my $why                = $args{why};
	my $source_id          = $args{source_id};
	my $marked_for_removal = $args{marked_for_removal};
	my $genre              = $args{genre};
	my $curated_filename   = $args{curated_filename};
	my $publish            = $args{publish};
	my $skipped            = $args{skipped};
	my $wanted             = $args{wanted};

	if ( !defined $wanted ) {
		$wanted = 1;
	}

	# figure out and store why we acquisitioned this acquisition
	my $why_artist_id;
	my $why_source_id;
	my $artist_name         = $why->{artist_name};
	my $artist_name_matches = $why->{artist_name_matches};
	my $artist_rating       = $why->{artist_rating};
	my $source_rating       = $why->{source_rating};

	$source_id ||= $why->{source_id};

	my $genre_id;
	if ($genre) {
		$genre_id = $self->lookup_or_add_genre( genre_name => $genre );
	}

	# only count the artist as a reason why we acquisitioned this work if the artist
	# is rated favorably. very often we acquisition an artist despite an unfavorable
	# rating because the source is highly-rated.
	if ( $artist_rating > 0 ) {

		# just use the first match that has a positive rating. close enough.
	MATCH: for my $match (@$artist_name_matches) {
			if ( $match->{rating} > 0 ) {
				$why_artist_id = $match->{artist_id};
			}
		}
	}

	# only count the source as a reason why we acquisitioned this work if the source
	# is rated favorably. very often we acquisition a work from a source despite an
	# unfavorable source rating because the source contained a highly-rated artist.
	if ( $source_rating > 0 ) {
		$why_source_id = $source_id;
	}

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( "
        insert into acquisition 
        (
            acquisition_destination, 
            source_id, 
            based_on_interest_in_source_id, 
            based_on_interest_in_artist_id, 
            marked_for_removal,
            genre_id,
            curated_filename,
            publish,
            skipped,
            wanted
        ) 
        values 
        (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
    " );
	$sth->execute( $file, $source_id, $why_source_id, $why_artist_id, $marked_for_removal, $genre_id, $curated_filename, $publish, $skipped, $wanted );
	my $acquisition_id = $dbh->last_insert_id( '', '', '', '' );
	$self->output("Added acquisition $acquisition_id '$file'.");

	return $acquisition_id;
}

sub make_acquisition_wanted {
	my $self = shift;
	my %args = @_;

	my $acquisition_id = $args{acquisition_id} or confess "Must provide acquistion_id";

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('update acquisition set wanted=1 where acquisition_id=?');
	$sth->execute($acquisition_id);

	return;
}

sub love {
	my $self = shift;
	my %args = @_;

	my $love = $self->{config}->{love} or confess 'No love rating';
	$self->rate_source_acquisition_artist_work( rating => $love, %args );

	return;
}

sub like {
	my $self = shift;
	my %args = @_;

	my $like = $self->{config}->{like} or confess 'No like rating';
	$self->rate_source_acquisition_artist_work( rating => $like, %args );

	return;
}

sub dislike {
	my $self = shift;
	my %args = @_;

	my $dislike = $self->{config}->{dislike} or confess 'No dislike rating';
	$self->rate_source_acquisition_artist_work( rating => $dislike, %args );

	return;
}

sub hate {
	my $self = shift;
	my %args = @_;

	my $hate = $self->{config}->{hate} or confess 'No hate rating';
	$self->rate_source_acquisition_artist_work( rating => $hate, %args );

	return;
}

sub like_percentage {
	my $self = shift;
	my %args = @_;

	my $dbh      = $self->get_dbh();
	my $like_sth = $dbh->prepare("select count(*) from acquisition where rating>0");
	$like_sth->execute();
	my ($like) = $like_sth->fetchrow_array();
	my $dislike_sth = $dbh->prepare("select count(*) from acquisition where rating<0");
	$dislike_sth->execute();
	my ($dislike) = $dislike_sth->fetchrow_array();
	my $percent   = 0;
	my $total     = $like + $dislike;
	if ($dislike) {
		$percent = sprintf( "%.2f", $like / $total * 100 );
	}

	return "$total evaluated, $percent\% liked";
}

sub acquisition_reason {
	my $self = shift;
	my %args = @_;

	my $file = $args{file} or confess 'No path and name provided';

	my $dbh                            = $self->get_dbh();
	my $acquisition                    = $self->lookup_acquisition( file => $file );
	my $based_on_interest_in_source_id = $acquisition->{based_on_interest_in_source_id};
	my $based_on_interest_in_artist_id = $acquisition->{based_on_interest_in_artist_id};
	my $reason;
	if ( $based_on_interest_in_source_id || $based_on_interest_in_artist_id ) {
		if ($based_on_interest_in_source_id) {
			my $sth = $dbh->prepare('select source_name from source where source_id = ?');
			$sth->execute($based_on_interest_in_source_id);
			my ($source_name) = $sth->fetchrow_array();
			$source_name or confess 'Could not find source name';
			$reason->{source} = $source_name;
		}
		if ($based_on_interest_in_artist_id) {
			my $sth = $dbh->prepare('select artist_name from artist where artist_id = ?');
			$sth->execute($based_on_interest_in_artist_id);
			my ($artist_name) = $sth->fetchrow_array();
			$artist_name or confess 'Could not find artist name';
			$reason->{artist} = $artist_name;
		}
	}

	return $reason;
}

sub mark_for_removal {
	my $self = shift;
	my %args = @_;

	my $file = $args{file} or confess 'No filename provided';

	my $acquisition = $self->lookup_acquisition( file => $file );

	# TODO XXX FIXME set acquisition rating also

	if ( $acquisition->{acquisition_id} ) {
		my $dbh = $self->get_dbh();
		my $sth = $dbh->prepare('update acquisition set marked_for_removal = 1 where acquisition_id = ?');
		$sth->execute( $acquisition->{acquisition_id} );
		return "'$file' acquisition id '$acquisition->{acquisition_id}' marked for removal";
	} else {
		my $class       = $self->get_class_name();
		my $source_name = $class->existing( file_location => $file, directory => $self->{directory} )->source();
		my $source_id   = $self->lookup_source( source_name => $source_name );
		if ( !$source_id ) {
			$source_id = $self->add_source( source_name => $source_name );
		}
		my $expected_location = File::Spec->catfile( App::MediaDiscovery::File::Curator::Secretary->new()->new_acquisitions_directory(), $source_name );
		if ( $file =~ m|^$expected_location| && $file !~ /\.\./ ) {

			# TODO XXX FIXME add artist and title. i didn't do this here because it's done elsewhere and needs to
			# be refactored. and i'm too lazy too repeat myself. so sometimes we won't have an artist and title.
			my $acquisition_id = $self->add_acquisition(
				file               => $file,
				why                => { source_id => $source_id },
				marked_for_removal => 1
			);
			return "'$file' acquisition id '$acquisition_id' was missing; added and immediately marked for removal";
		} else {
			confess "Illegal file location '$file'";
		}
	}

	return "Could not mark for removal because could not find or create acquisition '$file'";
}

sub mark_for_curation {
	my $self = shift;
	my %args = @_;

	my $file             = $args{file}             or confess 'No filename provided';
	my $genre            = $args{genre_name}       or confess 'No genre';
	my $curated_filename = $args{curated_filename} or confess 'No curated filename';
	my $publish          = $args{publish};

	my $genre_id = $self->lookup_or_add_genre( genre_name => $genre );
	my $acquisition = $self->lookup_acquisition( file => $file );

	if ( $acquisition->{acquisition_id} ) {
		my $dbh = $self->get_dbh();
		my $sth = $dbh->prepare('update acquisition set genre_id=?, curated_filename=?, publish=? where acquisition_id=?');
		$sth->execute( $genre_id, $curated_filename, $publish, $acquisition->{acquisition_id} );
		return "'$file' acquisition id '$acquisition->{acquisition_id}' marked for curation, genre_id is '$genre_id', new curated filename is '$curated_filename', publish is '$publish'";
	} else {
		my $class       = $self->get_class_name();
		my $source_name = $class->existing( file_location => $file, directory => $self->{directory} )->source();
		my $source_id   = $self->lookup_source( source_name => $source_name );
		if ( !$source_id ) {
			$source_id = $self->add_source( source_name => $source_name );
		}
		my $expected_location = File::Spec->catfile( App::MediaDiscovery::File::Curator::Secretary->new()->new_acquisitions_directory(), $source_name );
		if ( $file =~ m|^$expected_location| && $file !~ /\.\./ ) {

			# TODO XXX FIXME add artist and title. i didn't do this here because it's done elsewhere and needs to
			# be refactored. and i'm too lazy too repeat myself. so sometimes we won't have an artist and title.
			my $acquisition_id = $self->add_acquisition(
				file             => $file,
				why              => { source_id => $source_id },
				genre_id         => $genre_id,
				curated_filename => $curated_filename,
				publish          => $publish,
			);
			return "'$file' acquisition id '$acquisition_id' was missing; added and marked for curation, genre_id is '$genre_id', new curated filename is '$curated_filename', publish is '$publish'";
		} else {
			confess "Illegal file location '$file'";
		}
	}

	return "Could not mark for curation because could not find acquisition '$file'";
}

sub lookup_or_add_genre {
	my $self = shift;
	my %args = @_;

	my $genre = $args{genre_name} or confess 'No genre_name';

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('select genre_id from genre where genre_name=?');
	$sth->execute($genre);
	my ($genre_id) = $sth->fetchrow_array();

	if ( !$genre_id ) {
		$sth = $dbh->prepare('insert into genre (genre_name) values (?)');
		$sth->execute($genre);
		$genre_id = $dbh->last_insert_id( '', '', '', '' );
	}

	return $genre_id;
}

sub skip {
	my $self = shift;
	my %args = @_;

	my $file = $args{file} or confess 'No filename provided';
	my $acquisition = $self->lookup_acquisition( file => $file );

	if ( $acquisition->{acquisition_id} ) {
		my $dbh = $self->get_dbh();
		my $sth = $dbh->prepare('update acquisition set skipped = 1 where acquisition_id = ?');
		$sth->execute( $acquisition->{acquisition_id} );
		return "'$file' skipped";
	} else {
		my $class       = $self->get_class_name();
		my $source_name = $class->existing( file_location => $file, directory => $self->{directory} )->source();
		my $source_id   = $self->lookup_source( source_name => $source_name );
		if ( !$source_id ) {
			$source_id = $self->add_source( source_name => $source_name );
		}
		my $expected_location = File::Spec->catfile( App::MediaDiscovery::File::Curator::Secretary->new()->new_acquisitions_directory(), $source_name );
		if ( $file =~ m|^$expected_location| && $file !~ /\.\./ ) {

			# TODO XXX FIXME add artist and title. i didn't do this here because it's done elsewhere and needs to
			# be refactored. and i'm too lazy too repeat myself. so sometimes we won't have an artist and title.
			my $acquisition_id = $self->add_acquisition(
				file    => $file,
				why     => { source_id => $source_id },
				skipped => 1,
			);
			return "'$file' acquisition id '$acquisition_id' was missing; added and marked as skipped";
		} else {
			confess "Illegal file location '$file'";
		}
	}

	return "Could not skip";
}

sub clear_old_skipped {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('update acquisition set skipped=null');
	$sth->execute();

	return;
}

sub skipped_or_curated {
	my $self = shift;
	my %args = @_;

	my $file_object = $args{file} or confess 'No file object';
	my $acquisition_row;
	my $file_location = $file_object->path_and_name();

	$acquisition_row = $self->lookup_acquisition( file => $file_location );

	my $skip_this_one =
		( $acquisition_row->{marked_for_removal} || $acquisition_row->{skipped} || $acquisition_row->{curated_filename} || $acquisition_row->{publish} || $acquisition_row->{genre_id} );

	return $skip_this_one;
}

sub files_marked_for_removal {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( '
        select 
            acquisition_id, 
            acquisition_destination 
        from 
            acquisition 
        where 
            marked_for_removal = 1 
            and skipped is null
            and genre_id is null
            and publish is null
            and curated_filename is null
        limit 1
    ' );
	$sth->execute();
	my $files = $sth->fetchall_arrayref( {} );
	$files ||= [];

	return $files;
}

sub mark_removed {
	my $self = shift;
	my %args = @_;

	my $acquisition_id = $args{acquisition_id} or confess 'No acquisition id provided';

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('update acquisition set marked_for_removal=null where acquisition_id=?');
	$sth->execute($acquisition_id);

	return;
}

sub files_marked_for_curation {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( '
        select 
            acquisition_id, 
            acquisition_destination, 
            source_name,
            curated_filename, 
            genre_name, 
            publish 
        from 
            acquisition 
            inner join genre using (genre_id)
            left join source using (source_id)
        where 
            curated_filename is not null
        limit 
            1
    ' );
	$sth->execute();
	my $files = $sth->fetchall_arrayref( {} );
	$files ||= [];

	return $files;
}

sub mark_curated {
	my $self = shift;
	my %args = @_;

	my $acquisition_id = $args{acquisition_id} or confess 'No acquisition id provided';
	my $dbh = $self->get_dbh();

	my $sth = $dbh->prepare( '
        update 
            acquisition 
        set 
            curated_filename=null, 
            genre_id=null, 
            publish=null 
        where 
            acquisition_id=?
    ' );
	$sth->execute($acquisition_id);

	return;
}

# at the moment, marking curated and uncurated are the same thing in the database
sub mark_uncurated {
	return shift->mark_curated(@_);
}

sub favorite_sources {
	my $self = shift;
	my %args = @_;

	my $threshold = $args{threshold} || 0;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q(
        select
            source_name,
            rating
        from 
            source
        where
            rating >= ?
            and source_name like '%.%' 
            and source_name not like '%@%'  
        order by
            rating desc,
            source_name  
    )
	);
	$sth->execute($threshold);
	my $result = $sth->fetchall_arrayref( {} );
	$result ||= [];

	return $result;
}

sub all_source_scores {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q(
        select
            source_name,
            rating
        from 
            source
        order by
            rating desc,
            source_name  
    )
	);
	$sth->execute();
	my $result = $sth->fetchall_arrayref( {} );
	$result ||= [];

	return $result;
}

sub all_artist_scores {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q(
        select
            artist_name,
            rating
        from 
            artist
        order by
            rating desc,
            artist_name  
    )
	);
	$sth->execute();
	my $result = $sth->fetchall_arrayref( {} );
	$result ||= [];

	return $result;
}

sub scores_for_songs_from {
	my $self = shift;
	my %args = @_;

	my $source_name = $args{source_name};

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( '
        select 
            artist_name,
            work_name song_name,
            work.rating song_rating,
            source_name,
            source.rating source_rating 
        from 
            work 
            inner join source using (source_id) 
            inner join artist using (artist_id) 
        where 
            source_name = ?
    ' );
	$sth->execute($source_name);
	my $result = $sth->fetchall_arrayref( {} );
	$result ||= [];

	return $result;
}

sub genre_scores_for_sources {
	my $self = shift;
	my %args = @_;

	my $genre_name = $args{genre_name} or confess 'Must provide genre_name';

	my $genre_score_for_source;

	# here we are getting all the sources that we have genre information for,
	# and we're getting how likely they are to be sources providing works
	# mainly of the desired genre. we compare how many works we've categorized
	# for that source and genre, divided by the total number of works we've
	# categorized for that source, to get a score between 0 and 1. this score
	# represents how much that source qualifies as being in that genre. a
	# score of 0 means that we've never curated a work of the desired genre coming
	# from the source. a score of 1 means that every work that we've ever curated
	# from the source has been of the desired genre. a score of .5 means that
	# half of the works we've curated from this source were of the desired
	# genre, and half were not.
	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q{
        select 
            source_genre.source_id,
            source.source_name,
            source_genre.genre_id,
            genre.genre_name,
            count,
            sum(count) total,
            round((count/sum(count))*100) score 
        from 
            source_genre 
            inner join source using (source_id) 
            inner join genre using (genre_id) 
        group by 
            source_name 
        having 
            genre_name=?
    }
	);
	$sth->execute($genre_name);

	# grabbing more columns than we need, in case we ever want to print out debugging info or something
	while ( my ( $source_id, $source_name, $genre_id, $genre_name, $count, $total, $score ) = $sth->fetchrow_array() ) {
		$genre_score_for_source->{$source_name} = $score;
	}

	return $genre_score_for_source;
}

sub genre_scores_for_artists {
	my $self = shift;
	my %args = @_;

	my $genre_name = $args{genre_name} or confess 'Must provide genre_name';

	my $genre_score_for_artist;

	# here we are getting all the artists that we have genre information for,
	# and we're getting how likely they are to be artists creating works
	# mainly of the desired genre. we compare how many works we've categorized
	# for that artist and genre, divided by the total number of works we've
	# categorized for that artist, to get a score between 0 and 1. this score
	# represents how much that artist qualifies as being in that genre. a
	# score of 0 means that we've never curated a work of the desired genre coming
	# from the artist. a score of 1 means that every work that we've ever curated
	# from the artist has been of the desired genre. a score of .5 means that
	# half of the works we've curated from this artist were of the desired
	# genre, and half were not.
	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q{
        select 
            artist_genre.artist_id,
            artist.artist_name,
            artist_genre.genre_id,
            genre.genre_name,
            count,
            sum(count) total,
            round((count/sum(count))*100) score 
        from 
            artist_genre 
            inner join artist using (artist_id) 
            inner join genre using (genre_id) 
        group by 
            artist_name 
        having 
            genre_name=?
    }
	);
	$sth->execute($genre_name);

	# grabbing more columns than we need, in case we ever want to print out debugging info or something
	while ( my ( $artist_id, $artist_name, $genre_id, $genre_name, $count, $total, $score ) = $sth->fetchrow_array() ) {
		$genre_score_for_artist->{$artist_name} = $score;
	}

	return $genre_score_for_artist;
}

sub source_genre {
	my $self = shift;
	my %args = @_;

	my $source_name = $args{source_name} or confess 'Must provide source_name';
	my $source      = $self->lookup_source(@_);
	my $source_id   = $source->{id} or return;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( '
        select 
            genre_id
        from
            source_genre
        where
            source_id=?
            and count=
            (
                select 
                    max(count) 
                from 
                    source_genre
                where 
                    source_id=?
            )
    ' );
	$sth->execute( $source_id, $source_id );
	my ($genre_id) = $sth->fetchrow_array();
	my $genre = $self->lookup_genre( genre_id => $genre_id );

	return $genre->{genre_name};
}

sub artist_genre {
	my $self = shift;
	my %args = @_;

	my $artist_name = $args{artist_name} or confess 'Must provide artist_name';
	my $artist      = $self->lookup_artist(@_);
	my $artist_id   = $artist->{id} or return;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare( '
        select 
            genre_id
        from
            artist_genre
        where
            artist_id=?
            and count=
            (
                select 
                    max(count) 
                from 
                    artist_genre
                where 
                    artist_id=?
            )
    ' );
	$sth->execute( $artist_id, $artist_id );
	my ($genre_id) = $sth->fetchrow_array();
	my $genre = $self->lookup_genre( genre_id => $genre_id );

	return $genre->{genre_name};
}

sub good_enough_score_to_count_in_genre {
	my $self = shift;

	my $good_enough_score_to_count_in_genre_config = $self->{config}->{good_enough_score_to_count_in_genre} or die 'Could not get good_enough_score_to_count_in_genre from config';

	return $good_enough_score_to_count_in_genre_config;
}

# just used to print out all scores, as an informal backup or for debugging
sub show_source_scores {
	my $self = shift;

	my $sources = $self->all_source_scores();
	$self->output("-------------");
	$self->output("SOURCE SCORES");
	$self->output("-------------");
	for my $source (@$sources) {
		$self->output("$source->{source_name}\t$source->{rating}");
	}
	$self->output("-------------");

	return;
}

# just used to print out all scores, as an informal backup or for debugging
sub show_artist_scores {
	my $self = shift;

	my $artists = $self->all_artist_scores();
	$self->output("-------------");
	$self->output("ARTIST SCORES");
	$self->output("-------------");
	for my $artist (@$artists) {
		$self->output("$artist->{artist_name}\t$artist->{rating}");
	}
	$self->output("-------------");

	return;
}

sub why_was_it_downloaded {
	my $self = shift;
	my %args = @_;

	my $acquisition_destination = $args{acquisition_destination} or confess 'Must provide acquisition_destination';

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare(
		q(
        select 
            acquisition.based_on_interest_in_source_id, 
            acquisition.based_on_interest_in_artist_id,
            source.source_name,
            artist.artist_name
        from 
            acquisition
            left join artist on (acquisition.based_on_interest_in_artist_id=artist.artist_id)
            left join source on (acquisition.based_on_interest_in_source_id=source.source_id)
        where
            acquisition.acquisition_destination=?
    )
	);
	$sth->execute($acquisition_destination);
	my $why = $sth->fetchrow_hashref();

	return $why;
}

sub prepare_database {
	my $self = shift;
	my %args = @_;

	# handle differences between database back ends
	my $autoincrement;
	my $db = $self->{config}->{database};
	if ( $db =~ /mysql/i ) {
		$autoincrement = 'auto_increment';
	} elsif ( $db =~ /sqlite/i ) {

		# make database file's directory if need be
		my $path = $db;
		$path =~ s/^dbi:SQLite:dbname=//;
		my ( $volume, $directory, $file ) = File::Spec->splitpath($path);
		if ( !-d $directory ) {
			make_path $directory or confess "Could not make data directory '$directory'";
		}
		if ( !-x $directory ) {
			confess "Execute permissions needed for directory '$directory'";
		}

		$autoincrement = 'autoincrement';
	} else {
		die "Database '$db' is not yet supported";
	}

	my %definitions = (
		artist => "
            create table if not exists artist
            (
                artist_id integer primary key $autoincrement,
                artist_name varchar(255) not null unique,
                suggested_by varchar(255),
                rating integer not null default 0,
                based_on_interest_in_artist_id integer references artist (artist_id),
                based_on_interest_in_source_id integer references source (source_id)
            )
        ",
		work => "
            create table if not exists work
            (
                work_id integer primary key $autoincrement,
                work_name varchar(255) not null,
                artist_id integer not null references artist (artist_id),
                source_id integer references source (source_id),
                published boolean,
                rating integer not null default 0,
                based_on_interest_in_artist_id integer references artist (artist_id),
                based_on_interest_in_source_id integer references source (source_id)
            )
        ",
		source => "
            create table if not exists source
            (
                source_id integer primary key $autoincrement,
                source_name varchar(255) not null unique,
                rating integer not null default 0,
                based_on_interest_in_artist_id integer references artist (artist_id),
                based_on_interest_in_source_id integer references source (source_id),
                blacklist integer
            )
        ",
		acquisition => "
            create table if not exists acquisition
            (
                acquisition_id integer primary key $autoincrement,
                source_id integer not null references source (source_id),
                acquisition_destination varchar(255) not null unique,
                artist_id integer references artist (artist_id),
                work_id integer references work (work_id),        
                rating integer not null default 0,
                based_on_interest_in_artist_id integer references artist (artist_id),
                based_on_interest_in_source_id integer references source (source_id),
                marked_for_removal boolean,
                skipped boolean,
                publish boolean,  
                genre_id integer references genre (genre_id),
                curated_filename varchar(255),
                wanted boolean not null default true
            )
        ",
		genre => "
            create table if not exists genre
            (
                genre_id integer primary key $autoincrement,
                genre_name varchar(63) not null
            )
        ",
		artist_genre => "
            create table if not exists artist_genre
            (
                artist_genre_id integer primary key $autoincrement,
                artist_id integer not null references artist (artist_id),
                genre_id integer not null references genre (genre_id), 
                count integer not null,
                constraint artist_genre_unique unique (artist_id, genre_id)
            )
        ",
		source_genre => "
            create table if not exists source_genre
            (
                source_genre_id integer primary key $autoincrement,
                source_id integer not null references source (source_id),
                genre_id integer not null references genre (genre_id), 
                count integer not null,
                constraint source_genre_unique unique (source_id, genre_id)
            )
        ",
	);

	# if this is the first time running, or if tables are missing, fix this situation
	my $dbh = $self->get_dbh();

	for my $table ( keys %definitions ) {
		my $sth = $dbh->prepare( $definitions{$table} );
		$sth->execute();
	}

	return;
}

sub output {
	my $self = shift;
	my ($message) = @_;
	if ( $self->{verbose} ) {
		print color($color_1) . "$message\n" . color('reset');
	}
	return;
}

sub needs_to_know_tastes {
	my $self = shift;
	my %args = @_;

	my $dbh = $self->get_dbh();
	my $sth = $dbh->prepare('select count(*) from artist where rating>0');
	$sth->execute();
	my ($count) = $sth->fetchrow_array();
	my $minimum_count_of_liked_artists = $self->{config}->{minimum_count_of_liked_artists} or die 'minimum_count_of_liked_artists not configured';

	if ( $count < $minimum_count_of_liked_artists ) {

		#print "$count < $minimum_count_of_liked_artists\n";
		return 1;
	}

	return;
}

sub never_downloaded_anything_from_source {
	my $self = shift;
	my %args = @_;

	my $source_id = $args{source_id} or confess 'Must provide source_id';

	my $dbh = $self->get_dbh();

	# see if we have any acquisitions
	my $sth = $dbh->prepare('select count(*) from acquisition where source_id=?');
	$sth->execute($source_id);
	my ($acquisition_count) = $sth->fetchrow_array();

	# see if we've already rated this source somehow (even if we don't have acquisitions in db for some reason)
	my $source_rating = $self->source_rating( source_id => $source_id );

	if ( !$acquisition_count && !$source_rating ) {
		return 1;
	}

	return 0;
}

sub add_artists_works_and_ratings {
	my $self = shift;
	my %args = @_;

	my $artists = $args{artists} or die 'Must provide artists hashref';

	for my $artist ( sort keys %$artists ) {
		my $rating     = scalar @{ $artists->{$artist} };                  # make the count of works the score
		my $artist_row = $self->lookup_artist( artist_name => $artist );
		my $artist_id  = $artist_row->{artist_id};
		if ( !$artist_id ) {

			#$self->output("Adding $artist with a score of $rating.");
			$artist_id = $self->add_artist( artist_name => $artist, rating => $rating, );
		}
		for my $title ( @{ $artists->{$artist} } ) {
			if ($title) {
				my $work = $self->lookup_work( artist_id => $artist_id, work_name => $title, );
				my $work_id = $work->{work_id};
				if ( !$work_id ) {

					#$self->output("Adding $title by $artist.");
					$self->add_work( work_name => $title, artist_id => $artist_id, );
				}
			}
		}
	}

	return;
}

sub get_class_name {
	my $self = shift;
	my %args = @_;

	my $type = $self->{config}->{type};
	$type =~ /^\w+$/ or die "Invalid file type '$type' configued";
	my $uppercase_type = uc $type;
	my $class          = "App::MediaDiscovery::File::$uppercase_type";
	eval "require $class;";
	if ($@) {
		die "Could not load class '$class' to process files of type '$type': $@";
	}

	return $class;
}

1;

