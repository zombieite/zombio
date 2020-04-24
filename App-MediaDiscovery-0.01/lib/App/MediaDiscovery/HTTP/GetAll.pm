use strict;

# This module gets all files of a certain type that are
# referenced on a web page.

package App::MediaDiscovery::HTTP::GetAll;

use App::MediaDiscovery::HTTP;
use base('App::MediaDiscovery::HTTP');

use File::Spec;
use File::Path;
use URI::Escape;
use File::Path qw(make_path);

our $max_filename_length = 100;

sub get_all {
	my $self   = shift;
	my %params = @_;

	my @downloaded_files;
	my $page        = $params{page}        or die "No page";
	my $file_type   = $params{file_type}   or die "No file type";
	my $out_dir     = $params{directory}   or die "No directory";
	my $source_name = $params{source_name} or die "No source name";
	my $why         = $params{why};
	my $number_of_files_left_to_get = $params{maximum_number_of_files_to_get} || 100;

	$self->output("Maximum number of files to get: '$number_of_files_left_to_get'.");

	my $html = $self->get( http_file => $page );
	if ( !$html ) {
		$self->output("No content returned for page '$page'.");
		return;
	}

	my $successfully_parsed_count = 0;

	#$self->output( "Parsing html.\n" );
	# find double-quoted links to files of the type we want
	while ( $html =~ /"([^"]+\.$file_type)"/g ) {
		if ( $number_of_files_left_to_get > 0 ) {
			$self->output("File count still wanted is '$number_of_files_left_to_get'.");
			$successfully_parsed_count++;
			my $wanted_file = $self->handle_wanted_file_link( link => $1, %params );
			if ($wanted_file) {
				push( @downloaded_files, $wanted_file );
				$number_of_files_left_to_get--;
				$self->output("Got file.");
			} else {
				$self->output("Did not want file.");
			}
		}
	}

	# find single-quoted links to files of the type we want
	while ( $html =~ /'([^']+\.$file_type)'/g ) {
		if ( $number_of_files_left_to_get > 0 ) {
			$self->output("File count still wanted is '$number_of_files_left_to_get'.");
			$successfully_parsed_count++;
			my $wanted_file = $self->handle_wanted_file_link( link => $1, %params );
			if ($wanted_file) {
				push( @downloaded_files, $wanted_file );
				$number_of_files_left_to_get--;
				$self->output("Got file.");
			} else {
				$self->output("Did not want file.");
			}
		}
	}

	if ( !$successfully_parsed_count ) {
		$self->output("Could not find any files parsing page '$page'.");
	}

	return @downloaded_files;
}

sub handle_wanted_file_link {
	my $self   = shift;
	my %params = @_;

	my $wanted_file = $params{link}        or die "No link";
	my $page        = $params{page}        or die "No page";
	my $file_type   = $params{file_type}   or die "No file type";
	my $out_dir     = $params{directory}   or die "No directory";
	my $source_name = $params{source_name} or die "No source name";
	my $why         = $params{why};

	$self->{download_counter}->{$source_name} ||= 0;

	# handle non-fully-qualified links
	if ( $wanted_file !~ m|^http| ) {

		# TODO XXX FIXME does this handle relative URLs? i don't think it does. but no one uses relative URLs so meh.
		$wanted_file = "$page$wanted_file";
	}

	##########################################################################################################
	# hack: not sure how to abstract this kind of thing yet. it should be configurable, a plugin or something.
	# but, at the same time, i don't want to make this code too complex. for now i think it makes sense to
	# just drop this stuff in here.
	##########################################################################################################
	# handle various browser players
	if ( $wanted_file =~ /soundFile=(.+)$/ ) {
		$self->output("Translating '$wanted_file'.");
		$wanted_file = URI::Escape::uri_unescape($1);
		$self->output("Translated as '$wanted_file'.");
	}
	if ( $wanted_file =~ /^http%3A%2F%2F/ ) {
		$self->output("Translating '$wanted_file'.");
		$wanted_file = URI::Escape::uri_unescape($wanted_file);
		$self->output("Translated as '$wanted_file'.");
	}
	##########################################################################################################
	# end hack
	##########################################################################################################

	my $filename;
	if ( $wanted_file =~ m|/([^/]+\.$file_type)| ) {
		$filename = $1;
	} else {
		$self->output("'$wanted_file' doesn't look right.");
		return;
	}

	# clean the filename to make it more readable (and less likely to contain shell commands in its name
	# since i use poorly escaped shell commands on files in some places)
	$filename = lc($filename);                                             # lowercase
	$filename =~ s|\.$file_type$||g;                                       # remove file extension. we'll add it back in later.
	$filename =~ s|'||g;                                                   # remove single quotes entirely
	$filename =~ s|"||g;                                                   # remove double quotes entirely
	$filename =~ s|[^[:ascii:]]|_|g;                                       # remove non-ascii
	$filename =~ s|[^\w^\-]+|_|g;                                          # replace all non-letter, non-number, non-hyphen, non-underscores with an underscore
	$filename =~ s/20|21|22|23|24|25|26|27|28|29|2A|2B|2C|2D|2E|2F/_/g;    # remove all "_20"s formerly "%20" and such
	$filename =~ s|_+|_|g;                                                 # remove all multiple underscores
	$filename =~ s|^_+||;                                                  # remove all leading underscores
	$filename =~ s|_$||;                                                   # remove all trailing underscores
	$filename =~ s|_-|-|g;                                                 # remove extra underscores before hyphens
	$filename =~ s|-_|-|g;                                                 # remove extra underscores after hyphens
	$filename .= ".$file_type";

	if ( length($filename) > $max_filename_length ) {
		$self->output("Filename too long; failed to extract from '$wanted_file'.");
		return;
	}
	if ( !$filename ) {
		$self->output("Could not get a filename for '$wanted_file'.");
		return;
	}
	my $destination_file = File::Spec->catfile( $out_dir, $filename );
	if ( -f ($destination_file) ) {
		$self->output("'$destination_file' exists on disk; skipping.");
		return;
	}

	# this is a pre-download check, if we have a download checker object.
	# mainly we're checking to see if it already exists on disk, or it's
	# been downloaded before.
	my $download_checker = $self->{download_checker};
	if (
		$download_checker
		&& !$download_checker->ok_to_acquire(
			source_name       => $source_name,
			save_destination  => $destination_file,
			acquisition_count => $self->{download_counter}->{$source_name},
		)
		)
	{
		$self->output("Not ok to download.");
		return;
	}

	my $string_length = length $wanted_file;
	$self->output( "-" x $string_length );
	$self->output($wanted_file);
	$self->output( "-" x $string_length );
	#$self->output("Getting '$wanted_file'; storing it at '$destination_file'.");
	if ( !-d $out_dir ) {
		make_path $out_dir;
	}
	my $wanted_file_contents = $self->getstore( http_file => $wanted_file, disk_file => $destination_file );
	if ( !-f $destination_file ) {
		$self->output( "Could not download destination file '$destination_file'" );
		return;
	}
	$self->{download_counter}->{$source_name}++;

	# this is a post-download check, if we have a download checker object/
	# mainly we're checking to see if we've already downloaded this work
	# before, from another source, for instance.
	if ($download_checker) {
		if ( $download_checker->add_acquisition_and_decide_if_work_is_worth_evaluating( file => $destination_file, why_downloaded => $why ) ) {
			$self->output("Keeping '$destination_file'.");
		} else {
			$self->output("Removing '$destination_file'.");
			unlink $destination_file;
			return;
		}
	}

	return $destination_file;
}

1;
