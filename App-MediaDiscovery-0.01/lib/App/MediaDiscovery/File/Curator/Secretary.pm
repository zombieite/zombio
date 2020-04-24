use strict;

# this class is kind of a stub at the moment.
# it's kind of useful as a place to keep directory configs,
# but the long-term plan is to have it do all the "filing"
# too (as in, moving files around and renaming them).
# currently that functionality is in the curator.

package App::MediaDiscovery::File::Curator::Secretary;

use Carp;
use Config::General;
use Data::Dumper;
use File::Path qw(make_path);
use IO::Prompter;

use App::MediaDiscovery::File;
use App::MediaDiscovery::Directory;

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

	my $collection_directory_name = $self->get_collection_directory_name();

	my %required_configs = (
		new_acquisitions_directory      => File::Spec->catfile( $ENV{HOME}, 'zombio', 'music', 'new_acquisitions' ),
		curated_directory               => File::Spec->catfile( $ENV{HOME}, 'zombio', 'music', $collection_directory_name ),
		trash_directory                 => File::Spec->catfile( $ENV{HOME}, 'zombio', 'music', 'trash' ),
		lists_directory                 => File::Spec->catfile( $ENV{HOME}, 'zombio', 'music', 'playlists' ),
		blog_directory                  => File::Spec->catfile( $ENV{HOME}, 'zombio', 'music', 'blog' ),
		new_local_file_source_directory => undef,
	);
	for my $required_config ( keys %required_configs ) {
		if ( !defined $self->{config}->{$required_config} ) {
			$self->{config}->{$required_config} = $required_configs{$required_config};
		}
	}

	return $self;
}

# used in more than one place, so moved into a sub
sub get_collection_directory_name {
	return 'collection';
}

sub new_acquisitions_directory {
	my $self = shift;
	my %args = @_;

	my $new_acquisitions_directory = $self->{config}->{new_acquisitions_directory} or confess 'No new_acquisitions directory found';

	if ( !-d $new_acquisitions_directory ) {
		make_path $new_acquisitions_directory or confess "Could not make directory '$new_acquisitions_directory'";
	}

	return $new_acquisitions_directory;
}

sub new_local_file_source_directory {
	my $self = shift;
	my %args = @_;

	my $new_local_file_source_directory = $self->{config}->{new_local_file_source_directory};

	return $new_local_file_source_directory;
}

sub curated_directory {
	my $self = shift;
	my %args = @_;

	my $curated_directory = $self->{config}->{curated_directory} or confess 'No curated directory found';

	if ( !-d $curated_directory ) {
		make_path $curated_directory or confess "Could not make directory '$curated_directory'";
	}

	return $curated_directory;
}

sub lists_directory {
	my $self = shift;
	my %args = @_;

	my $lists_directory = $self->{config}->{lists_directory} or confess 'No lists directory found';

	if ( !-d $lists_directory ) {
		make_path $lists_directory or confess "Could not make directory '$lists_directory'";
	}

	return $lists_directory;
}

sub trash_directory {
	my $self = shift;
	my %args = @_;

	my $trash_directory = $self->{config}->{trash_directory} or confess 'No trash directory found';

	if ( !-d $trash_directory ) {
		make_path $trash_directory or confess "Could not make directory '$trash_directory'";
	}

	return $trash_directory;
}

sub blog_directory {
	my $self = shift;
	my %args = @_;

	my $blog_directory = $self->{config}->{blog_directory} or confess 'No blog directory found';

	if ( !-d $blog_directory ) {
		make_path $blog_directory or confess "Could not make directory '$blog_directory'";
	}

	return $self->{config}->{blog_directory};
}

sub backup_directory {
	my $self = shift;
	my %args = @_;

	# not required to be set, so we won't create it if missing

	return $self->{config}->{backup_directory};
}

sub content_subdirs {
	my $self = shift;
	my %args = @_;

	my $curated_directory = $self->curated_directory();
	my $content_subdirs   = App::MediaDiscovery::Directory->existing($curated_directory)->subdirs();
	@$content_subdirs = map { m|/([^/]+)$| } @$content_subdirs;

	return @$content_subdirs;
}

sub remove_empty_acquisition_directories {
	my $self = shift;
	my %args = @_;

	my $dir = $self->new_acquisitions_directory();
	-d $dir       or confess "Not a directory: '$dir'";
	$dir =~ /\w+/ or confess "Invalid directory: '$dir'";

	my $command = "find $dir -name .DS_Store -delete";
	system($command);

	$command = "find $dir -type d -empty";
	$self->output($command);
	my $dirs_string = `$command`;

	my @dirs = split( "\n", $dirs_string );
	for my $dir (@dirs) {
		$dir =~ s|([ \(\)'"&])|\\$1|g;

		$command = "find $dir -type f";
		$self->output($command);
		my $files_string = `$command`;

		if ( !$files_string ) {
			$self->output("Removing dir '$dir'.");

			rmdir $dir or $self->output($!);
		}
	}

	return;
}

sub empty_trash {
	my $self = shift;
	my %args = @_;

	my $file_type = $args{file_type} or confess 'Must provide file type';

	my $trash_dir = $self->trash_directory();

	my $trashed_files = App::MediaDiscovery::Directory->existing($trash_dir)->subfiles();

	for my $file (@$trashed_files) {
		#if ( $file =~ /$file_type$/ ) {
			unlink $file;
		#}
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

