# App-MediaDiscovery version 0.01

During the golden age of mp3 blogs (2005-2015) Zombio could be used to discover and download mp3s. It could still be used for that, but few mp3 blogs make their mp3s downloadable anymore. Nowadays I use it mostly as a music player and music organizer.

## Installing Zombio on a Mac

Download Zombio via the "Code" button and ZIP link on the GitHub page. Right click the zombio-master.zip in your Download manager and choose "Show in Finder". Double click zombio-master.zip in the window that opens. This will unzip the archive and create a folder called zombio-master (with no ".zip"). Click the Finder icon (the blue face) and then choose File->New Finder Window. Find your home directory, the one with your username and a house beside it. You may have to navigate from Macintosh HD to Users to find it. Drag the zombio-master folder into that home directory window.

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

Run the following commands in the Terminal window in your home directory.


```
cd
perl -MCPAN -e shell # Let it configure itself as much as possible, or use the default configuration options for the most part. Choose local::lib as how to set it up.
exit # Exits the CPAN shell
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

Then, to run it (replace "$USER" below with your username):


```
export PATH=$PATH:/Users/$USER/zombio-master/App-MediaDiscovery-0.01/bin/ 

zombio_play
```
