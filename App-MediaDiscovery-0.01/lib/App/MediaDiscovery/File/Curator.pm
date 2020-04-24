use strict;
$| = 1;

# This is the interactive module that lets a user review acquisitions and decide what to do with them.

package App::MediaDiscovery::File::Curator;

use Carp;
use Config::General;
use Data::Dumper;
use File::Path qw(make_path);
use IO::Prompter;
use Term::ReadKey;    # used by IO::Prompter to only echo good input
use Term::ANSIColor;
use File::Spec;

use App::MediaDiscovery::File;
use App::MediaDiscovery::Directory;
use App::MediaDiscovery::File::Curator::Procurer;
use App::MediaDiscovery::File::Curator::Secretary;
use App::MediaDiscovery::File::Curator::Scorekeeper;

sub new {
	my $class = shift;
	my %args  = @_;
	my $self  = bless( \%args, $class );

	$self->{secretary} = App::MediaDiscovery::File::Curator::Secretary->new();

	my $param_config = $args{config};
	$param_config ||= {};

	my %file_config;
	my $config_file = File::Spec->catfile( $ENV{HOME}, 'zombio', 'config', split( /::/, __PACKAGE__ ) ) . '.conf';

	if ( -f $config_file ) {
		my $conf = Config::General->new($config_file);
		%file_config = $conf->getall();
		$self->{config} = \%file_config;
	}

	#confess Dumper $param_config;
	for my $param_config_key ( keys %$param_config ) {
		$self->{config}->{$param_config_key} = $param_config->{$param_config_key};
	}

	#confess Dumper $self->{config};

	# if directory to evaluate is not defined, just use the one where we put new stuff
	if ( !$self->{config}->{content_directory} ) {
		$self->{config}->{content_directory} = App::MediaDiscovery::File::Curator::Secretary->new()->new_acquisitions_directory();
	}

	my %required_configs = (
		type                           => 'mp3',
		evaluation_command             => 'killall afplay >/dev/null 2>&1; afplay -v 1 $file >/dev/null &',
		pause_command                  => 'killall afplay >/dev/null 2>&1',
		edit_command                   => '',
		default_action                 => 'r',
		procurer_script                => 'zombio_get',
		use_letter_subdirectories      => 1,
		extra_seconds                  => 0,
		search_metadata                => 0,
		acquire_new_files              => 1,
		procurer_verbose               => 0,
		color_1                        => 'blue',
		color_2                        => 'red',
		color_3                        => 'cyan',
	);
	for my $required_config ( keys %required_configs ) {
		if ( !defined $self->{config}->{$required_config} ) {
			$self->{config}->{$required_config} = $required_configs{$required_config};
		}
	}

	if ( !$self->{config}->{skip_scorekeeper} ) {
		$self->{scorekeeper} = App::MediaDiscovery::File::Curator::Scorekeeper->new( verbose => $self->{verbose} );
	}

	my $content_directory = $self->{config}->{content_directory} or die "'content_directory' not configured in $config_file";
	if ( !-d $content_directory ) {
		eval {
			make_path $content_directory or die "Couldn't make directory '$content_directory'";
		};
		if ($@) {
			die "Could not find and could not make directory '$content_directory': $@";
		}
	}

	return $self;
}

sub acquire_new_files {
	my $self = shift;
	my %args = @_;

	my $configured_procurer = $self->{config}->{procurer_script};
	if ( !$configured_procurer ) {
		warn "No procurer script configured; cannot acquire files. Config is: " . Dumper( $self->{config} );
		return;
	}
	my $script_location = `which $configured_procurer`;
	chomp $script_location;
	if ( !$script_location || !-f $script_location || !-x $script_location ) {
		warn "Command '$configured_procurer' is not found, does not exist, or is not executable; cannot acquire files";
		return;
	}

	$self->{config}->{procurer_verbose} =~ /^\d$/ or confess "Invalid \$self->{config}->{procurer_verbose}: '$self->{config}->{procurer_verbose}'";
	system("nohup $configured_procurer $self->{config}->{procurer_verbose} >/tmp/procurer.out &");

	print "Finding files";
	$self->{sleep_time} ||= 1;
	for ( 1 .. $self->{sleep_time} ) {
		sleep 1;
		print ".";
	}
	print "\n";
	$self->{sleep_time} *= 2;

	my $result = `ps aux | grep zom[b]io_get`;
	print "$result\n";

	return $result;
}

sub command_line_loop {
	my $self = shift;
	my %args = @_;

	if ( $self->{config}->{acquire_new_files} ) {
		if ($self->acquire_new_files()) {
			# All good
		} else {
            #confess "Could not acquire new files by running '$self->{config}->{procurer_script}'";
		}
	}
	$self->{secretary}->empty_trash( file_type => $self->{config}->{type} );

	while (1) {
		$self->load_files();

		my $found_count = scalar @{ $self->{files} };

		my $index = 0;
		while ($index < scalar @{ $self->{files} }) {
			my $file_object = $self->{files}->[$index];
			$self->{sleep_time} = 1;

			$file_object->history_index($index);
			my $file_action = $self->do_one_file(
				found_count => $found_count,
				file_object => $file_object,
			);

			$self->do_sort();

			if ($file_action eq 'back' || $file_action eq 'b') {
				if ($index > 0) {
					$index--;
				}
			} else {
				$index++;
			}
		}

		if ( $self->{config}->{player_only} ) {
			print "You chose to evaluate files without procuring new ones, and we have evaluated all files. Exiting.\n";
			exit(0);
		}
		if ( $self->{config}->{search_terms} && @{ $self->{config}->{search_terms} } ) {
			print "You chose some search terms ('@{$self->{config}->{search_terms}}'), and there are no more files that match those terms. Exiting.\n";
			exit(0);
		}
		if ( $self->{config}->{max_count} ) {
			print "You chose to evaluate $self->{config}->{max_count} files, and we did, so we'll exit now.\n";
			exit(0);
		}
		if ( $self->{config}->{acquire_new_files} ) {
			if ($self->acquire_new_files()) {
				# All good
			} else {
                #confess "Could not acquire new files by running '$self->{config}->{procurer_script}'";
			}
		} else {
			print "You have chosen not to procure new files, and we have evaluated all files. Exiting.\n";
			exit(0);
		}
	}

	return;
}

sub do_sort {
	my $self = shift;
	my %args = @_;

	my $sort = $self->{config}->{sort};
	$sort ||= 'most_liked';

	#print "Sorting files with sort '$sort'\n";
	$sort = "sort_$sort";
	$self->$sort( genre => $self->{config}->{genre} );

	#print "Done sorting files\n";

	return;
}

sub do_one_file {
	my $self = shift;
	my %args = @_;

	my $file_object = $args{file_object} or confess 'No file object provided';
	my $found_count = $args{found_count} || '';

	# if someone besides us has removed it since we checked, who cares, skip it
	if ( !-f ( $file_object->path_and_name() ) ) {
		print $file_object->path_and_name() . " has vanished; skipping.\n";
		return;
	}

	$self->{curation_progress} = undef;
	$self->{curation_progress}->{current_file_object} = $file_object;
	my $file_action = $self->evaluate( found_count => $found_count );

	return $file_action;
}

