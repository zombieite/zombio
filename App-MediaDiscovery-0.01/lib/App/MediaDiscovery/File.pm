use strict;

package App::MediaDiscovery::File;

use File::Spec;
use File::Copy;
use Carp;
use Data::Dumper;

sub existing {
	my $class = shift;
	my (%params) = @_;

	my $self = bless( \%params, $class );

	if ( $self->{file_location} ) {
		if ( -f ( $self->{file_location} ) ) {
			( undef, $self->{filepath}, $self->{filename} ) = File::Spec->splitpath( $self->{file_location} );
		} else {
			confess "File '$self->{file_location}' does not exist";
		}
	} else {
		confess "Must provide file location";
	}

	return $self;
}

sub create {
	my $class = shift;
	my ($file_location) = @_;

	if ($file_location) {
		if ( -f ($file_location) ) {
			confess "File '$file_location' already exists; cannot create";
		}
	} else {
		confess "Must provide file location";
	}
	my ( $filepath, $filename ) = File::Spec->splitpath($file_location);
	$class->check_filename( filename => $filename );
	system("touch $file_location") and confess "Could not touch '$file_location'";

	return $class->existing( file_location => $file_location );
}

sub create_or_replace {
	my $class = shift;
	my ($file_location) = @_;

	if ( !$file_location ) {
		confess "Must provide file location";
	}
	my ( $filepath, $filename ) = File::Spec->splitpath($file_location);
	$class->check_filename( filename => $filename );
	system("touch $file_location") and confess "Could not touch '$file_location'";

	return $class->existing( file_location => $file_location );
}

sub as_string {
	return shift->path_and_name();
}

sub content {
	my $self = shift;

	my $content;
	my $path_and_name = $self->path_and_name();
	open( my $file, '<', $path_and_name ) or confess "Could not open '$path_and_name': $!";
	local $/;
	defined( $content = <$file> ) or confess $!;
	close $file or confess $!;

	return $content;
}

sub write_content {
	my $self = shift;
	my ($content) = @_;

	my $path_and_name = $self->path_and_name();
	open( my $file, '>', $path_and_name ) or confess "Could not open '$path_and_name': $!";
	print $file $content or confess $!;

	close $file or confess $!;
}

sub size {
	my $self = shift;

	my $bytes = -s ( $self->path_and_name() );
	$bytes += 0;

	return $bytes;
}

sub ctime {
	my $self = shift;
	my ( $dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks ) = stat( $self->path_and_name() );
	return $ctime;
}

sub mtime {
	my $self = shift;
	my ( $dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks ) = stat( $self->path_and_name() );
	return $mtime;
}

sub atime {
	my $self = shift;
	my ( $dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks ) = stat( $self->path_and_name() );
	return $atime;
}

sub mb {
	my $self = shift;

	my $mb = sprintf( "%.2f", ( $self->size() ) / ( 2**20 ) );
	$mb += 0;

	return $mb;
}

sub approximate_mb {
	my $self = shift;

	my $mb = int( $self->size() / ( 2**20 ) + 0.5 );
	$mb += 0;

	return $mb;
}

sub filepath {
	my $self = shift;

	return $self->{filepath};
}

sub filename {
	my $self = shift;

	return $self->{filename};
}

sub basename {
	return shift->filename();
}

sub path_and_name {
	my $self = shift;

	return File::Spec->catfile( $self->filepath(), $self->filename() );
}

sub extension {
	my $self = shift;

	my $filename = $self->filename();
	if ( $filename =~ /\.(\w+)$/ ) {
		return $1;
	}

	return;
}

sub check_filename {
	my $self = shift;
	my ($filename) = @_;

	$filename ||= $self->filename();
	if ( $filename =~ m|^[a-z0-9_\-\.]+$| ) {
		return 1;
	}

	return 0;
}

sub new_filepath {
	my $self = shift;

	if (@_) {
		( $self->{new_filepath} ) = @_;
		if ( !( -d ( $self->{new_filepath} ) ) ) {
			confess "'$self->{new_filepath}' is not a valid directory";
		}
	}

	return $self->{new_filepath};
}

sub new_filename {
	my $self = shift;

	if (@_) {
		( $self->{new_filename} ) = @_;

		#print "File will be renamed to '$self->{new_filename}'\n";
	}

	return $self->{new_filename};
}

sub new_path_and_name {
	my $self = shift;

	return File::Spec->catfile( $self->new_filepath(), $self->new_filename() );
}

sub move_to_new_path_and_name {
	my $self = shift;

	$self->new_filepath() or confess "No new path is present";
	$self->new_filename() or $self->new_filename( $self->filename() );

	#print "moving to ".$self->new_path_and_name()."\n";

	return $self->move_to( $self->new_path_and_name() );
}

