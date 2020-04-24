use strict;

# This module is a subclass of the App::MediaDiscovery::File class which
# works specifically with MP3 files. It allows the user
# to search, tag, rename, and rate MP3 files.

package App::MediaDiscovery::File::MP3;

use App::MediaDiscovery::File;
use base ('App::MediaDiscovery::File');

use MP3::Info;
use MP3::Tag;
use Carp;

use App::MediaDiscovery::Directory;
use App::MediaDiscovery::File::Curator::Secretary;    # to determine if a file is already curated or not, by its directory name

sub load_tags {
	my $self = shift;

	#warn "Loading tags\n";
	my $mp3_tags = MP3::Tag->new( $self->path_and_name() );

	#warn "Tags loaded\n";
	#local $SIG{__WARN__}=sub{}; #MP3::Tag::IDv2.pm has too many warnings
	my @autoinfo;
	if ($mp3_tags) {

		# sometimes dies with UTF-16:Unrecognised BOM 5000
		eval { @autoinfo = $mp3_tags->autoinfo(); };
	} else {
		warn "Could not get tags from file '" . $self->path_and_name() . "'";
	}
	my ( $title, $track, $artist, $album, $comment, $year, $genre ) = @autoinfo;
	for ( $title, $track, $artist, $album, $comment, $year, $genre ) { $_ ||= ''; }    #initialize undefs
	my $time = MP3::Info::get_mp3info( $self->path_and_name() );

	#warn "Checking minutes and seconds tags\n";
	if ( defined( $time->{MM} ) && defined( $time->{SS} ) ) {
		$self->{seconds} = ( $time->{MM} * 60 + $time->{SS} );

		#warn "File is '$self->{seconds}' long\n";
	} else {
		$self->{seconds} = 0;

		#warn "Not tagged with run time\n";
	}
	for my $possibly_empty_field ( $title, $artist ) {

		# clean up these fields a bit also while we're here
		$possibly_empty_field =~ s/\s+/ /g;

		if ( !$possibly_empty_field ) {
			my $filename_no_ext = $self->filename();
			$filename_no_ext =~ s/\.\w+$//;
			$possibly_empty_field = $self->clean_with_spaces($filename_no_ext);
		}
	}

	# if it's a curated file, we should be able to determine artist, work name, and genre from file path and name
	my $collection_directory_name = App::MediaDiscovery::File::Curator::Secretary->get_collection_directory_name();
	if ( $self->path_and_name() =~ /$collection_directory_name/ ) {
		my $filename   = $self->filename();
		if ( $filename =~ /^([\w\-]+)-(\w+)\.mp3$/ ) {
			$artist = $1;
			$title  = $2;
			#$artist =~ s/-/ and /g;    # multiple artist names separated by hyphens
			for ( $artist, $title ) {
				s/_/ /g;
			}
		}

		# i don't tag genre; i keep it in the path
		my $path = $self->filepath();
		if ( $path =~ m|/([^/]+)/([a-z]/)?$| ) {
			$genre = $1;
		} else {
			confess "Could not get genre from curated directory '$path'";
		}
	}

	$self->{title}        = $title;
	$self->{artist}       = $artist;
	$self->{genre}        = $genre;
	$self->{clean_title}  = $self->clean_with_spaces( $self->{title} );
	$self->{clean_artist} = $self->clean_with_spaces( $self->{artist} );

	$self->{tags_loaded} = 1;

	return;
}

sub artist {
	my $self = shift;

	if ( !$self->{tags_loaded} ) {
		$self->load_tags();
	}
	if (@_) {
		( $self->{artist} )       = @_;
		( $self->{clean_artist} ) = @_;
	}

	return $self->{artist};
}

sub title {
	my $self = shift;

	if ( !$self->{tags_loaded} ) {
		$self->load_tags();
	}
	if (@_) {
		( $self->{title} )       = @_;
		( $self->{clean_title} ) = @_;
	}

	return $self->{title};
}

sub clean_title {
	my $self = shift;

	if ( !$self->{tags_loaded} ) {
		$self->load_tags();
	}

	return $self->{clean_title};
}

sub clean_artist {
	my $self = shift;

	if ( !$self->{tags_loaded} ) {
		$self->load_tags();
	}

	return $self->{clean_artist};
}

