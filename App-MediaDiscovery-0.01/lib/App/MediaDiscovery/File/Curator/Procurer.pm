use strict;
# This is the module that uses user preferences to decide what new works to acquire, and acquires those works.

package App::MediaDiscovery::File::Curator::Procurer;

use Config::General;
use Carp qw(confess cluck);
use XML::Simple;
use File::Spec;
use List::Util qw(shuffle);
use Data::Dumper;

use App::MediaDiscovery::HTTP::GetAll;
use App::MediaDiscovery::File::Curator::Secretary;
use App::MediaDiscovery::File::Curator::Scorekeeper;
use App::MediaDiscovery::File;
use App::MediaDiscovery::Directory;

sub new {
	my $class  = shift;
	my %params = @_;
	my $self   = bless( \%params, $class );

	my $config_file = File::Spec->catfile( $ENV{HOME}, 'zombio', 'config', split( /::/, __PACKAGE__ ) ) . '.conf';

	if ( -f $config_file ) {
		my %file_config;
		my $conf = Config::General->new($config_file);
		%file_config = $conf->getall();
		$self->{config} = \%file_config;
	}

	my %required_configs = (
		feed_plugin                                       => 'App::MediaDiscovery::File::Curator::Procurer::FeedParser::HypeM',
		maximum_number_of_files_to_get_from_a_new_source  => 50,
		times_to_run                                      => 500,
		minutes_between_runs                              => 60,
		maximum_number_of_files_to_get_per_source_per_run => 50,
		top_source_threshold_to_check                     => -100,
		files_to_have_before_respecting_blackout_window   => 500,
		blackout_window_start                             => 0,
		blackout_window_end                               => 0,
		file_extension                                    => 'mp3', # Duplicated config from Curator.pm, not ideal
		new_local_files_to_procure_each_startup           => 0,
		local_collection_files_to_recycle_each_startup    => 0,

	);
	for my $required_config ( keys %required_configs ) {
		if ( !defined $self->{config}->{$required_config} ) {
			$self->{config}->{$required_config} = $required_configs{$required_config};
		}
	}

	my $secretary = App::MediaDiscovery::File::Curator::Secretary->new( verbose => $self->{verbose}, );
	$self->{secretary} = $secretary;

	return $self;
}

