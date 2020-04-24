use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'App::MediaDiscovery',
    VERSION_FROM      => 'lib/App/MediaDiscovery.pm', # finds $VERSION
    PREREQ_PM         => {
        Config::General => undef,
        IO::Prompter    => undef,
        XML::Simple     => undef,
        DBI             => undef,
        DBD::SQLite     => undef,
        MP3::Info       => undef,
        MP3::Tag        => undef,
        URI::Escape     => undef,
        Data::Dumper    => undef,
        Carp            => undef,
        Term::ReadKey   => undef,
        File::Path      => undef,
        File::Spec      => undef,
        List::Util      => undef,
        LWP::UserAgent  => undef,  
    }, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
       (AUTHOR         => 'john <john_binns@yahoo.com>') : ()),
);