sub genre {
	my $self = shift;
	if ( !$self->{tags_loaded} ) {
		$self->load_tags();
	}
	if (@_) {
		( $self->{genre} ) = @_;
	}
	return $self->{genre};
}

sub seconds {

	#warn "Checking seconds\n";
	my $self = shift;
	if ( !$self->{tags_loaded} ) {

		#warn "Tags not loaded\n";
		$self->load_tags();
	} else {

		#warn "Tags already loaded\n";
	}
	return $self->{seconds};
}

sub check_filename {
	my $self = shift;
	my ($filename) = @_;
	$filename ||= $self->filename();
	if ( $self->SUPER::check_filename($filename) ) {
		if ( $filename =~ m|^[a-z0-9_\-]+-[a-z0-9_]+\.mp3$| ) {
			( $self->{artist}, $self->{title} ) = $self->artist_and_title_from_filename($filename);
			return 1;
		} else {
			warn "Nonstandard song filename: '$filename'\n";
		}
	} else {
		warn "Nonstandard filename: '$filename'\n";
	}
	return 0;
}

sub suggested_filename {
	my $self = shift;
	my ( $artist, $title ) = ( $self->artist(), $self->title() );

	my $suggested_filename = '';

	my $location = $self->path_and_name();          #add filename and directories to name string in case they are needed
	$location =~ s|$self->{content_directory}||;    #remove name of directory where all songs live
	$suggested_filename = $self->clean($artist) . '-' . $self->clean($title) . '.mp3';

	return $suggested_filename;
}

sub matches_search_term {
	my $self        = shift;
	my %params      = @_;
	my $search_term = $params{search_term};
	my $check_tags  = $params{check_metadata};
	if ( !$search_term ) {
		confess "no search term";
	}
	if ( $self->SUPER::matches_search_term( search_term => $search_term ) ) {
		return 1;
	}
	if ($check_tags) {

		#warn "checking tags\n";
		if (   $self->artist() =~ m|$search_term|i
			|| $self->title() =~ m|$search_term|i
			|| $self->genre() =~ m|$search_term|i )
		{
			return 1;
		}
	}
	return;
}

sub tag {
	my $self   = shift;
	my %params = @_;
	my $artist = $params{artist} or confess "Must provide artist";
	my $title  = $params{title} or confess "Must provide title";

	eval {
		my $mp3 = MP3::Tag->new( $self->path_and_name() );
		$mp3 or confess "Could not get mp3 tag object from " . $self->path_and_name();
		my $id3v2 = $mp3->new_tag("ID3v2");
		$id3v2->add_frame( "TPE1", $artist );
		$id3v2->add_frame( "TIT2", $title );
		$id3v2->write_tag();
		$mp3->close();
	};
	if ($@) {

		#warn $@; # don't really care if we can't tag a file. we'll just give it a meaningful filename (later).
	}

	return;
}

sub tag_by_filename {
	my $self = shift;

	my $filename = $self->filename();
	my ( $artist, $title ) = $self->artist_and_title_from_filename($filename);
	$artist or confess "No artist found in filename '$filename'";
	$title  or confess "No title found in filename '$filename'";
	$self->tag( artist => $artist, title => $title );

	return;
}

sub artist_and_title_from_filename {
	my $self = shift;
	my ($filename) = @_;

	$filename =~ s/_/ /g;
	$filename =~ s/\.mp3$//;
	my @artists_and_title = split( '-', $filename );
	my $title             = pop @artists_and_title;
	#my $artist            = join( ' and ', @artists_and_title );
	my $artist            = join( ' - ', @artists_and_title );

	return ( $artist, $title );
}

sub evaluation_message {
	my $self = shift;

	my $console_playing_msg = '';
	my $file_size_mb        = $self->mb() . 'MB';
	my $artist              = $self->artist();
	my $title               = $self->title();
	my $source              = $self->source();
	my $filename            = $self->filename();

	my $number_message = '';
	if ($filename =~ /^([0-9]+)/) {
		$number_message = "$1 | ";
	}

	$console_playing_msg = "$number_message$artist | $title";

	return $console_playing_msg;
}

