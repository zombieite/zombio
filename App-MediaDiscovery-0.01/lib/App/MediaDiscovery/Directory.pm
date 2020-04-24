use strict;

package App::MediaDiscovery::Directory;

use File::Spec;
use Carp;

sub existing {
	my $class       = shift;
	my ($directory) = @_;
	my $self        = bless( {}, $class );
	if ($directory) {
		if ( -d ($directory) ) {
			$self->{directory} = $directory;
			if ( $self->{directory} =~ m|/([^/]+)/?$| ) {
				$self->{dirname} = $1;
			} else {
				confess "Could not get dirname from '$self->{directory}'";
			}
		} else {
			confess "Directory '$directory' does not exist";
		}
	} else {
		confess "Must provide dir location";
	}
	return $self;
}

sub subdirs {
	my $self = shift;
	my %args = @_;

	$self->{subdirs} = undef;
	opendir( my $dir, $self->{directory} ) or confess $!;
	my @stuff = readdir($dir) or confess $!;
	closedir $dir or confess $!;

	for my $maybe_dir (@stuff) {
		if ( $maybe_dir !~ m|^\.+$| ) {
			my $full_maybe_dir = File::Spec->catfile( $self->{directory}, $maybe_dir );
			if ( -d ($full_maybe_dir) ) {
				push( @{ $self->{subdirs} }, $full_maybe_dir );
			}
		}
	}

	if ( $self->{subdirs} ) {
		@{ $self->{subdirs} } = sort @{ $self->{subdirs} };
	}

	return $self->{subdirs};
}

sub subfiles {
	my $self = shift;
	my %args = @_;

	my $filename_match = $args{filename_match};

	$self->{subfiles} = undef;
	opendir( my $dir, $self->{directory} ) or confess $!;
	my @stuff = readdir($dir) or confess $!;
	closedir $dir or confess $!;
	$self->{subfiles} = [];

	for my $maybe_file (@stuff) {
		if ( $maybe_file !~ m|^\.+| ) {
			#warn "Using '$maybe_file'";
			my $full_maybe_file = File::Spec->catfile( $self->{directory}, $maybe_file );
			if ( -f ($full_maybe_file) ) {
				if ( !$filename_match || ( $filename_match && ( $full_maybe_file =~ /$filename_match/ ) ) ) {
					push( @{ $self->{subfiles} }, $full_maybe_file );
				}
			}
		} else {
			#warn "Skipping '$maybe_file'";
		}
	}
	@{ $self->{subfiles} } = sort @{ $self->{subfiles} };

	return $self->{subfiles};
}

sub path {
	my $self = shift;
	return $self->{directory};
}

sub dirname {
	my $self = shift;
	return $self->{dirname};
}

sub size {
	my $self = shift;
	$self->{directory} =~ m|^/[\w_\-\./]+$| or confess "Not sure if I can check size of directory with a funny name like '$self->{directory}'";
	my $cmd         = "du -sk $self->{directory} | cut -f1";
	my $space_taken = `$cmd`;
	if ( $space_taken =~ /^(\d+)$/ ) {
		$space_taken = $1;
	} else {
		confess "Could not figure out space taken up by dir";
	}
	$space_taken *= 1024;
	return $space_taken;
}

sub mb {
	my $self = shift;
	return sprintf( "%.2f", ( $self->size() ) / ( 2**20 ) );
}

sub rmrf {
	my $self = shift;
	$self->{directory} =~ m|^/[\w_\-\./]+$| or confess "Not sure if I can remove a directory with a funny name like '$self->{directory}'";
	my $cmd = "rm -rf $self->{directory}";
	system($cmd) and confess "Could not do command '$cmd'";
	return;
}

1;