sub evaluate {
	my $self = shift;
	my %args = @_;

	#print "Beginning evaluation\n";

	my $found_count = $args{found_count};    # just to show to user if they care

	my $scorekeeper = $self->{scorekeeper};

	my $file_object    = $self->{curation_progress}->{current_file_object} or confess 'Current file object not set';
	my $basic_message  = $file_object->evaluation_message();
	my $artist_name    = $file_object->clean_artist();
	my $source_name    = $file_object->source();
	my $path_and_name  = $file_object->path_and_name();
	my $artist_score   = 0;
	my $source_score   = 0;
	my $why_downloaded = {};

	if ( $self->{scorekeeper} ) {
		if ($artist_name) {
			$artist_score = $scorekeeper->artist_rating( artist_name => $artist_name )->{rating};
		}
		if ($source_name) {
			$source_score = $scorekeeper->source_rating( source_name => $source_name );
		}
		$why_downloaded = $scorekeeper->why_was_it_downloaded( acquisition_destination => $path_and_name );
	}

	my $details_message = $file_object->evaluation_message_details();

	my $why_downloaded_string = '';
	my $why_artist_name       = $why_downloaded->{artist_name} || '';
	my $why_source_name       = $why_downloaded->{source_name} || '';
	my $downloaded_time       = $why_downloaded->{download_time} || '';

	# we don't always have a why source (a source with a score good enough to download from)
	# but if we do, it should always be the same as the source of the file we downloaded
	if ($why_source_name) {
		$why_source_name eq $source_name or print "Unmatched file source '$source_name' and why source '$why_source_name'";
	}

	my $why_downloaded_string = '';

	if ($downloaded_time) {
		$why_downloaded_string .= "Downloaded $downloaded_time";
	}

	if ( $why_artist_name || $why_source_name ) {
		$why_downloaded_string ||= 'Downloaded';

		$why_downloaded_string .= ' based on ratings of ';
		if ($why_source_name) {
			$why_downloaded_string .= "this source";

			#my $score = $scorekeeper->source_rating( source_name => $why_source_name );
			#$why_downloaded_string .= "($score)";
		}
		if ( $why_artist_name && $why_source_name ) {
			$why_downloaded_string .= ' and ';
		}
		if ($why_artist_name) {
			if ( $artist_name eq $why_artist_name ) {
				$why_downloaded_string .= "this artist";
			} else {
				$why_downloaded_string .= "artist '$why_downloaded->{artist_name}'";
			}

			#my $score = $scorekeeper->artist_rating( artist_name => $why_artist_name )->{rating};
			#$why_downloaded_string .= "($score)";
		}
	}

	if ($why_downloaded_string) {
		$why_downloaded_string = "\n$why_downloaded_string";
	}

	my $evaluation_command;

	$self->execute_evaluation_command();

	my $seconds             = $file_object->seconds();
	my $seconds_til_timeout = $seconds + $self->extra_seconds();
	my $timeout_message     = "Evaluation timeout";
	local $SIG{ALRM} = sub {

		# only "die" (skip to next work) if we haven't decided to start curation without having time to finish.
		# if we've started curation, but haven't had time to finish, let's just do nothing and let the user
		# complete the curation process when ready.
		if ( !$self->{curation_progress}->{curation_in_progress} ) {
			die $timeout_message;
		}

		return;
	};

	my $color_1 = $self->{config}->{color_1};
	my $color_2 = $self->{config}->{color_2};
	my $color_3 = $self->{config}->{color_3};

	eval {
		#if we have a timeout set, set an alarm signal to tell
		#us that the user has failed to select an action, and
		#we can proceed to the next file
		if ( $seconds && !$args{no_timeout} ) {
			alarm $seconds_til_timeout;
		}

		while ( !$self->{curation_progress}->{evaluation_complete} ) {

			#print "Evaluation not complete\n";

			# score might be updated during evaluation, so check it every time
			my $artist_score = 0;
			my $source_score = 0;
			if ($scorekeeper) {
				if ($artist_name) {
					$artist_score = $scorekeeper->artist_rating( artist_name => $artist_name )->{rating};
				}
				if ($source_name) {
					$source_score = $scorekeeper->source_rating( source_name => $source_name );
				}
			}

			# if source is a directory that looks like a website, indicating where the work came from,
			# we can show that source's score
			if ( $source_name =~ /\./ ) {
				$source_score = "   $source_score";
				$artist_score = "   $artist_score";
			}

			# else the source is a genre directory, so it should have no score
			else {
				$source_score = '';
				$artist_score = '';
			}

			my $count = `$self->{find_command} | wc -l`;
			chomp $count;
			$count =~ s/\s+//g;
			my $left_to_do_now = $self->files_left() + 1;
			my $liked          = '';
			if ( $self->{scorekeeper} ) {
				$liked = $self->{scorekeeper}->like_percentage();
			}

			my $artist_title_spaces           = '';
			my $source_spaces                 = '';
			my $artist_title_message          = "$basic_message$artist_title_spaces$artist_score";
			my $source_message                = "$source_name$source_spaces$source_score";
			my $artist_title_length_no_spaces = length($artist_title_message);
			my $source_length_no_spaces       = length($source_message);
			if ( $artist_title_length_no_spaces < $source_length_no_spaces ) {
				$artist_title_spaces = ' ' x ( $source_length_no_spaces - $artist_title_length_no_spaces );
			} elsif ( $source_length_no_spaces < $artist_title_length_no_spaces ) {
				$source_spaces = ' ' x ( $artist_title_length_no_spaces - $source_length_no_spaces );
			}
			$artist_title_message = "$basic_message$artist_title_spaces";
			$source_message       = "$source_name$source_spaces";

			print color($color_3) . " 
Scoring and saving:" . color($color_2) . "
    I love    this one and want to " . color($color_1) . "[" . color($color_3) . "c" . color($color_1) . "]" . color($color_2) . "urate it;        continue playing
    I lo" . color($color_1) . "[" . color($color_3) . "v" . color($color_1) . "]" . color($color_2) . "e  this one but want to remove   it;        continue playing
    I " . color($color_1) . "[" . color($color_3) . "l" . color($color_1) . "]" . color($color_2) . "ike  this one but want to remove   it;        continue playing
    I dislike this one and want to r" . color($color_1) . "[" . color($color_3) . "e" . color($color_1) . "]" . color($color_2) . "move it;        continue playing
    I dislike this one and want to " . color($color_1) . "[" . color($color_3) . "r" . color($color_1) . "]" . color($color_2) . "emove it; do not continue playing
    I " . color($color_1) . "[" . color($color_3) . "h" . color($color_1) . "]" . color($color_2) . "ate  this one and want to remove   it; do not continue playing
" . color($color_3) . "
Fixing mistakes:" . color($color_2) . "
   " . color($color_1) . "[" . color($color_3) . "f" . color($color_1) . "]" . color($color_2) . "ix filename, artist, title, or genre
" . color($color_3) . "
Playback controls:" . color($color_2) . "
   " . color($color_1) . "[" . color($color_3) . "p" . color($color_1) . "]" . color($color_2) . "lay
    Pa" . color($color_1) . "[" . color($color_3) . "u" . color($color_1) . "]" . color($color_2) . "se
   " . color($color_1) . "[" . color($color_3) . "s" . color($color_1) . "]" . color($color_2) . "kip
   " . color($color_1) . "[" . color($color_3) . "b" . color($color_1) . "]" . color($color_2) . "ack
" . color($color_1) . " 
$count files available for evaluation
$liked
$details_message$why_downloaded_string" . color('reset') . "

$artist_title_message" . color($color_1) . $artist_score . color('reset') . "
$source_message" . color($color_1) . $source_score . color('reset') . "

" . color($color_2);

			my $status = $self->status();
			if ($status) {
				print color($color_1) . $status . color('reset') . "\n";
			}

			#print $file_object->as_string()."\n";

			$evaluation_command = '';    #reset it if we're not done evaluating. we only need to save it if we're done.
			my @evaluation_parameters;
			while ( !$self->can($evaluation_command) ) {

				# various curation actions might change the current default action. otherwise, use our configured default action.
				my $default_action = ( $self->{curation_progress}->{default_action} || $self->{config}->{default_action} );
				$default_action or die 'No default action set';

				@ARGV = ();              # IO::Prompter hates it when there's stuff in @ARGV
				print( color($color_2) . "Do nothing, enter command, or press enter for default " . color($color_1) . "[" . color($color_3) . $default_action . color($color_1) . "]" . color('reset') );
				$evaluation_command = prompt( ": ", -default => $default_action, -guarantee => qr/^[A-Za-z0-9]*$/ );

				if ( $evaluation_command eq '' ) {
					$evaluation_command = $default_action;
				}
				# check our playlists dir. perhaps the user wants to copy this file to one.
				elsif ( ( !$self->can($evaluation_command) ) && defined $evaluation_command ) {
					# Entering a number lets you order a playlist by renaming its files
					if ($evaluation_command =~ /^([0-9]+)$/) {
						@evaluation_parameters = ($1);
						$evaluation_command = 'reorder_in_playlist';
					} else {
						my $lists_dir         = $self->{secretary}->lists_directory();
						my $dir               = App::MediaDiscovery::Directory->existing($lists_dir);
						my $subdirs           = $dir->subdirs();
						my $possible_list_dir = File::Spec->catfile( $lists_dir, $evaluation_command );
						if ( !-d ($possible_list_dir) && $evaluation_command =~ /^\w+$/ ) {
							@ARGV = ();    # IO::Prompter hates it when there's stuff in @ARGV
							print "Create playlist '$evaluation_command'? " . color($color_1) . "[" . color($color_3) . "n" . color($color_1) . "]" . color('reset');
							my $create_list = prompt ": ", -default => 'n', -guarantee => qr/^[YNyn]*$/, -yesno;
							if ( $create_list =~ /^y$/i ) {
								mkdir $possible_list_dir or confess "$possible_list_dir: $!";
							}
						}
						if ( -d ($possible_list_dir) ) {
							@evaluation_parameters = ($evaluation_command);
							$evaluation_command    = 'add_to_list';
						}
					}
				}
			}

			my $result = $self->$evaluation_command( @evaluation_parameters );
			if ($result) {
				print color($color_1) . $result . color('reset');
			}
		}
	};
	if ($@) {

		# if we've timed out...
		if ( $@ =~ /$timeout_message/ ) {
			print "\n";

			# if the user has started curation...
			if ( $self->{curation_progress}->{default_action} eq 'c' ) {

				# finish curation for the user
				while ( !$self->{curation_progress}->{evaluation_complete} ) {

					#print "Finishing curation\n";
					my $result = $self->curate();
					if ($result) {
						print color($color_1) . $result . color('reset');
					}

					#print "Performed another curation step\n";
				}
			}

			# else the user has not decided what to do with the file, so skip
			else {
				return $self->skip();
			}
			return;
		} else {
			confess $@;
		}
	}

	return $evaluation_command;
}

