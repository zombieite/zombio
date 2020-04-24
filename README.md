# App-MediaDiscovery version 0.01

During the golden age of mp3 blogs (2005-2015) Zombio could be used to discover and download mp3s. It could still be used for that, but few mp3 blogs make their mp3s downloadable anymore. Nowadays I use it only as a music player and music organizer.

## Installing Zombio on a Mac

Download Zombio via the ZIP link on the GitHub page. Right click the zombio-master.zip in your Download manager and choose "Show in Finder". Double click zombio-master.zip in the window that opens. This will unzip the archive and create a folder called zombio-master (with no ".zip"). Click the Finder icon (the blue face) and then choose File->New Finder Window. Find your home directory, the one with your username and a house beside it. You may have to navigate from Macintosh HD to Users to find it. Drag the zombio-master folder into that home directory window.

Open up a Terminal (in Macintosh HD, Applications, Utilities). Type:

```
which make
````

If you get a result that looks something like this:

```
/usr/bin/make
```

You're all set with installation of "make." If you see this, you have to install XCode:

```
no make in /bin /sbin /usr/bin /usr/sbin
```

To install Xcode: Apple Icon, App Store, search for Xcode, run installer (don't just copy the file to Applications). Retype "which make" in the Terminal to make sure it's working now.

Run the following commands in the Terminal window.


```
sudo su - # You'll have to enter your password
perl -MCPAN -e shell # Let it configure itself as much as possible, or use the default configuration options for the most part.
exit # Exits the CPAN shell
exit # Exits root shell and # sign changes to $ sign
cd zombio-master/App-MediaDiscovery-0.01/ # Navigates us into the Zombio installer code directory
perl Makefile.PL
make
sudo make install # You'll have to enter your password again
sudo cpan install Config::General
sudo cpan install IO::Prompter
sudo cpan install MP3::Info
sudo cpan install MP3::Tag
sudo cpan install Term::ReadKey
sudo cpan install XML::Simple
sudo cpan install DBI
sudo cpan install DBD::SQLite
```

Then, to run it (replace "yourusername" below):


```
export PATH=$PATH:/Users/yourusername/zombio-master/App-MediaDiscovery-0.01/bin/ # Necessary because zombio_get will also be run in the background and that command must be able to be found, too
zombio_curate
```

It may take a while to download some music, and it may not download enough to listen to until an hour or so has passed. If something has gone wrong in its configuration, it may not be looking for music at all. I need to add a better error message when that happens.

The first one or two times you run it, Zombio will take a while to start playing music, and it won't be very smart. But be patient. It gets better.

When you first starting using Zombio, it will prompt you for the locations of your music directories. You can skip this step, but that means you'll have to spend a few days listening to music that is chosen completely at random (though that might be fun too). If you let Zombio examine your music directories, it will store information about your favorite artists. This may take a while. If your collection is large, I'd let it run for up to an hour before killing it. It will only recognize mp3 files at the moment. Unfortunately, iTunes doesn't create or download mp3 files by default--it uses its own file format. So if you've left your iTunes on its default settings, Zombio probably won't recognize any of your iTunes music.

The first time you run it, you will also be stuck waiting while it does some initial downloads. In the future when you start up Zombio, you won't have to wait. The initial downloads will be pretty much random, even if you've allowed Zombio to examine your music directories, because its goal at this point will be to find you something, anything to listen to right now. It has to establish a buffer full of songs so you never run out of stuff to listen to.

When downloading is complete, music should start to play, and you can follow the prompts to decide what to do with each song. If you're confused, you don't have to do anything. Zombio will simply play like a radio station. If you curate songs (that is, add them to your collection), Zombio will use this information to download similar music in the future. If you remove songs, Zombio will avoid music like this in the future. The more you use it, the smarter it gets.

If you choose to curate some songs, Zombio will keep them for you in its collection folder in your home directory by default. You can remove music files, add music files, or rename music files in these directories if you wish. But do not remove or rename any Zombio-created directories.

Do not remove the file which is located (by default) at ~/zombio/data/zombio.db. This is the database that stores your music tastes. If you delete it, Zombio will forget what you like. You may even want to back this file up along with your music collection. If you know sqlite3, you can use it to explore that database, but it's best not to change anything unless you know what you're doing.

A process called zombio_get keeps running for quite a while (days) after you quit zombio_curate or zombio_play. This process will keep collecting music for you in the background after you're done listening to Zombio. Most of the time it will just sit there doing nothing, but occasionally it will suddenly hog a bunch of bandwidth. Feel free to kill it if you need to.