sub evaluation_message_details {
	my $self = shift;

	my $details      = '';
	my $file_size_mb = $self->mb() . 'MB';
	my $artist       = $self->artist();
	my $title        = $self->title();
	my $source       = $self->source();
	my $filename     = $self->path_and_name();

	$details = "$filename $file_size_mb";

	return $details;
}

sub source {
	my $self = shift;

	# cache this within object because sometimes we move a file and then keep playing it,
	# thereby screwing up source_from_path_and_name(). and source should not ever change.
	if ( $self->{source} ) {
		return $self->{source};
	}

	$self->{source} = $self->source_from_path_and_name( file => $self->path_and_name() );

	return $self->{source};
}

sub source_from_path_and_name {
	my $self   = shift;
	my %params = @_;

	my $file = $params{file} or confess 'Must provide file path and name';

	my @tokens   = split( '/', $file );
	my $filename = pop @tokens;
	my $source   = pop @tokens;

	# optional one-letter directory files can live under
	if ( $source =~ /^\w$/ ) {
		$source = pop @tokens;
	}

	$source or confess "Could not get source from path and name '$file'";

	return $source;
}

sub clean {
	my $self = shift;
	my ($thing_to_clean) = @_;

	$thing_to_clean =~ s/^\s+//g;
	$thing_to_clean =~ s/\s+$//g;
	$thing_to_clean =~ s/\s+/ /g;
	$thing_to_clean = lc($thing_to_clean);    # lowercase

	# remove extension if present, so we don't screw it up
	my $extension = '';
	if ( $thing_to_clean =~ /(\.\w+)$/ ) {
		$extension = $1;
		$thing_to_clean =~ s/$extension$//;
	}

	$thing_to_clean =~ s/^(the |a |an )//i;    # remove initial articles
	$thing_to_clean =~ s|'||g;                 # remove single quotes entirely
	$thing_to_clean =~ s|\.||g;                # remove periods entirely
	$thing_to_clean =~ s|&|and|g;              # expand ampersands
	$thing_to_clean =~ s|[^\w\-]+|_|g;         # replace all non-letter, non-number, non-hyphen, non-underscores with underscores
	$thing_to_clean =~ s|[^[:ascii:]]|_|g;     # remove non-ascii also
	$thing_to_clean =~ s/[\x00-\x1F]//g;       # these characters make no sense
	$thing_to_clean =~ s/[\x7F]//g;            # these characters make no sense
	$thing_to_clean =~ s|_feat_|-|g;           # replace "feat" (featuring) with hyphen indicating multiple artists
	$thing_to_clean =~ s|^[_\-]+||;            # remove all leading underscores and hyphens
	$thing_to_clean =~ s|[_\-]+$||;            # remove all trailing underscores and hyphens
	$thing_to_clean =~ s|_+|_|g;               # remove repeated underscores
	$thing_to_clean =~ s|-+|-|g;               # remove repeated hyphens
	$thing_to_clean =~ s|_-|-|g;               # remove underscores around hyphens
	$thing_to_clean =~ s|-_|-|g;               # remove underscores around hyphens
	$thing_to_clean =~ s/^\s+//g;              # remove spaces at beginning
	$thing_to_clean =~ s/\s+$//g;              # remove spaces at end
	$thing_to_clean =~ s/\s+/ /g;              # replace multiple spaces with a single space
	$thing_to_clean =~ s/^_+//g;               # remove underscores at beginning
	$thing_to_clean =~ s/_+$//g;               # remove underscores at end
	$thing_to_clean =~ s/_+/_/g;               # replace multiple underscores with a single underscore

	# put extension back on, if we have one
	$thing_to_clean .= $extension;

	return $thing_to_clean;
}

sub clean_with_spaces {
	my $self = shift;
	my ($thing_to_clean) = @_;

	$thing_to_clean = $self->clean($thing_to_clean);
	$thing_to_clean =~ s/_/ /g;
	$thing_to_clean =~ s/\./ /g;    # clean with spaces won't be cleaning filenames by my naming conventions, so remove periods too

	return $thing_to_clean;
}

# add tags to renamed mp3 files also
sub move_to_new_path_and_name {
	my $self = shift;

	$self->tag(
		artist => scalar( $self->artist() ),
		title  => scalar( $self->title() ),
	);

	return $self->SUPER::move_to_new_path_and_name(@_);
}

1;