sub procure {
	my $self   = shift;
	my %params = @_;

	my $secretary = $self->{secretary};

	# This section will trickle in a few files from a local drive, if one is set up. That way you can continue to get new files externally,
	# while also evaluating a huge pile of local files, without getting inundated by the local files
	my $new_local_files_to_procure_each_startup = $self->{config}->{new_local_files_to_procure_each_startup};
	if ($new_local_files_to_procure_each_startup) {
		$new_local_files_to_procure_each_startup =~ /^[0-9]+$/ or confess "Invalid new_local_files_to_procure_each_startup '$new_local_files_to_procure_each_startup'";
		my $new_local_file_source_directory = $secretary->new_local_file_source_directory();
		if (-d $new_local_file_source_directory) {
			my $source_name = App::MediaDiscovery::Directory->existing( $new_local_file_source_directory )->dirname();
			my $file_extension = uc $self->{config}->{file_extension};
			if ($new_local_file_source_directory) {
				-d $new_local_file_source_directory or confess "Can't find content directory new_local_file_source_directory '$new_local_file_source_directory'";
				my $find_command = "find -L $new_local_file_source_directory -type f -iname '*.$file_extension'";
				#print "$find_command\n";
				my $files_string = `$find_command`;
				my @filenames = split( "\n", $files_string );

				#allow plugin modules to do specific things for specific file types, or fall back to App::MediaDiscovery::File
				$file_extension =~ /^[a-z0-9]+$/i or confess "Invalid file type '$file_extension'";
				my $module = "App::MediaDiscovery::File::$file_extension";
				eval "require $module;";
				if ($@) {
					cluck $@;
					$module = 'App::MediaDiscovery::File';
				}

				my @files = map {
					my $file;
					# sometimes another process deletes files before we get here so double check
					if ( -f $_ ) {
						$file = $module->existing( file_location => $_, );
					}
					$file;
				} @filenames;

				@files = shuffle grep { $_ } @files; # remove ones not found
				my $new_acquisitions_directory = $secretary->new_acquisitions_directory();
				-d $new_acquisitions_directory or confess "Not a directory: '$new_acquisitions_directory'";
				my $new_local_acquisitions_directory = File::Spec->catfile( $new_acquisitions_directory, $source_name );
				if (!-d $new_local_acquisitions_directory) {
					system('mkdir', '-p', $new_local_acquisitions_directory) and die "Could not create directory '$new_local_acquisitions_directory'";
				}
				for (1 .. $new_local_files_to_procure_each_startup) {
					my $file_to_move = shift @files;
					$self->output( 'Moving ' . $file_to_move->path_and_name() . " to '$new_local_acquisitions_directory'" );
					$file_to_move->move_to_directory( $new_local_acquisitions_directory );
				}
			} else {
				cluck 'If new_local_files_to_procure_each_startup is configured, new_local_file_source_directory must also be configured';
			}
		}
	}

	# This section will "recycle" older existing collection files into the new acquisitions section for re-evaluation.
	# If you use this feature, and you delete these files from new acquisitions, they will be gone forever, so be careful.
	# It's mostly copied from the code above. It's broken into two separate stanzas of code to allow the code to diverge over time,
	# since I'm not quite sure how I'll use it and tweak it, and I'm not sure what the stanzas will have in common and not have in
	# common until I mess with them a while. Or maybe I'm just too lazy to abstract it right now.
	my $local_collection_files_to_recycle_each_startup = $self->{config}->{local_collection_files_to_recycle_each_startup};
	if ($local_collection_files_to_recycle_each_startup) {
		$local_collection_files_to_recycle_each_startup =~ /^[0-9]+$/ or confess "Invalid local_collection_files_to_recycle_each_startup '$local_collection_files_to_recycle_each_startup'";
		my $new_local_file_source_directory = $secretary->curated_directory();
		if (-d $new_local_file_source_directory) {
			my $source_name = App::MediaDiscovery::Directory->existing( $new_local_file_source_directory )->dirname();
			my $file_extension = uc $self->{config}->{file_extension};
			if ($new_local_file_source_directory) {
				-d $new_local_file_source_directory or confess "Can't find content directory new_local_file_source_directory '$new_local_file_source_directory'";
				my $find_command = "find -L $new_local_file_source_directory -type f -iname '*.$file_extension' ";
				#print "$find_command\n";
				my $files_string = `$find_command`;
				my @filenames = split( "\n", $files_string );

				#allow plugin modules to do specific things for specific file types, or fall back to App::MediaDiscovery::File
				$file_extension =~ /^[a-z0-9]+$/i or confess "Invalid file type '$file_extension'";
				my $module = "App::MediaDiscovery::File::$file_extension";
				eval "require $module;";
				if ($@) {
					cluck $@;
					$module = 'App::MediaDiscovery::File';
				}

				my @files = map {
					my $file;
					# sometimes another process deletes files before we get here so double check
					if ( -f $_ ) {
						$file = $module->existing( file_location => $_, );
					}
					$file;
				} @filenames;

				@files = sort { ( $a->atime() <=> $b->atime() ) } grep { $_ } @files; # remove ones not found, and sort oldest first
				my $new_acquisitions_directory = $secretary->new_acquisitions_directory();
				-d $new_acquisitions_directory or confess "Not a directory: '$new_acquisitions_directory'";
				my $new_local_acquisitions_directory = File::Spec->catfile( $new_acquisitions_directory, $source_name );
				if (!-d $new_local_acquisitions_directory) {
					system('mkdir', '-p', $new_local_acquisitions_directory) and die "Could not create directory '$new_local_acquisitions_directory'";
				}
				for (1 .. $local_collection_files_to_recycle_each_startup) {
					my $file_to_move = shift @files;
					$self->output( 'Moving ' . $file_to_move->path_and_name() . " to '$new_local_acquisitions_directory'" );
					$file_to_move->move_to_directory( $new_local_acquisitions_directory );
				}
			} else {
				cluck 'If local_collection_files_to_recycle_each_startup is configured, new_local_file_source_directory must also be configured';
			}
		}
	}

	#this nonsense just means that if this code is already running in another instance, quit
	use Fcntl 'LOCK_EX', 'LOCK_NB';
	if ( flock DATA, LOCK_EX | LOCK_NB ) {
		$self->output("No procurer running; beginning.");
	} else {
		$self->output("Procurer already running; exiting.");
		exit;
	}

	my $times_to_run         = $self->{config}->{times_to_run}         or confess "Times to run not configured";
	my $minutes_between_runs = $self->{config}->{minutes_between_runs} or confess "Minutes between runs not configured";

	# no, you cannot harass our feed providers too often
	my $min_minutes = 15;
	if ( !$minutes_between_runs || ( $minutes_between_runs < $min_minutes ) || ( $minutes_between_runs < 0 ) || ( $minutes_between_runs !~ /^\d+$/ ) ) {
		$minutes_between_runs = $min_minutes;
	}

	# keep track of what sources we've visited lately
	my %urls_gotten;

	# run repeatedly for a few days to avoid making users have to set up a cron job
	PROCURER_RUN: for my $counter ( 1 .. $times_to_run ) {
		$self->output("Beginning run '$counter' of '$times_to_run'.");

		# keep track of what day it is, so we don't visit the same url more than once a day
		my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime;

		my $scorekeeper = App::MediaDiscovery::File::Curator::Scorekeeper->new( verbose => $self->{verbose} );
		my $getter      = App::MediaDiscovery::HTTP::GetAll->new( download_checker => $scorekeeper, verbose => $self->{verbose}, );

		# remove empty source directories where we put new songs, to reduce clutter
		$secretary->remove_empty_acquisition_directories();

		# where should we put stuff? the secretary keeps track of that.
		my $new_acquisitions_directory = $secretary->new_acquisitions_directory();
		-d $new_acquisitions_directory or confess "Not a directory: '$new_acquisitions_directory'";

		my $count = `find $new_acquisitions_directory -type f | wc -l`;
		$count =~ s/\s//g;
		$self->output("$count files already in new acquisitions.");
		if ($count > $self->{config}->{files_to_have_before_respecting_blackout_window}) {
			$self->output("This is greater than the number of files needed '$self->{config}->{files_to_have_before_respecting_blackout_window}' to respect the blackout window.");
			if ($hour >= $self->{config}->{blackout_window_start} && $hour < $self->{config}->{blackout_window_end}) {
				$self->output("Blackout window '$self->{config}->{blackout_window_start}'-'$self->{config}->{blackout_window_end}' is being respected because hour is '$hour'. Sleeping '$minutes_between_runs' minutes.");
				sleep $minutes_between_runs * 60;
				next PROCURER_RUN;
			} else {
				$self->output("Blackout window '$self->{config}->{blackout_window_start}'-'$self->{config}->{blackout_window_end}' is not in effect because hour is '$hour'; proceeding.");
			}
		}

		# which plugin should we use to discover new content?
		my $feed_plugin = $self->{config}->{feed_plugin} or confess "No feed plugin configured";
		$feed_plugin =~ /^App::MediaDiscovery::File::Curator::Procurer::FeedParser::(\w+)$/ or confess "Invalid feed plugin '$feed_plugin'";
		$self->output("Using $1 plugin.");
		eval "require $feed_plugin;";
		if ($@) {
			confess $@;
		}
		$self->{feed} ||= $feed_plugin->new( verbose => $self->{verbose}, );
		my $file_type = $self->{feed}->file_type() or confess "Feed does not specify file_type to download";

		# get list of all sites that might have content
		my $source_list = $self->{feed}->get_source_list();

		if ( !scalar @$source_list ) {
			die "Could not get site list from '$feed_plugin'";
		}

		my @all_new_files;

		SOURCE: for my $source (@$source_list) {

			$source =~ m|https?://([\w.\-]+)| or confess "Invalid source '$source'";
			my $source_name = $1;
			$source_name =~ /^[\w.\-]+$/ or confess "Invalid site/directory name: '$source_name'";

			# get information about new works that have been posted on the internet.
			if (
				my $why = $scorekeeper->should_we_acquire_all_works_from_source(
					source_name                => $source_name,
					new_acquisitions_directory => $new_acquisitions_directory,
				)
			) {
				$self->output( "The scorekeeper says we should acquire all works from source '$source'." );

				if ( $urls_gotten{$source} ) {
					$self->output("Already visited source '$source' recently.");
				} else {
					my $maximum_number_of_files_to_get = $self->{config}->{maximum_number_of_files_to_get_per_source_per_run} or confess 'maximum_number_of_files_to_get not set';

					if ( $why->{never_downloaded_anything_from_source} ) {
						$maximum_number_of_files_to_get = $self->{config}->{maximum_number_of_files_to_get_from_a_new_source} || 0;
						$self->output("We have never visited source '$source', so we'll give it a try, getting at most '$maximum_number_of_files_to_get' files.");
					} else {
						$self->output("We have not visited source '$source' recently.");
					}

					my $out_dir = File::Spec->catfile( $new_acquisitions_directory, $source_name );
					$self->output("Getting all ${file_type}s from '$source' if they pass checks.");

					# note that the scorekeeper may keep the getter from downloading everything it sees,
					# and the scorekeeper may prevent the getter from keeping everything it downloads.
					my @gotten_files = $getter->get_all(
						source_name                    => $source_name,
						page                           => $source,
						directory                      => $out_dir,
						file_type                      => $file_type,
						why                            => $why,
						maximum_number_of_files_to_get => $maximum_number_of_files_to_get,
					);

					if (@gotten_files) {
						$self->output("Got files:");
						$self->output( join( "\n", @gotten_files ) );
						my $gotten_count = scalar @gotten_files;
					} else {
						$self->output("No files retrieved, blacklisting.");
						$scorekeeper->blacklist_source( source_name => $source_name );
					}

					@all_new_files = ( @all_new_files, @gotten_files );
					$urls_gotten{$source} = 1;
				}
			} else {
				$self->output( "The scorekeeper says we should NOT acquire all works from source '$source'." );
			}
		}

		if (@all_new_files) {
			my $message = join( "\n", @all_new_files );
			$self->output("We have kept:\n$message");
		}

		$self->output("Sleeping '$minutes_between_runs' minutes.");
		sleep $minutes_between_runs * 60;
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

### DO NOT REMOVE THE FOLLOWING LINES ###
__DATA__
This exists to allow the locking code to work.
DO NOT REMOVE THESE LINES!