sub copy_to_new_path_and_name {
	my $self = shift;

	$self->new_filepath() or confess "No new path is present";
	$self->new_filename() or $self->new_filename( $self->filename() );

	#print "moving to ".$self->new_path_and_name()."\n";

	return $self->save_copy_as( $self->new_path_and_name() );
}

sub rename_to_new_path_and_name_on_same_filesystem {
	my $self = shift;

	$self->new_filepath() or confess "No new path is present";
	$self->new_filename() or $self->new_filename( $self->filename() );

	#print "moving to ".$self->new_path_and_name()."\n";

	return $self->rename_to_on_same_filesystem( $self->new_path_and_name() );
}

sub move_to {
	my $self = shift;
	my ($move_location) = @_;

	if ( -f $move_location ) {
		confess "Cannot move; file exists: $move_location";
	}

	#print "really moving ".$self->path_and_name()." to $move_location\n";
	copy( $self->path_and_name(), $move_location ) or confess $!;
	unlink $self->path_and_name() or confess $!;
	( undef, $self->{filepath}, $self->{filename} ) = File::Spec->splitpath($move_location);

	return "Moved to $move_location\n";
}

sub move_to_directory {
	my $self = shift;
	my ($move_location) = @_;

	#print "really moving ".$self->path_and_name()." to $move_location\n";
	copy( $self->path_and_name(), File::Spec->catfile($move_location, $self->basename()) ) or confess $!;
	unlink $self->path_and_name() or confess $!;
	( undef, $self->{filepath} ) = File::Spec->splitpath($move_location);

	return "Moved to $move_location\n";
}

sub rename_to_on_same_filesystem {
	my $self = shift;
	my ($move_location) = @_;

	if ( -f ($move_location) ) {
		confess "Cannot move; file exists: $move_location";
	}

	#print "really moving ".$self->path_and_name()." to $move_location\n";
	rename( $self->path_and_name(), $move_location ) or confess "'$move_location': $!";
	( undef, $self->{filepath}, $self->{filename} ) = File::Spec->splitpath($move_location);

	return "Moved to '$move_location'\n";
}

sub save_as {
	my $self = shift;
	my ($copy_location) = @_;

	$self->save($copy_location);
	( undef, $self->{filepath}, $self->{filename} ) = File::Spec->splitpath($copy_location);

	return "Saved as '$copy_location'\n";
}

sub save_copy_as {
	my $self = shift;
	my ($copy_location) = @_;

	if ( -f ($copy_location) ) {
		confess "Cannot copy; file exists: $copy_location";
	}
	File::Copy::copy( $self->path_and_name(), $copy_location ) or confess "$!: '$copy_location'";

	return "Copy saved as '$copy_location'\n";
}

sub matches_search_term {
	my $self   = shift;
	my %params = @_;

	my $search_term = $params{search_term};
	if ( !$search_term ) {
		confess "No search term";
	}
	if ( $self->path_and_name() =~ m|$search_term|i ) {
		return 1;
	}

	return;
}

sub matches_search_terms {
	my $self   = shift;
	my %params = @_;

	my $search_terms   = $params{search_terms};
	my $check_metadata = $params{check_metadata};
	for my $term (@$search_terms) {

		#print "checking for term '$term'\n";
		if ( !$self->matches_search_term( search_term => $term, check_metadata => $check_metadata ) ) {

			#print $self->as_string() . " does not match term '$term'\n";
			return;
		} else {

			#print "matches term '$term'\n";
		}
	}

	return 1;    #if no search terms are configured, then we match (no filter means all match)
}

sub choose_filename {
	my $self = shift;

	return $self->prompt_new_filename($_);
}

sub choose_directory {
	my $self = shift;

	return $self->prompt_new_filepath($_);
}

sub evaluation_message {
	my $self = shift;

	return $self->as_string();
}

sub evaluation_message_details {
	my $self = shift;

	return;
}

sub seconds {
	return 10;    # A file type may or may not have a "seconds" attribute, but this still serves as "how long to keep the file open while evaluating"
}

sub artist {
	return;
}

sub title {
	return;
}

sub source {
	return;
}

sub suggested_filename {
	my $self = shift;

	my $existing_files_string = `find $self->{curated_directory} -type f`;
	my @existing_filenames = split( "\n", $existing_files_string );
	@existing_filenames = map { App::MediaDiscovery::File->existing( file_location => $_ )->filename() } @existing_filenames;
	my $file_number = 1;
	while ( grep { $_ eq "$file_number.$self->{type}" } @existing_filenames ) {
		$file_number++;
	}

	return "$file_number.$self->{type}";
}

sub clean_artist {
	return;
}

sub history_index {
	my $self = shift;
	if (@_) {
		($self->{history_index}) = @_;
	}
	return $self->{history_index};
}

1;