sub ask_about_tastes {
	my $self = shift;
	my %args = @_;

	my $directory;
	print "We need to know which artists you like. Type the full path to a directory that contains $self->{config}->{type}s you like--the more, the better. We won't move or change anything. We'll just use the information in these files to determine what to download for you initially. Or, press enter to skip this step.\n";
	@ARGV      = ();           # IO::Prompter hates it when there's stuff in @ARGV
	$directory = prompt ':';

	if ( !$directory || $directory eq '' ) {
		return;
	}

TRY: while ( $directory && $directory ne '' ) {

		#print "Directory chosen is '$directory'\n";
		if ( !-d $directory || !-r $directory ) {
			print "Can't open directory '$directory'. Please try again, or press enter to quit.\n";
			$directory = prompt ':';
			next TRY;
		}

		$self->seed_preferences_from_directory_contents( directory => $directory );

		print "Got preferences from directory '$directory'. Type the location of a another directory, or press enter to quit.\n";
		$directory = prompt ':';
	}

	return;
}

sub seed_preferences_from_directory_contents {
	my $self = shift;
	my %args = @_;

	my $directory = $args{directory} or die 'Must provide directory';
	-d $directory or die "'$directory' is not a directory";

	my $class = $self->get_class_name();

	#print "Examining directory $directory.\n";
	my $files_string = `find -L $directory -type f -iname '*.$self->{config}->{type}' | sort`;    # sort makes output prettier for user
	my %artists;
	for my $filename ( split( /\n/, $files_string ) ) {
		print "$filename.\n";
		my $file = $class->existing( file_location => $filename );
		if ( $file->can('load_tags') ) {
			$file->load_tags();
		} else {
			print "Could not load tags.\n";
		}
		my $artist = $file->clean_artist();
		my $title  = $file->clean_title();
		if ($artist) {
			push( @{ $artists{$artist} }, $title );
		} else {
			print "Could not determine artist.\n";
		}
	}

	#use Data::Dumper; $Data::Dumper::Sortkeys = 1; warn Dumper \%artists;
	$self->{scorekeeper}->add_artists_works_and_ratings( artists => \%artists, );

	return;
}

sub find_some_files_to_play {
	my $self = shift;
	my %args = @_;

	my $counter = $args{counter};
	my $number_of_files_wanted = $args{number_of_files_wanted} || 1;

	$self->load_files();
	my $found_count = scalar @{ $self->{files} };
	my @file_objects;
	my $download;

	# for online radio station
	if ( defined $counter ) {
		@file_objects = @{ $self->{files} }[ $counter .. $counter + $number_of_files_wanted - 1 ];
	}

	# for command line curator
	else {
		my $file_object;
		do {
			$file_object = shift @{ $self->{files} };
		} while ( $file_object && $self->{scorekeeper}->skipped_or_curated( file => $file_object ) );

		@file_objects = ($file_object);    # just give one at a time to curator
	}

	return @file_objects;
}

sub load_files {
	my $self = shift;
	my %args = @_;

	my $directory = $self->{config}->{content_directory};
	-d $directory or confess "Can't find content directory directory '$directory'";
	$self->{find_command} = "find -L $directory -type f -iname '*.$self->{config}->{type}'";
	my $find_all_files_command = "find -L $directory -type f";

	#print "$self->{find_command}\n";
	my $files_string = `$self->{find_command}`;

	my @filenames = split( "\n", $files_string );

	#allow plugin modules to do specific things for specific file types, or fall back to App::MediaDiscovery::File
	my $type = uc $self->{config}->{type} or confess 'No file type to evaluate is configured';
	$type =~ /^[a-z0-9]+$/i or confess "Invalid file type '$type'";
	my $module = $self->{module} = "App::MediaDiscovery::File::$type";
	eval "require $module;";
	if ($@) {
		print $@;
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
	@files = grep { $_ } @files;    # remove ones not found

	$self->{files} = \@files;

	$self->do_sort();

	#if searching for a particular directory/filename/song/artist/genre, remove others
	if ( $self->{config}->{search_terms} ) {
		ref $self->{config}->{search_terms} eq 'ARRAY' or confess "Search terms invalid: " . Dumper( $self->{config}->{search_terms} );
		if ( scalar( @{ $self->{config}->{search_terms} } ) ) {

			#die "search terms are " . Dumper $self->{config}->{search_terms};
			my @matching_files;
			for my $file ( @{ $self->{files} } ) {

				#if we match this term in any attribute of the file
				if (
					$file->matches_search_terms(
						search_terms   => $self->{config}->{search_terms},
						check_metadata => $self->{config}->{search_metadata}
					)
					)
				{
					print $file->filename() . "\n";
					push( @matching_files, $file );
				} else {

					#print "Skipping ".$file->filename()."\n";
				}
			}
			$self->{files} = \@matching_files;
		}
	}

	if ( my $max = $self->{config}->{max_count} ) {
		$max =~ /^\d+$/ or confess "Invalid max count '$max'";
		my $files = $self->{files};
		while ( scalar @$files > $max ) {
			pop @$files;
		}
	}

	return;
}

sub search_terms {
	my $self = shift;
	if (@_) {
		$self->{config}->{search_terms} = \@_;
	}
	return $self->{config}->{search_terms};
}

sub clear_search_terms {
	my $self = shift;
	$self->{config}->{search_terms} = undef;
	return;
}

sub files {
	my $self = shift;
	return $self->{files};
}

sub files_left {
	my $self = shift;
	return scalar( @{ $self->{files} } );
}

sub sort_filename {
	my $self = shift;
	@{ $self->{files} } = sort { $a->filename() cmp $b->filename() } @{ $self->{files} };
	return;
}

sub sort_smallest_to_largest {
	my $self = shift;
	@{ $self->{files} } = sort { $a->size() <=> $b->size() } @{ $self->{files} };
	return;
}

sub sort_largest_to_smallest {
	my $self = shift;
	@{ $self->{files} } = sort { $b->size() <=> $a->size() } @{ $self->{files} };
	return;
}

sub sort_newest_to_oldest {
	my $self = shift;
	@{ $self->{files} } = sort {
		( $b->ctime() <=> $a->ctime() )
	} @{ $self->{files} };
	return;
}

sub sort_oldest_to_newest {
	my $self = shift;
	@{ $self->{files} } = sort {
		( $a->ctime() <=> $b->ctime() )
	} @{ $self->{files} };
	return;
}

sub sort_random {
	my $self = shift;

	my @tempList = ();
	while ( @{ $self->{files} } ) {
		push( @tempList, splice( @{ $self->{files} }, rand( @{ $self->{files} } ), 1 ) );
	}
	@{ $self->{files} } = @tempList;

	# Don't change the past, but do change the future
	@{ $self->{files} } = sort {
		my $cmp;

		if ( defined $a->history_index() && defined $b->history_index() ) {
			$cmp = $a->history_index() <=> $b->history_index();
		} elsif ( defined $a->history_index() && !defined $b->history_index() ) {
			$cmp = -1;
		} elsif ( !defined $a->history_index() && defined $b->history_index() ) {
			$cmp = 1;
		}

		$cmp;
	} @{ $self->{files} };

	return;
}

sub sort_most_liked {
	my $self = shift;
	my %args = @_;

	# this sort takes genre into account, so maybe "most_liked" is not the best name.
	# it's now "genre if specified, otherwise most liked"
	my $genre = $args{genre};

	my $genre_scores_for_artist;
	my $genre_scores_for_source;
	my %source_ratings_cache;

	if ( my $scorekeeper = $self->{scorekeeper} ) {
		if ($genre) {
			$genre_scores_for_artist = $scorekeeper->genre_scores_for_artists( genre_name => $genre );
			$genre_scores_for_source = $scorekeeper->genre_scores_for_sources( genre_name => $genre );
		}

		@{ $self->{files} } = sort {
			my $cmp;    # cmp value to "return" at end of this block

			# Don't change the past, but do change the future
			if ( defined $a->history_index() && defined $b->history_index() ) {
				$cmp = $a->history_index() <=> $b->history_index();
			} elsif ( defined $a->history_index() && !defined $b->history_index() ) {
				$cmp = -1;
			} elsif ( !defined $a->history_index() && defined $b->history_index() ) {
				$cmp = 1;
			}

			if (!$cmp) {

				my $a_source = $a->source();
				my $b_source = $b->source();

				# move friend submissions (source is an email address instead of website) to the front.
				# i have a webpage that allows people to upload acquisitions and it puts them into
				# folders named after the person's email
				if ( ( $a_source =~ /\@/ ) && ( $b_source =~ /\@/ ) ) {
					$cmp = 0;
				} elsif ( $a_source =~ /\@/ ) {
					$cmp = -1;
				} elsif ( $b_source =~ /\@/ ) {
					$cmp = 1;
				}

				# move other sources (manual folder creations probably) to the front. for instance,
				# artist seabright sent me some of his work and i put it into a "seabright" folder
				# and i wanted that to play first
				if ( ( $a_source !~ /\./ ) && ( $b_source !~ /\./ ) ) {
					$cmp = 0;
				} elsif ( $a_source !~ /\./ ) {
					$cmp = -1;
				} elsif ( $b_source !~ /\./ ) {
					$cmp = 1;
				}

				# if a genre is requested, use that to sort
				if ( !$cmp && $genre ) {

					# compare source's scores for the chosen genre, if at least one of the
					# sources we're comparing has a good score for this genre. if neither
					# have a good score for this genre, we'll decide below based on artist
					# instead.
					my $good_enough_score_to_count_in_genre = $scorekeeper->good_enough_score_to_count_in_genre();
					if (   ( $genre_scores_for_source->{$a_source} > $good_enough_score_to_count_in_genre )
						|| ( $genre_scores_for_source->{$b_source} > $good_enough_score_to_count_in_genre ) )
					{
						$cmp = ( $genre_scores_for_source->{$b_source} <=> $genre_scores_for_source->{$a_source} );
					}

					if ( !$cmp ) {

						# it takes a while to load up these tags, so we only use artist name
						# to sort by if we have to.
						my $a_artist = $a->clean_artist();
						my $b_artist = $b->clean_artist();
						$cmp = ( $genre_scores_for_artist->{$b_artist} <=> $genre_scores_for_artist->{$a_artist} );
					}
				}

				if ( !$cmp ) {

					# get source ratings from scorekeeper or cache
					for my $source ( $a_source, $b_source ) {
						if ( !defined( $source_ratings_cache{$source} ) ) {
							$source_ratings_cache{$source} = $scorekeeper->source_rating( source_name => $source );
						}
					}

					# sort by highest source rating
					$cmp = $source_ratings_cache{$b_source} <=> $source_ratings_cache{$a_source};
				}

				$cmp ||= 0;
			}

			$cmp;    # "return" this value to sort
		} @{ $self->{files} };
	} else {

		#print "Scorekeeper must be set in order to sort by most liked\n";
	}

	return;
}

# this is actually useful when you want to clear your collection of crap.
# sort by least liked, then hit delete, delete, delete... also, these
# sort methods don't make a huge difference, because everything was
# downloaded for a reason anyway.
sub sort_least_liked {
	my $self = shift;
	my %args = @_;

	my %source_ratings_cache;

	if ( my $scorekeeper = $self->{scorekeeper} ) {
		@{ $self->{files} } = sort {
			my $cmp;    # cmp value to "return" at end of this block

			# Don't change the past, but do change the future
			if ( defined $a->history_index() && defined $b->history_index() ) {
				$cmp = $a->history_index() <=> $b->history_index();
			} elsif ( defined $a->history_index() && !defined $b->history_index() ) {
				$cmp = -1;
			} elsif ( !defined $a->history_index() && defined $b->history_index() ) {
				$cmp = 1;
			}

			if (!$cmp) {

				my $a_source = $a->source();
				my $b_source = $b->source();

				if ( !$cmp ) {

					# get source ratings from scorekeeper or cache
					for my $source ( $a_source, $b_source ) {
						if ( !defined( $source_ratings_cache{$source} ) ) {
							$source_ratings_cache{$source} = $scorekeeper->source_rating( source_name => $source );
						}
					}

					# sort by LOWEST source rating
					$cmp = $source_ratings_cache{$a_source} <=> $source_ratings_cache{$b_source};
				}

				$cmp ||= $a->history_index() <=> $b->history_index();
				$cmp ||= 0;
			}

			$cmp;    # "return" this value to sort
		} @{ $self->{files} };
	} else {
		print "Scorekeeper must be set in order to sort by least liked\n";
	}

	return;
}

sub execute_evaluation_command {
	my $self = shift;
	my %args = @_;

	my $cmd = ( $args{command} || $self->{config}->{evaluation_command} ) or confess 'No evaluation command';

	my $file_object = $args{file_object} || $self->{curation_progress}->{current_file_object};
	$file_object or confess 'No file object';
	my $file_location           = $file_object->path_and_name();
	my $file_location_for_shell = $file_location;
	$file_location_for_shell =~ s/([ ()\$&'"])/\\$1/g;    #' #escape for shell
	if ( $cmd =~ /^(.+)?\$file(.+)?$/ ) {
		$cmd =~ s/\$file/$file_location_for_shell/g;
	} else {
		confess "Command '$cmd' needs to mention \$file somewhere in it";
	}

	#confess $cmd;
	#print "$cmd\n";
	if ( system $cmd) {
		confess "Could not open file for evaluation with command '$cmd': $!";
	}

	return "Evaluating\n";
}

sub pause {
	my $self = shift;
	my $pause_command = $self->{config}->{pause_command} or return 'No pause command configured';
	system($pause_command);
	alarm 0;
	return "Paused\n";
}

sub extra_seconds {
	my $self = shift;
	return $self->{config}->{extra_seconds};
}

sub add_to_list {
	my $self            = shift;
	my ($list)          = @_;
	my $file_object     = $self->{curation_progress}->{current_file_object} or confess 'No current file object set';
	my $lists_directory = $self->{secretary}->lists_directory() or confess "No lists directory configured";
	my $new_filename    = $self->{curation_progress}->{new_filename};
	$new_filename ||= $file_object->filename();
	-d $lists_directory or confess "Lists directory '$lists_directory' not found";
	my $destination = File::Spec->catfile( $lists_directory, $list, $new_filename );

	if ( $destination =~ /\s/ ) {
		confess "Found spaces in destination: '$destination'";
	}
	if ( -f $destination ) {
		return 'Already added';
	}
	return $file_object->save_copy_as($destination);
}

sub reorder_in_playlist {
	my $self            = shift;
	my ($number)        = @_;

	$number             =~ /^[0-9]+$/ or die "Invalid number '$number'";
	$number             = sprintf("%03d", $number);

	my $file_object     = $self->{curation_progress}->{current_file_object} or confess 'No current file object set';
	my $new_filename    = $file_object->filename();

	# Remove old number ordering if present
	$new_filename =~ s/^[0-9]+\.//;

	# Give filename the new number
	$file_object->new_filepath( $file_object->filepath() );
	$file_object->new_filename( "$number.$new_filename" );

	return $file_object->rename_to_new_path_and_name_on_same_filesystem();

	return;
}

sub status {
	my $self   = shift;
	my $status = '';
	if ( $self->{curation_progress}->{new_filepath} ) {
		$status .= "New filepath: $self->{curation_progress}->{new_filepath}\n";
	}
	if ( $self->{curation_progress}->{new_filename} ) {
		$status .= "New filename: $self->{curation_progress}->{new_filename}\n";
		if ( $self->{curation_progress}->{new_filename} =~ m|^(\w+)-| ) {
			my $artist = $1;
		}
	}
	if ( $self->{curation_progress}->{backed_up} ) {

		# backed up is actually just a flag to indicate that we checked to
		# see if we needed to back up. backed_up_location indicates that a
		# backup was done.
		if ( $self->{curation_progress}->{backed_up_location} ) {
			$status .= "Backed up to $self->{curation_progress}->{backed_up_location}\n";
		}
	}
	return $status;
}

sub skip {
	my $self = shift;

	alarm 0;    # deactivate evaluation timeout
	$self->{curation_progress}->{kept}                = undef;    #not sure if we're keeping it; we're skipping it for now
	$self->{curation_progress}->{evaluation_complete} = 1;

	return;
}

sub back {
	my $self = shift;

	alarm 0;    # deactivate evaluation timeout
	$self->{curation_progress}->{kept}                = undef;    #not sure if we're keeping it; we're skipping it for now
	$self->{curation_progress}->{evaluation_complete} = 1;

	return;
}

sub kept {
	my $self = shift;
	return $self->{kept};
}

sub curate {
	my $self = shift;

	my $message;

	$self->{curation_progress}->{curation_in_progress} = 1;
	$self->{curation_progress}->{evaluation_complete}  = 0;

	#once the user has started curation, continue that by default
	$self->{curation_progress}->{default_action} = 'c';

	my $color_1 = $self->{config}->{color_1};
	my $color_2 = $self->{config}->{color_2};
	my $color_3 = $self->{config}->{color_3};

	if ( !$self->{curation_progress}->{new_filename} ) {
		print color($color_1) . $self->prompt_new_filename() . color('reset');
	}
	if ( !$self->{curation_progress}->{new_filepath} ) {
		$message = $self->prompt_new_filepath();

		# if we don't have a backup directory configured, we're done
		if ( !$self->{secretary}->backup_directory() ) {
			$self->{curation_progress}->{curation_in_progress} = 0;
			return $message;
		}
	}

	# if we're not backed up, and we have a backup directory configured, back it up, then we're done
	if ( !$self->{curation_progress}->{backed_up} && $self->{secretary}->backup_directory() ) {
		$message = $self->backup();
		$self->{curation_progress}->{curation_in_progress} = 0;
		return $message;
	}

	$message                                          = $self->love_and_curate();
	$self->{curation_progress}->{kept}                = 1;
	$self->{curation_progress}->{evaluation_complete} = 1;

	return $message;
}

sub recurate {
	my $self = shift;

	$self->{curation_progress}->{new_filename}         = undef;
	$self->{curation_progress}->{new_filepath}         = undef;
	$self->{curation_progress}->{curation_in_progress} = 1;
	$self->{curation_progress}->{evaluation_complete}  = 0;
	$self->{curation_progress}->{backed_up}            = 0;

	return $self->curate();
}

sub backup {
	my $self = shift;
	my %args = @_;

	my $new_filename = ( $args{new_filename} || $self->{curation_progress}->{new_filename} ) or confess "No new filename set";

	my $backup_file_object = $args{backup_this} || $self->{curation_progress}->{current_file_object};
	$backup_file_object or confess 'No backup file object';
	ref $backup_file_object or confess 'Backup file must be object';

	# Hack for now because I'm not sure how to handle this. Now that I am re-examining existing library items, I don't really
	# need to back them up (add them to my mixtape) because they were already backed up in the past
	if ($backup_file_object->path_and_name() =~ m|/collection/|) {
		return $self->{curation_progress}->{backed_up} = 1;
	}

	my $backup_directory = $self->{secretary}->backup_directory();
	if ( !$backup_directory ) {
		$self->{curation_progress}->{backed_up} = 1;
		return "No backup directory configured";
	}
	if ( !-d $backup_directory ) {
		confess "Backup directory '$backup_directory' not found";
	}

	$self->{curation_progress}->{backed_up_location} = File::Spec->catfile( $backup_directory, $new_filename );

	#print "backing up to $backup_location\n";
	File::Copy::copy( $backup_file_object->path_and_name(), $self->{curation_progress}->{backed_up_location} ) or confess "Could not back up to $self->{curation_progress}->{backed_up_location}";
	$self->{curation_progress}->{backed_up} = 1;
	return "Backed up to $self->{curation_progress}->{backed_up_location}\n";
}

sub love_and_curate {
	my $self = shift;
	my %args = @_;

	$self->{scorekeeper} or confess 'No scorekeeper';
	my $file = $self->{curation_progress}->{current_file_object};
	$file or confess 'No current file object';
	my $genre_name = $file->genre() or confess 'File has no genre: ' . Dumper $file;
	my $new_filepath = $self->{curation_progress}->{new_filepath} or confess 'No new filepath found';
	-d $new_filepath or confess "New file path '$new_filepath' does not exist";
	my $new_filename = $self->{curation_progress}->{new_filename} or confess 'No new filename found';
	$file->new_filepath($new_filepath);
	$file->new_filename($new_filename);

	if ( -f $file->new_path_and_name() ) {
		return "File exists, skipping: '" . $file->new_path_and_name() . "'";
	}

	$self->{scorekeeper}->love(
		file         => $file->path_and_name(),
		clean_artist => $file->clean_with_spaces( $file->artist() ),
		clean_title  => $file->clean_with_spaces( $file->title() ),
		source_name  => $file->source(),
		published    => $self->{curation_progress}->{published},
		genre_name   => $genre_name,
	);

	return $file->move_to_new_path_and_name();
}

sub like_but_remove {
	my $self = shift;

	# only "like" it once
	if ( $self->{curation_progress}->{liked_but_removed} || $self->{curation_progress}->{disliked_and_removed} ) {
		return;
	}

	$self->{scorekeeper} or confess 'No scorekeeper';
	my $file = $self->{curation_progress}->{current_file_object} or confess 'No current file object';
	$self->{scorekeeper}->like(
		file         => $file->path_and_name(),
		clean_artist => $file->clean_with_spaces( $file->artist() ),
		clean_title  => $file->clean_with_spaces( $file->title() ),
		source_name  => $file->source(),
		published    => $self->{curation_progress}->{published},
	);
	$self->{curation_progress}->{default_action}    = 's';    # we've removed the file, but keep playing until skipped, or until timeout, when we'll "skip" it
	$self->{curation_progress}->{liked_but_removed} = 1;

	return $self->trash(@_);
}

sub dislike_and_remove_later {
	my $self = shift;

	# only do this once
	if ( $self->{curation_progress}->{liked_but_removed} || $self->{curation_progress}->{disliked_and_removed} ) {
		return;
	}

	$self->{scorekeeper} or confess 'No scorekeeper';
	my $file = $self->{curation_progress}->{current_file_object} or confess 'No current file object';
	$self->{scorekeeper}->dislike(
		file         => $file->path_and_name(),
		clean_artist => $file->clean_with_spaces( $file->artist() ),
		clean_title  => $file->clean_with_spaces( $file->title() ),
		source_name  => $file->source(),
		published    => $self->{curation_progress}->{published},
	);
	$self->{curation_progress}->{default_action}       = 's';    # we've removed the file, but keep playing until skipped, or until timeout, when we'll "skip" it
	$self->{curation_progress}->{disliked_and_removed} = 1;

	return $self->trash(@_);
}

sub dislike_and_remove {
	my $self = shift;
	if ( $self->{scorekeeper} ) {
		my $file = $self->{curation_progress}->{current_file_object} or confess 'No current file object';
		$self->{scorekeeper}->dislike(
			file         => $file->path_and_name(),
			clean_artist => $file->clean_with_spaces( $file->artist() ),
			clean_title  => $file->clean_with_spaces( $file->title() ),
			source_name  => $file->source(),
			published    => $self->{curation_progress}->{published},
		);
	}
	$self->{curation_progress}->{evaluation_complete} = 1;
	return $self->trash(@_);
}

sub hate_and_remove {
	my $self = shift;
	$self->{scorekeeper} or confess 'No scorekeeper';
	my $file = $self->{curation_progress}->{current_file_object} or confess 'No current file object';
	$self->{scorekeeper}->hate(
		file         => $file->path_and_name(),
		clean_artist => $file->clean_with_spaces( $file->artist() ),
		clean_title  => $file->clean_with_spaces( $file->title() ),
		source_name  => $file->source(),
		published    => $file->{published},
	);
	$self->{curation_progress}->{evaluation_complete} = 1;
	return $self->trash(@_);
}

sub love_but_remove {
	my $self = shift;

	# only "like" it once
	if ( $self->{curation_progress}->{liked_but_removed} || $self->{curation_progress}->{disliked_and_removed} ) {
		return;
	}

	$self->{scorekeeper} or confess 'No scorekeeper';
	my $file = $self->{curation_progress}->{current_file_object} or confess 'No current file object';
	$self->{scorekeeper}->love(
		file         => $file->path_and_name(),
		clean_artist => $file->clean_with_spaces( $file->artist() ),
		clean_title  => $file->clean_with_spaces( $file->title() ),
		source_name  => $file->source(),
		published    => $self->{curation_progress}->{published},
	);
	$self->{curation_progress}->{default_action}    = 's';    # we've removed the file, but keep playing until skipped, or until timeout, when we'll "skip" it
	$self->{curation_progress}->{liked_but_removed} = 1;

	return $self->trash(@_);
}

sub edit {
	my $self = shift;
	my $command = $self->{config}->{edit_command} or return "No edit command configured";
	alarm 0;                                                  # deactivate evaluation timeout so playback does not skip to next song while editing is in progress
	$self->execute_evaluation_command( command => $command );
	return 'Editing complete';
}

sub trash {
	my $self = shift;
	my %args = @_;

	#print "Attempting to trash file";
	my $trash_directory = $self->{secretary}->trash_directory();
	$trash_directory or confess 'No trash directory specified';
	-d $trash_directory or confess "Trash directory '$self->{trash_directory}' is not a directory";

	my $file = $self->{curation_progress}->{current_file_object} || $args{file_object};
	$file or confess 'No file to trash';
	my $old_path_and_name = $file->path_and_name();
	my $trash_location = File::Spec->catfile( $trash_directory, $file->filename() );

	# if a file with the same name already exists in trash, rather than worry about
	# coming up with a new name for it, in these rare cases, let's just actually
	# delete the file.
	if ($old_path_and_name eq $trash_location) {
		return "Already trashed\n";
	} else {
		eval { $file->move_to($trash_location); };
		if ($@) {
			my $path_and_name = $file->path_and_name();
			$self->{curation_progress}->{kept} = 0;
			if ( -f $path_and_name )    # something or someone else might have removed it already
			{
				unlink $path_and_name or confess "Could not remove file '$path_and_name' permanently: $!";
				return "Deleted permanently ($@: '$trash_location')";
			}
			return "File vanished";
		}

		# if we've backed it up, but now we're trashing it, remove the backup as well
		if ( -f $self->{curation_progress}->{backed_up_location} ) {
			unlink $self->{curation_progress}->{backed_up_location};
			$self->{curation_progress}->{backed_up_location} = undef;
		}

		$self->{curation_progress}->{kept} = 0;
		return "Trashed; restore by running:\nmv $trash_location $old_path_and_name\n";
	}
}

sub prompt_new_filename {
	my $self        = shift;
	my %args        = @_;
	my $file_object = $self->{curation_progress}->{current_file_object} or confess 'No file object';

	my ( $artist, $title, $file_location ) = ( $file_object->artist(), $file_object->title(), $file_object->path_and_name() );

	my $color_1 = $self->{config}->{color_1};
	my $color_2 = $self->{config}->{color_2};
	my $color_3 = $self->{config}->{color_3};

	my $class = $self->get_class_name();
	my $new_filename;
	do {
		@ARGV = ();    # IO::Prompter hates it when there's stuff in @ARGV
		print( "Artist name " . color($color_1) . "[" . color($color_3) . $artist . color($color_1) . "]" . color('reset') );
		$artist = prompt ": ", -default => $artist;
		$artist = $class->clean_with_spaces($artist);
	} while ( !$artist );
	do {
		@ARGV = ();    # IO::Prompter hates it when there's stuff in @ARGV
		print( "Title " . color($color_1) . "[" . color($color_3) . $title . color($color_1) . "]" . color('reset') );
		$title = prompt ": ", -default => $title;
		$title = $class->clean_with_spaces($title);
	} while ( !$title );
	$new_filename = "$artist-$title.$self->{config}->{type}";    # Someday we should make this a configurable template
	$new_filename = $class->clean($new_filename);

	if ( $file_object->check_filename($new_filename) ) {
		$file_object->artist($artist);
		$file_object->title($title);
		print color($color_1) . "Tagging file with artist '$artist' and title '$title'\n" . color('reset');
		$file_object->tag( artist => $artist, title => $title );
		$self->{curation_progress}->{new_filename} = $new_filename;

		return "New filename: $new_filename\n";
	}

	confess "'$new_filename'\n is not a valid filename\n";
	return;
}

# these filepaths correspond to genres. if we ever want to change that, it will be some work.
sub prompt_new_filepath {
	my $self = shift;

	my $new_filename = $self->{curation_progress}->{new_filename};
	if ( !$new_filename ) {
		return $self->prompt_new_filename();
	}

	my $color_1 = $self->{config}->{color_1};
	my $color_2 = $self->{config}->{color_2};
	my $color_3 = $self->{config}->{color_3};

	#let the user choose a directory to move the file into
	print color($color_3) . "\nChoose a genre:\n" . color('reset');
	my $curated_directory = $self->{secretary}->curated_directory() or confess 'No curated directory';
	-d $curated_directory or confess "Curated directory '$curated_directory' not found";
	my $directories_arrayref = App::MediaDiscovery::Directory->existing($curated_directory)->subdirs();
	my @directories;
	if ($directories_arrayref) {
		@directories = @$directories_arrayref;
	}

	#loop through directories the curator might want to put the song, giving them numbers the curator can choose
	my $default_choice;
	my $new_genre_choice = 0;
	for my $dir_index ( 0 .. $#directories ) {
		$new_genre_choice = $dir_index + 1;
		my $dir_name = $directories[$dir_index];

		#remove the last directory name from the full path to get the genre part
		my $genre_name;
		if ( $dir_name =~ m|^.+/([^/]+)$| ) {
			$genre_name = $1;
		} else {
			confess "Could not get genre name from directory '$dir_name'";
		}

		#guess where the curator might want to put this song, based on where other songs by this artist are found
		my $found_files = '';
		if ( $new_filename =~ m|(\w+)-| )    #if file is named artist-title, get artist name
		{
			my $artist_name = $1;

			#look for artist name in curated music directories
			if ( $found_files = `find -L $dir_name -iname '*$artist_name-*'` ) {
				if ( !$default_choice )      #if we haven't found a suggested directory already...
				{
					$default_choice = $dir_index;    #suggest this directory
				}

				#find file sizes of existing files, to help decide whether to replace existing ones if we are curating a duplicate
				my @found_files_array = sort split( "\n", $found_files );
				$found_files = '';
				for my $found_file (@found_files_array) {
					my $found_filename;
					if ( $found_file =~ m|/([^/]+)$| ) {
						$found_filename = $1;
					} else {
						confess "Could not get filename from '$found_file'";
					}
					my $file_size_mb_compare = '';
					if ( $new_filename eq $found_filename ) {
						my $existing_file_size = App::MediaDiscovery::File->existing( file_location => $found_file )->mb();
						$file_size_mb_compare = " (existing: ${existing_file_size}MB, new: " . $self->{curation_progress}->{current_file_object}->mb() . "MB)";
					}
					$found_files .= "\t$found_filename$file_size_mb_compare\n";
				}
			}
		}
		print color($color_1) . "[" . color($color_3) . $dir_index . color($color_1) . "]" . color($color_2) . " - $genre_name\n$found_files";
	}

	# add a choice for a new directory
	print color($color_1) . "[" . color($color_3) . $new_genre_choice . color($color_1) . "]" . color($color_2) . " - <add new genre>\n" . color('reset');

	#let the curator choose the directory to put the song
	$default_choice ||= 0;
	my $dir_choice;
	do {
		my $choices;
		for my $dir_index ( 0 .. $#directories ) {
			my $dir_name = $directories[$dir_index];

			#remove the last directory name from the full path to get the genre part
			my $genre_name;
			if ( $dir_name =~ m|^.+/([^/]+)$| ) {
				$genre_name = $1;
			} else {
				confess "Could not get genre name from directory '$dir_name'";
			}
			$choices->{$dir_index} = $dir_name;
		}
		$choices->{$new_genre_choice} = '<add new genre>';

		@ARGV = ();    # IO::Prompter hates it when there's stuff in @ARGV
		print "\nNew location " . color($color_1) . "[" . color($color_3) . $default_choice . color($color_1) . "]" . color('reset');
		$dir_choice = prompt ": ", -default => $default_choice, -guarantee => [ 0 .. $new_genre_choice ], -integer, $choices;
		if ( !defined($dir_choice) || $dir_choice eq '' ) {
			$dir_choice = $default_choice;
		}
	} while ( $dir_choice !~ /^\d+$/ or $dir_choice < 0 or $dir_choice > $new_genre_choice );

	my $chosen_directory;
	if ( $dir_choice == $new_genre_choice ) {
		$chosen_directory = $self->prompt_new_genre();
		if ( !$chosen_directory ) {
			return;
		}
		$chosen_directory = File::Spec->catfile( $curated_directory, $chosen_directory );
		if ( !-d $chosen_directory ) {
			make_path($chosen_directory) or die "Could not make path '$chosen_directory'";
		}
		if ( $self->{config}->{use_letter_subdirectories} ) {
			for my $letter ( 'a' .. 'z' ) {
				my $letter_subdir = File::Spec->catfile( $chosen_directory, $letter );
				make_path($letter_subdir) or die "Could not make path '$letter_subdir'";
			}
		}
	} else {
		$chosen_directory = $directories[$dir_choice];
	}

	return $self->new_curated_filepath(
		genre_directory => $chosen_directory,
		new_filename    => $new_filename
	);
}

sub prompt_new_genre {
	my $self = shift;
	my %args = @_;

	@ARGV = ();    # IO::Prompter hates it when there's stuff in @ARGV
	my $genre = prompt "Genre name:", -guarantee => qr/^\w*$/;

	return $genre;
}

sub new_curated_filepath {
	my $self = shift;
	my %args = @_;

	my $new_filename = $args{new_filename}    or confess "Must provide new_filename";
	my $new_filepath = $args{genre_directory} or confess "Must provide genre_directory";
	my $file_object  = $args{file_object}     || $self->{curation_progress}->{current_file_object} or confess 'No file object';

	# remove the last directory name from the full path to get the genre part, and
	# set the file's genre
	my $genre_name;
	if ( $new_filepath =~ m|^.+/([^/]+)$| ) {
		$genre_name = $1;
	} else {
		confess "Could not get genre name from directory '$new_filepath'";
	}
	$file_object->genre($genre_name);

	# get first letter of filename for letter subdirectories. if we have these
	# subdirectories, we'll use them. if not, that's ok too (but less tested since i do use the letter subdirs).
	my @array = split( //, $new_filename );
	my $char_dir = shift @array;
	if ( $char_dir =~ /^\d$/ ) {
		$char_dir = 'a';
	} elsif ( $char_dir =~ /^[a-z]$/ ) {
		# all good
	} else {
		confess "Found invalid character for first character of filename: '$char_dir' for filename '$new_filename'";
	}
	if ( -d File::Spec->catfile( $new_filepath, $char_dir ) ) {
		$new_filepath = File::Spec->catfile( $new_filepath, $char_dir );
	}

	if ( $file_object->new_filepath($new_filepath) ) {
		$self->{curation_progress}->{new_filepath} = $new_filepath;
		return "New filepath: $new_filepath\n";
	}

	return;
}

sub other_curated_files_by_artist {
	my $self = shift;
	my %args = @_;

	my $file = $args{file_object} || $self->{curation_progress}->{current_file_object};
	my $artist = $file->clean( $file->artist() );

	my $curated_directory = $self->{secretary}->curated_directory();

	my $command = "find -L $curated_directory -iregex '.+/\\(.*-\\)*$artist-.+\\.$self->{config}->{type}'";

	#die $command;
	my $existing_files_string = `$command`;
	my @existing_files        = split( /\n/, $existing_files_string );
	my $type_module           = $self->{module} or confess "No file type module set";

	@existing_files = map { $type_module->existing( file_location => $_ ) } sort @existing_files;

	return @existing_files;
}

sub downloaded_based_on_interest_in {
	my $self = shift;
	my %args = @_;

	my $file = $args{file_object} or confess "No file object";

	my $scorekeeper = $self->{scorekeeper};
	return $scorekeeper->acquisition_reason( file => $file->path_and_name() );
}

# TODO XXX FIXME i thinki want to move this into secretary
sub cleanup_files_marked_for_removal {
	my $self = shift;
	my %args = @_;

	my $remove_files = $self->{scorekeeper}->files_marked_for_removal();

	for my $remove_file (@$remove_files) {
		my ( $acquisition_id, $file_location ) = ( $remove_file->{acquisition_id}, $remove_file->{acquisition_destination} );
		my $acquisitions_directory = $self->{secretary}->new_acquisitions_directory();
		$acquisitions_directory = quotemeta $acquisitions_directory;
		$file_location =~ m|^$acquisitions_directory| or confess "Invalid remove file location: '$file_location'";
		$file_location =~ /\.\./ and confess "Invalid remove file location: '$file_location'";
		if ( !-f $file_location ) {
			print "Already trashed: $file_location\n";
		} else {
			my $message = $self->trash( file_object => App::MediaDiscovery::File->existing( file_location => $file_location ) );
			print $message;
		}
		$self->{scorekeeper}->mark_removed( acquisition_id => $acquisition_id );
	}
	return;
}

# TODO XXX FIXME i think i want to move this into secretary
sub curate_files_marked_for_curation {
	my $self = shift;
	my %args = @_;

	my $class = $self->get_class_name();

	my $files_marked_for_curation = $self->{scorekeeper}->files_marked_for_curation();
	for my $file (@$files_marked_for_curation) {
		my ( $acquisition_id, $file_location, $source_name, $curated_filename, $genre_name, $publish, ) = ( $file->{acquisition_id}, $file->{acquisition_destination}, $file->{source_name}, $file->{curated_filename}, $file->{genre_name}, $file->{publish}, );

		$curated_filename =~ /^[a-z0-9\-_]+\.$self->{config}->{type}$/ or confess "Invalid curated filename '$curated_filename'";
		print "Curating '$curated_filename', acquisition id '$acquisition_id'\n";

		my $work;

		eval { $work = $class->existing( file_location => $file_location, ); };

		# don't do or print anything when this breaks, so we don't clog the logs with error messages
		if ($@) { exit; }

		$work->new_filename($curated_filename);
		my $curated_directory = $self->{secretary}->curated_directory() or confess "No curated directory";
		-d $curated_directory or confess "Curated directory '$curated_directory' not found";    # potential race condition here. directory could have been removed after having been selected a while ago (currently genre directory is normally selected in the web browser when evaluating over the web, then curated a while later). if so we just quit and let them try again. we could re-add the directory but i don't like software that does too much behind your back.
		my $genre_dir = File::Spec->catfile( $curated_directory, $genre_name );
		-d $genre_dir or confess "Directory '$genre_dir' not found";
		my $message = $self->new_curated_filepath(
			file_object     => $work,
			genre_directory => $genre_dir,
			new_filename    => $curated_filename,
		);

		my $color_1 = $self->{config}->{color_1};
		my $color_2 = $self->{config}->{color_2};
		my $color_3 = $self->{config}->{color_3};

		print color($color_1) . $message . color('reset');

		if ( $self->{secretary}->backup_directory() ) {
			print $self->backup( backup_this => $work, new_filename => $curated_filename );
		}

		eval { $message = $work->move_to_new_path_and_name(); };
		if ($@) {
			$self->{scorekeeper}->mark_uncurated( acquisition_id => $acquisition_id );
			confess "Could not move file: " . Dumper $work;
		} else {
			print $message;
			$self->{scorekeeper}->mark_curated( acquisition_id => $acquisition_id );
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

# delegate some functions to scorekeeper, so calling code
# won't have to worry about it.
sub love {
	my $self = shift;
	return $self->{scorekeeper}->love(@_);
}

sub like {
	my $self = shift;
	return $self->{scorekeeper}->like(@_);
}

sub dislike {
	my $self = shift;
	return $self->{scorekeeper}->dislike(@_);
}

sub mark_for_curation {
	my $self = shift;
	return $self->{scorekeeper}->mark_for_curation(@_);
}

sub mark_as_skipped {
	my $self = shift;
	return $self->{scorekeeper}->skip(@_);
}

sub mark_for_removal {
	my $self = shift;
	return $self->{scorekeeper}->mark_for_removal(@_);
}

sub artist_rating {
	my $self = shift;
	return $self->{scorekeeper}->artist_rating(@_);
}

sub source_rating {
	my $self = shift;
	return $self->{scorekeeper}->source_rating(@_);
}

# secretary delegation
sub content_subdirs {
	my $self = shift;
	return $self->{secretary}->content_subdirs(@_);
}

# aliases for function calls, for simpler command line use
sub p { return shift->evaluate(@_); }
sub z { return shift->evaluate(@_); }
sub u { return shift->pause(@_); }
sub s { return shift->skip(@_); }
sub b { return shift->back(@_); }
sub f { return shift->recurate(@_); }
sub c { return shift->curate(@_); }
sub r { return shift->dislike_and_remove(@_); }
sub v { return shift->love_but_remove(@_); }
sub h { return shift->hate_and_remove(@_); }
sub l { return shift->like_but_remove(@_); }
sub e { return shift->dislike_and_remove_later(@_); }

1;

