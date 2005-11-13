#!/usr/bin/perl -w
# Quick and dirty backup script
# Copyright (C) 2005 Adam J Nelson
# 
# Does a quick and dirty system backup

use Cwd;
use File::Find;
use File::Temp;
use Getopt::Long;
use Pod::Usage;
use Digest::MD5 qw(md5_hex);
use Net::Domain;

#Pre-size the backup_paths hash
keys %backup_paths = 100;

$argfile = ''; 
$server = '';
$username = '';
$use_rsync = 0;
$verbosity = 1;
$help = 0;
$setup = 0;
$include_filter = '';
$include_filter_sub = sub {return 1;};

$num_snaps = 10; #The number of snapshots to keep before the oldest start to get culled
$snap_set = "qdb"; #The name of the snapshot set to use by default
$prev_snap_set = ''; #The snapshot set to link this snapshot to.  Empty means most recent snapshot.
$remote_path = "~/" . Net::Domain::hostname();
$tmp_remote_path = File::Spec->catdir("$remote_path", "qdbtemp"); #The path where the files will be rsync'd to initially

$ssh_cmd = "ssh";
$rsync_cmd = "rsync";

#Constant verbosity levels used to specifying the verbosity of messages 
#printed with verbose_print
$INFO = 1;
$VERBOSE = 2;
$DEBUG = 3;

#Sub prototypes
sub do_setup;
sub verbose_print;
sub parse_argv;
sub remote_script;
sub run_remote_script;
sub rsync_file_up;
sub rsync_file_down;
sub ssh_command;
sub backup_files;
sub get_rsync_base_cmd;

#Post-backup variables need default values for use in pre-backup script
$file_list_fh = -1;
$file_list_name = '';
$norot_file_list_fh = -1;
$norot_file_list_name = '';
$num_files = 0;
$num_norot_files = 0;
$prev_snap = '';

#Parse the command line
parse_argv();

#Are there additional args to read from a file?
if ($argfile) {
   #User specified a file containing command line arguments
   if (! -f $argfile) {
      die "Arguments file '$argfile' does not exist\n";
      pod2usage(2);
   }

   open(ARGFILE, $argfile) || die "Unable to read arguments from $argfile";
   verbose_print $VERBOSE, "Getting additional args from $argfile\n";
   while (<ARGFILE>) {
      chomp;

      #Skip lines w/ leading whitespace or a #
      next if (/^\s/ || /^\#/);

      if ($_) {
         verbose_print $DEBUG, "Got '$_' from $argfile\n";
         #Command line params can be either commands alone, like --help or -?, 
         #or they can be associated with values, like --password spankme.
         #So, split on the first space after what looksl ike a command line arg
         if (/^--?\w.*?\s+/) {
            #Looks like a command followed by some space, so split on the first space
            push @ARGV, split(/\s+/, $_, 2);
         } else {
            #Doesn't look like a command; don't split at all
            push @ARGV, $_;
         }
      }                    
   }
   close ARGFILE;

   verbose_print $DEBUG, "ARGV after file:\n\t[", join("]\n\t[", @ARGV), "]\n";

   #Parse the command line params again, this time reflecting the args from the argfile
   parse_argv();
}

#If the setup mode has been enabled, generate an SSH keypair
#and go through the motions of putting it on the remote server
if ($setup) {
   do_setup();
   exit 0;
}

#Any remaining args are assumed to be paths
#Copy argv into @paths, to get rid of it's annoying
#0-is-1 semantics
foreach (@ARGV) {
   if (! -e || ! -d) {
      warn "Path [$_] does not exist or is not a directory.  Skipping.\n";
      next;
   }
   push @paths, $_;
}

#If there are no paths specified, use cwd
if (@paths == 0) {
   verbose_print $VERBOSE, "Paths from argv is empty.  Defaulting to cwd.\n";
   @paths = (getcwd);
}

#Verify the args.  Server and username must be specified
if (!$server) {
   die "A server must be specified\n";
   pod2usage(2);
}

if (!$username) {
   die "A username must be specified\n";
   pod2usage(2);
}

#If an include filter was specified, compile it into a procedure
if ($include_filter) {
   $include_filter_sub = generateSub('global_include_filter', $include_filter);
}

verbose_print $VERBOSE, "Server: $server\n";
verbose_print $VERBOSE, "Username: $username\n";

#Upload the server-side scripts used to support the backup.
#These scripts perform pre-processing like finding which
#previous snapshot to use, and post-processing like doing the snapshot
#rotation after the fact

#Upload this script to the server, run it, download the qdb_run file it outputs, 
#and suck in the name/value pairs in the qdb_run file
eval {
   %qdb_run = run_remote_script('pre_backup');
};

if ($@) {
   die "Error preparing server $server for backup:\n$@\n";
}

#The script will tell us for sure which previous snapshot to use
#If it's still empty, that means there are no previous snapshots on 
#this server
$prev_snap = $qdb_run{'prev_snap'};

verbose_print $VERBOSE, "$server reports previous snapshot: $prev_snap\n";

verbose_print $INFO, "Searching folder(s): \n\t", join("\n\t", @paths), "\n";
foreach (@paths) {
   eval {
      &File::Find::find(\&wanted, $_);
   };

   if ($@) {
      warn "Problems searching [$_]: $@\n";
   }
}

if (!%backup_paths) {
   die "No .qdb files were found in the path(s) searched.  Nothing to backup.\n";
}

verbose_print $INFO, "Found the following .qdb files:\n";
for my $folder (sort(keys(%backup_paths))) {
   verbose_print $INFO, "\t", $folder, "\n";

   my %dir = %{$backup_paths{$folder}};
   for (sort(keys(%dir))) {
      verbose_print $VERBOSE, "\t\t", $_, " = ", $dir{$_}, "\n";
   }
}

#%backup_paths contains the paths to backup as keys, 
#and a hash of name/value pairs as the value.  This secondary
#hash controls the backup behavior of the folder, including whether it is included or excluded,
#etc
#
#Build two lists of files.  One, the list of files to include in the normal, rotating
#backup.  Two, the list of files to backup without rotating
($file_list_fh, $file_list_name) = File::Temp::tempfile();
$num_files = 0;

($norot_file_list_fh, $norot_file_list_name) = File::Temp::tempfile();
$num_norot_files = 0;

verbose_print $INFO, "Building list of files to backup...\n";

#Many paths in %backup_paths are children other other paths in %backup_paths.
#There's no need to traverse these paths multiple times.  Thus, don't traverse
#those child paths specifically
@dedupe_path_list = grep{ !$backup_paths{$_}{'ancestor'} } sort(keys(%backup_paths));

&File::Find::find(\&build_lists, @dedupe_path_list);

#If there was at least one norot file, we'll need to upload the norot file list
#itself to the server, so the post-backup step can delete old copies of the norot files
if ($num_norot_files) {
   print $norot_file_list_fh "$norot_file_list_name\n";
}

close $file_list_fh;
close $norot_file_list_fh;

if ($verbosity >= $VERBOSE) {
   print "List files: $file_list_name and $norot_file_list_name\n";
   
   print "Files to include:\n";
   open(LISTFILE, $file_list_name) || die;
   while (<LISTFILE>) {
      chomp;
      print "$_\n";
   }
   close(LISTFILE);
   
   print "\n\nFiles to include w/o rotation:\n";
   
   open(LISTFILE, $norot_file_list_name) || die;
   while (<LISTFILE>) {
      chomp;
      print "$_\n";
   }
   close(LISTFILE);
}

if (!$num_files  && !$num_norot_files) {
   die "No backup files were found.  Ensure your .qdb files are not excluding all files.\n";
}

verbose_print $INFO, "Found $num_files files to backup with rotation, and $num_norot_files to back up without rotation.\nProceeding with backup...\n";

#If there are any files included in the normal rotation, copy them now
if ($num_files) {
   backup_files(1, $file_list_name);
}

if ($num_norot_files) {
   backup_files(0, $norot_file_list_name);
}

verbose_print $INFO, "Backup complete.  Performing server-side post-processing.\n";

#Backup complete.  Invoke the post-backup processing
eval {
   %qdb_run = run_remote_script('post_backup');
};

if ($@) {
   die"Error running post-backup finalization steps.\n$@\n";
}

verbose_print $INFO, "Done.  ", $num_files + $num_norot_files , " backed up.\n";

#Delete the temp files containing the file lists
unlink($file_list_name);
unlink($norot_file_list_name);


#Performs the setup of the remote server for password-less SSH authentication
sub do_setup {
   #Determine where to put the key
   my $keyfile = File::Spec->canonpath(File::Spec->catdir(get_home_dir(), ".qdb/qdb_key"));

   #If the key exists, that's one less step
   if (!-e $keyfile || ! -e "$keyfile.pub") {
      if (!-d get_home_dir() ."/.qdb") {
         mkdir get_home_dir() ."/.qdb", 0700;
      }
      #Generate the key
      if (system("ssh-keygen -b 2048 -C \"qdb.pl on " . Net::Domain::hostname ."\" -t rsa -N \"\" -f $keyfile -q")) {
         if ($? == 256) {
            die "Unable to start ssh-keygen.  Is OpenSSH installed correctly?";
         } else {
            die "ssh-keygen failed with exit code $?";
         }
      }

      if (!-e $keyfile || ! -e "$keyfile.pub") {
         die "ssh-keygen ran successfully, but did not produce the expected key files";
      }
   }

   #Read the public key from the file
   open(KEYFILE, "$keyfile.pub") || die "Unable to read key file $keyfile.pub";
   my $key = <KEYFILE>;
   chomp $key;
   close KEYFILE;

   #Build a simple perl script to populate ~/.ssh/authorized_keys with this key
   my $setup_script = File::Spec->canonpath(get_home_dir() ."/qdb_setup.pl");
   open(SETUPSCRIPT, ">$setup_script") || die "Unable to create $setup_script";
   print SETUPSCRIPT <<"EOF"
#!/usr/bin/perl

use File::Path;

\$homedir = \$ENV{'HOME'};
if (!\$homedir) {
   \$homedir = \$ENV{'LOGDIR'};
   if (!\$homedir) {
      \$homedir = \$ENV{'USERPROFILE'};
      if (!\$homedir) {
         \$homedir = (getpwuid($>))[7];
         if (!\$homedir) {
            warn "Can't figure out where your home dir is";
            \$homedir = getcwd();
         }
      }
   }
}

#Create .ssh if it doesn't exist
if (!-d "\$homedir/.ssh") {
   mkdir "\$homedir/.ssh", 0700;
}

#Add the qdb public key for qdb
open(AUTHKEYS, ">>\$homedir/.ssh/authorized_keys") || die "Unable to append to authorized_keys";
print AUTHKEYS "$key\\n";
close AUTHKEYS;

#Make sure the privs are right
chmod 0600, "\$homedir/.ssh/authorized_keys";

print "Your qdb.pl key has been installed successfully.\\n";
EOF
;
   close SETUPSCRIPT;
   chmod 0700, $setup_script;

   #Copy this script up to the remote host
   print "About to SCP a file to $server.  Enter password for $username when prompted.\n";
   if (system("scp -p $setup_script \"$username\@$server:~/qdb_setup.pl\"")) {
      if ($? == 256) {
         die "Failed to invoke scp.  Is OpenSSH installed correctly?";
      } else {
         die "scp failed with exit code $?.  Complete the setup manually.  Copy $setup_script to $server and run it as $username.";
      }
   }

   #Run the script
   print "About to use SSH to run a script on $server.\nEnter password for $username when prompted.\n";
   if (system("ssh $username\@$server perl -w \"~/qdb_setup.pl\"")) {
      if ($? == 256) {
         die "Failed to invoke ssh.  Is OpenSSH installed correctly?";
      } else {
         die "ssh failed with exit code $?.  Complete the setup manually.  Run $setup_script on $server as $username.\n";
      }
   }
}

sub parse_argv {
   verbose_print $DEBUG, "ARGV before parse_argv:\n\t[", join("]\n\t[", @ARGV), "]\n";

   # Parse the command line options.  If something's amiss, 
   #GetOptions will print to stderr and return 0. 
   #Should that happen, display detailed POD info with pod2usage
   GetOptions('argfile=s' => \$argfile,
              'server=s' => \$server,
              'username=s' => \$username,
              'use_rsync' => \$use_rsync,
              'verbose+' => \$verbosity,
              'num_snaps=i' => \$num_snaps,
              'snap_set=s' => \$snap_set,
              'prev_snap_set=s' => \$prev_snap_set,
              'remote_path=s' => \$remote_path,
              'ssh_cmd=s' => \$ssh_cmd,
              'rsync_cmd=s' => \$rsync_cmd,
              'include_filter=s' => \$include_filter,
              'setup' => \$setup,
              'help|?' => \$help) || pod2usage(1);
   
   verbose_print $DEBUG, "ARGV after parse_argv:\n\t[", join("]\n\t[", @ARGV), "]\n";

   if ($help) {
      pod2usage(2);
      exit;
   }
}

#Given the path of a folder on the file system, returns the 
#closest direct ancestor (or the folder itself) that has
#a .qdb file directing backup behavior.
sub getFolder {
   my($folder) = @_;

   verbose_print $DEBUG, "Getting .gdb folder for $folder\n";

   for (;;) {
      verbose_print $DEBUG, "Checking $folder\n";
      if ($backup_paths{$folder}) {
         verbose_print $DEBUG, "Returning $folder\n";
         return $folder;
      }
      #Move to the parent folder.  Normally, using canonpath to cannonicalize
      #the current path with updir() would do the trick, but that doesn't work in at
      #least Cygwin and may other environments.
      my ($vol, $dirs, $file) = File::Spec->splitpath($folder, 1);
      my @dirarray = File::Spec->splitdir($dirs);
      pop @dirarray;

      my $parentFolder = File::Spec->catpath($vol, File::Spec->catdir(@dirarray), $file);

      if ($folder eq $parentFolder) {
         last;
      }

      $folder = $parentFolder;
      verbose_print $DEBUG, "No match found; moving up to $folder\n";
   }

   verbose_print $DEBUG, "Couldn't find any matches, up to $folder\n";

   return;
}

sub wanted {
   # The name of the file is in $_.  Make sure it's
   # .qdb, and if so, load it and run it
   if (-f && /^\.qdb$/) {
      verbose_print $VERBOSE, "Processing file $File::Find::name\n";

      open(QDB, $_) || die "Unable to open QDB file $File::Find::name";

      my %dir;

      my $absPath = File::Spec->canonpath(getcwd);

      $dir{'exclude'} = 0;
      $dir{'name'} = $_;
      $dir{'path'} = $absPath;

      #Find the entry of the closest ancestor of this folder, if any exists, 
      #to more easily build the file list later on.
      $ancestor = getFolder($absPath);
      if ($ancestor) {
         $dir{'ancestor'} = $backup_paths{$ancestor};
      }

      #Slurp the entire contents into a scalar by redefining
      #the newline (held in $/) to be nothing
      for (<QDB>) {
         #If this line doesn't match the name = value syntax, skip it
         next unless /^\s*(.+?)\s*=\s*(.+?)\s*$/;
         my $name = $1;
         my $value = $2;

         $dir{$name} = $value;
      }
      close QDB;

      #If there are any filters defined here, compile them now
      eval {
         buildFilterSub(\%dir, 'excludeFilter');
      };
      if ($@) {
         warn "Error processing excludeFilter in .qdb file for ", $absPath, ": $@\n";
      }

      eval {
         buildFilterSub(\%dir, 'noRotateFilter');
      };
      if ($@) {
         warn "Error processing noRotateFilter in .qdb file for ", $absPath, ": $@\n";
      }

      #The $dir object should've been populated with config info.
      #Stick it in the associative array of paths to backup
      $backup_paths{$absPath} = \%dir;

      verbose_print $DEBUG, "Added dir object for ", $backup_paths{$absPath}{'path'}, "\n";
   }
}

# Checks a hash for the existence of a filter and, if found, 
# parses it into a sub that can be called and will return true
# or false depending upon the successful evaluation of the filter expression
sub buildFilterSub {
   my $dir = shift;
   my $filterName = shift;

   #Generate a unique name for this sub, so it doesn't collide
   #An base64 encoded MD5 hash of the directory containing the filter
   #should do the trick
   my $subName = "filter_sub_" . $filterName . md5_hex($dir->{'path'});
   if (!$dir->{$filterName}) {
      #no filter
      return;
   }

   verbose_print $DEBUG, "Filter sub $filterName for folder ", $dir->{'path'}, " is called $subName\n";

   my $expr = $dir->{$filterName};

   #Undef the filter text.  If the sub compiles successfully, it'll be
   #replaced by a reference to the sub 
   delete $dir->{$filterName};

   $dir->{$filterName} = generateSub($subName, $expr);
}

sub generateSub {
   #Generates and returns a sub reference by constructing a named subroutine from a given
   #expression
   my $subName = shift;
   my $filterExpression = shift;

   #Build a simple sub to wrap the filter expression
   my $sub = "sub $subName { $filterExpression; }"; 

   # The mysterious ".1" at the end is so that if the user code compiles, the whole eval returns true
   # This from Recipe 1.18
   unless (eval $sub . 1) {
      die "Error in filter expresson '$filterExpression': $@\nSubroutine: $sub";
   }

   #If it made it this far, there's a sub, $subName, defined.
   #Save a reference to it
   my $sub_ref;
   eval '$sub_ref = \&' . $subName . ';' || die "Error saving reference to filter: $@";

   return $sub_ref;
}

#Runs a filter subroutine
sub applyFilterSub {
   my $dir = shift;
   my $filterSub = shift;
   my $filterName = shift;
   my $filterResult = 0;

   $filename = shift;
   $filepath = shift;
   $relfilepath = shift;
   $qdb = $dir;

   #Call the filter
   verbose_print $DEBUG, "Applying filter $filterName (", $filterSub, ") in .qdb file for ", $qdb->{'path'}, "\n";
   eval {
      $filterResult = &$filterSub;
   };
   if ($@) {
      warn "Error applying filter $filterName in .qdb file for ", $qdb->{'path'}, ": $@\n";
   }

   undef $filename;
   undef $filepath;
   undef $relfilepath;
   undef $qdb;

   return $filterResult;
}

sub build_lists {
   # Based on the rules specified in the .qdb files 
   # in this folder and parent folders, determine if this
   # file should be included in the backup
   if (! -f) {
      #Only interested in files
      return;
   }

   my $absPath = File::Spec->catfile(File::Spec->canonpath(getcwd), $_);
   my $containingFolder = File::Spec->canonpath(getcwd);

   my $governingQdbFolder = getFolder($containingFolder);
   if (!$governingQdbFolder) {
      warn "Encountered file $File::Find::name not included in a backed-up folder";
      return;
   }

   my %dir = %{$backup_paths{$governingQdbFolder}};

   #Is this dir explicitly excluded?
   if ($dir{'exclude'}) {
      return;
   }

   #Compute the path of this file, relative to the dir containing the governing .qdb file
   #Then evaluate the resultant path against the exclude and no-rotate lists.
   my $relPath = File::Spec->abs2rel($absPath, $dir{"path"});

   #Apply the global include filter
   if (!applyFilterSub(\%dir, $include_filter_sub, 'global include filter', $_, $absPath, $relPath)) {
      return;
   }

   #If present, apply the exclude filter from the governing .qdb file
   if ($dir{'excludeFilter'} && applyFilterSub(\%dir, $dir{'excludeFilter'}, 'excludeFilter', $_, $absPath, $relPath)) {
      return;
   }

   #The file will definitely be included.  The only remaining question is whether
   #it will be included in the normal rotated backup, or the no-rotate backup that
   #replaces any previous copy of the file
   my $norot = 0;

   if ($dir{'noRotateFilter'} && applyFilterSub(\%dir, $dir{'noRotateFilter'}, 'excludeFilter', $_, $absPath, $relPath)) {
      $norot = 1;
   }

   if ($norot) {
      #Write to the norot list
      print $norot_file_list_fh "$absPath\n";
      $num_norot_files++;
   } else {
      print $file_list_fh "$absPath\n";
      $num_files++;
   }
}

#Gets the home directory for the current user
sub get_home_dir {
   #Usually HOME does it.  On Windows its USERPROFILE.  Failing that try .
   if ($ENV{'HOME'}) {
      return $ENV{'HOME'};
   } elsif ($ENV{'USERPROFILE'}) {
      return $ENV{'USERPROFILE'};
   } elsif ((getpwuid($>))[7]) {
      return (getpwuid($>))[7];
   } else {
      warn "Not sure how to get home directory; defaulting to .\n";
      return ".";
   }
}

#Runs the qdb_run.pl script on the remote system.  First it rsync's the
#script up to the server, then it uses SSH to run it.  the script
#communicates results with name=value pairs on stdout.
#
#The script takes a single argument: the name of the subroutine
#within the script to run
sub run_remote_script {
   my $subname = shift;
   my $script = remote_script();
   my $tempdir = File::Temp::tempdir();

   verbose_print $DEBUG, "Running script: \n[$script]\n\n";

   #First, write out the pre-backup script
   my $local_script_path = File::Spec->catfile($tempdir, "qdb_run.pl");
   open(SCRIPTFILE, ">$local_script_path") || die "Error opening $local_script_path for creation";
   print SCRIPTFILE $script;
   close SCRIPTFILE; 
   chmod 0700, $local_script_path;

   #Upload this script to the server using rsync
   my $remote_script_path = File::Spec->catfile("~", "qdb_run.pl");
   rsync_file_up($local_script_path, $remote_script_path);

   #Invoke the script
   my $output = ssh_command("perl -w $remote_script_path $subname");

   verbose_print $DEBUG, "Got this from SSH command: \n$output\n";

   #It's output should be:
   #qdb.pl:
   #Followed by name=value pairs containing results of the run.  If it's not that, 
   #it's probably error output.
   if (! ($output =~ /^qdb.pl:\n/)) {
      die "Error running remote script $remote_script_path on $server.\nOutput of script from $server:\n$output\n";
   }

   #Else, parse the name/value pairs
   my %results;
   for (split(/\n/, $output)) {
      if (/^([^=\s]+)\s*=\s*(.*)$/) {
         #Looks like a name/value pair.  Grab the name and the value
         $results{$1} = $2;
      } else {
         verbose_print $DEBUG, "Skipping qdb_run.pl output line [$_]\n";
      }
   }

   verbose_print $DEBUG, "qdb_run.pl on $server returned:\n";
   for (sort(keys(%results))) {
      verbose_print $DEBUG, "\t$_ = $results{$_}\n";
   }

   return %results;
}

#RSYNC's a file from the local filesystem to a remote system over SSH
sub rsync_file_up {
   my $local = shift;
   my $remote = shift;

   rsync_file($local, "$username\@$server:$remote");
}

#RSYNC's a file from the a remote server to the local filesystem over SSH
sub rsync_file_down {
   my $remote = shift;
   my $local = shift;

   rsync_file("$username\@$server:$remote", $local);
}

#General purpose wrapper around rsync, to rsync from a src to a dest file using ssh
sub rsync_file {
   my $src = shift;
   my $dest = shift;

   #Need to specify a custom SSH command line, to retrieve credentials from identify file
   #and disable prompts
   my $cmd = get_rsync_base_cmd() . " \"$src\" \"$dest\"";
   verbose_print $VERBOSE, "Invoking rsync: [$cmd]\n";
   my $retval = system($cmd);

   if ($retval) {
      #Exited non-zero
      if ($? == 256) {
         die "Failed to execute rsync command [$cmd]\n";
      } else {
         die "rsync command [$cmd] exited with error $?\n";
      }
   }
}

#Runs a command via SSH, returning the output of SSH and the remote command
sub ssh_command {
   my $remote_cmd = shift;

   #Build the command.  If there's a qdb SSH identify file in the home dir, try
   #authenticating with that
   #redirect stderr to stdout so it appears in the result of `` execution.
   my $cmd = "$ssh_cmd -q -A 2>&1";
   #If there's a qdb identity file in ~/.qdb/qdb_key, attempt to authenticate with that
   if (-e get_home_dir() . "/.qdb/qdb_key") {
      $cmd .= " -i " . get_home_dir() . "/.qdb/qdb_key";
   }
   $cmd .= " $username\@$server \"$remote_cmd\"";

   verbose_print $VERBOSE, "Invoking ssh: [$cmd]\n";
   #my $retval = system($cmd);
   my $output = `$cmd`;

   if ($?) {
      #Exited non-zero
      #SSH exits w/ the exit code of the command it ran, so most exit codes
      #reflect failures of the command to be executed, and not SSH itself
      if ($? == 256) {
         die "Failed to execute ssh command [$cmd]\n";
      } elsif ($? == 255) {
         die "ssh command [$cmd] exited with error $?\n";
      }
   }

   return $output;
}

#Does the backup using rsync
sub backup_files {
   my $use_hard_links = shift;
   my $file_list_filename = shift;

   my $cmd = get_rsync_base_cmd();

   #If using hard links, add the --link-dest arg using the previous snapshot 
   #as the source..
   #If there is no previous snapshot, then there's nothing to hard link to
   if ($use_hard_links && $prev_snap) {
      $cmd .= " --link-dest=\"$remote_path/$prev_snap\"";
   }

   $cmd .= " --files-from=\"$file_list_filename\"";

   #Since we're specifying the list of files from a file, the source directory
   #parameter to rsync means the path to which the files listed in the file
   #is relative.  Since the file contains fully-qualified paths, this should be
   #the root, '/', which hopefully works even on Windows.
   $cmd .= " /";

   #The destination is the remote temp folder initially.  After a successful
   #backup, this will be moved to its proper place as the 0th backup
   #in the series.
   $cmd .= " \"$username\@$server:$tmp_remote_path\"";
   
   verbose_print $VERBOSE, "Invoking rsync: [$cmd]\n";
   my $retval = system($cmd);

   if ($retval) {
      #Exited non-zero
      if ($? == 256) {
         die "Failed to execute rsync command [$cmd]\n";
      } else {
         # Error code is in high byte of $?
         my $errcode = $? / 256;

         # 24 is a warning code, indicating that one or more files 'vanished'
         # during backup.  This can happen is the filesystem is modified during
         # a long-running backup, for example when mail is spooled and delivered.
         # Vanished files should not fail the backup
         #
         # 23 is also a warning, reported when one or more files can't be transfered.
         # This happens for a similar reason as 24, and is similarly no reason to kill
         # the backup.
         if ($errcode != 24 && $errcode != 23) {
            die "rsync command [$cmd] exited with error $errcode\n";
         }
      }
   }
}

#Gets the rsync cmd with the optionss that apply to all uses of rsync, either
#uploading the server-side script or doing backups.  Contains stuff like the
#ssh command line.
sub get_rsync_base_cmd {
   #Need to specify a custom SSH command line, to retrieve credentials from identify file
   #and disable prompts
   my $cmd = "$rsync_cmd --links --times -z --rsh=\"$ssh_cmd -q -A";
   #If there's a qdb identity file in ~/.qdb/qdb_key, attempt to authenticate with that
   if (-e get_home_dir() . "/.qdb/qdb_key") {
      $cmd .= " -i " . get_home_dir() . "/.qdb/qdb_key";
   }
   $cmd .= "\"";

   return $cmd;
}

sub verbose_print {
   my $level = shift;

   if ($verbosity >= $level) {
      print @_;
   }
}

sub remote_script {
   #Return a string containing the preback script to run on the server
   return <<"EOF"
#!/usr/bin/perl -w
# Machine-generated helper script to support qdb, the Quick and Dirty Backup
# Do not modify

use File::stat;
use File::Path;
use File::Spec;

\$homedir = \$ENV{'HOME'};
if (!\$homedir) {
   \$homedir = \$ENV{'LOGDIR'};
   if (!\$homedir) {
      \$homedir = \$ENV{'USERPROFILE'};
      if (!\$homedir) {
         \$homedir = (getpwuid($>))[7];
         if (!\$homedir) {
            warn "Can't figure out where your home dir is";
            \$homedir = getcwd();
         }
      }
   }
}

\$prev_snap_set = '$prev_snap_set';
\$dest_folder = '$remote_path';
\$num_snaps = $num_snaps;
\$snap_set = '$snap_set';
\$prev_snap = '$prev_snap';
\$tmp_upload_folder = '$tmp_remote_path';
\$norot_file_list_name = '$norot_file_list_name'; 
\$num_norot_files = '$num_norot_files';

#Expand the ~ placeholder
\$dest_folder =~ s/~/\$homedir/g;
\$tmp_upload_folder =~ s/~/\$homedir/g;

#The first argument to the script is the sub to execute
#The subs all populate the \%results hash
\$subname = shift \@ARGV;

eval "\$subname();";
if (\$\@) {
   die \$\@;
}

#Dump the results to stdout
print "qdb.pl:\\n";
for (sort(keys(\%results))) {
   print "\$_=\$results{\$_}\\n";
}

sub pre_backup {
   #If the dest folder doesn't exist, create it
   if (!-e \$dest_folder) {
      mkdir(\$dest_folder);
   } elsif (! -d \$dest_folder) {
      #Dest exists, but it's a file
      die "\$dest_folder isn't a directory!\\n";
   }

   #If there's a temp folder from a previous failed backup attempt,
   #blow it away
   if (-e \$tmp_upload_folder) {
      rmtree(\$tmp_upload_folder) || die "Unable to delete \$tmp_upload_folder";
   }
   
   #Determine the previous snapshot to use.
   
   #Go over the directories in \$dest_folder to find the most recent series-1
   #snapshot.  If a prev_snap_set has been specified, that's the name of
   #the previous snapshot to use.  That takes priority over the heuristic, if
   #it's not bogus.
   if (!\$prev_snap_set || ! -d File::Spec->catdir("\$dest_folder", "\$prev_snap_set.1")) {
      opendir DESTFOLD, \$dest_folder || die "Failed to open \$dest_folder";

      my \@possibles = readdir(DESTFOLD);
      my \@snapshots = grep{/^[^\\.]+\\.1\$/ && -d "\$dest_folder/\$_"} \@possibles;
      
      closedir DESTFOLD;
      
      my \$last_mtime = 0;
      my \$last_snap = '';
      
      for (\@snapshots) {
         my \$path = File::Spec->catdir("\$dest_folder", "\$_");
      
         #Get the mtime of this folder.
         my \$mtime = (stat(\$path))->mtime;
         if (\$mtime > \$last_mtime) {
            \$last_mtime = \$mtime;
            \$last_snap = \$_;
         }
      }
   
      \$prev_snap = \$last_snap;
   }

   #Include \$prev_snap
   \$results{'prev_snap'} = \$prev_snap;
}

# Cycles the snapshots by renaming  1->2, 2->3, and so on, 
#finally deleting snapshot n, where n is num_snaps.  After that,
#renames tmp_upload_folder to the 1st snapshot.
sub post_backup {
   #If there are any norot files uploaded, delete them from the 
   #previous snapshot.
   if (\$num_norot_files) {
      my \$norot_list_path = File::Spec->catdir(\$tmp_upload_folder, \$norot_file_list_name);
      open(FILELIST, \$norot_list_path) || die "Failed to open norot list file \$norot_list_path\n\n";
      while (<FILELIST>) {
         chomp;
         my \$prev_file_path = File::Spec->catdir(\$dest_folder, \$prev_snap, \$_);
         if (-e \$prev_file_path) {
            unlink(\$prev_file_path);
         }
      }
      close(FILELIST);

      #Delete the norot file list, since it is just a temp file and not part of the backup
      unlink(\$norot_list_path);
   }
   
   #If the maximum number of snapshots have been taken, remove the oldest.
   if (-e File::Spec->catdir(\$dest_folder, "\$snap_set.\$num_snaps")) {
      rmtree(File::Spec->catdir(\$dest_folder, "\$snap_set.\$num_snaps"));
   }

   #For each snapshot down to .1, rename to .2
   my \$idx;
   for (\$idx = \$num_snaps-1; \$idx >= 1; \$idx--) {
      if (-e File::Spec->catdir(\$dest_folder, "\$snap_set.\$idx")) {
         rename (File::Spec->catdir(\$dest_folder, "\$snap_set.\$idx"), File::Spec->catdir(\$dest_folder, "\$snap_set." . (\$idx+1)));
      }
   }

   #Rename the tmpfolder to the 1 element of the set
   rename (\$tmp_upload_folder, File::Spec->catdir(\$dest_folder, "\$snap_set.1"));
}

EOF
;
}

__END__
=head1 NAME

qdb - Quick and Dirty Backup provides easy rsync-based backup functionality

=head1 SYNOPSIS

B<qdb> B<--server> I<servername> B<--user> I<username>  
   [B<--argfile> I<argfile>] 
   [B<--verbose>]
   [B<--num_snaps> I<num_snaps>]
   [B<--snap_set> I<set_name>]
   [B<--prev_snap_set> I<prev_set_name>]
   [B<--remote_path> I<remote_path>]
   [B<--ssh_cmd> I<ssh_cmd>]
   [B<--rsync_cmd> I<rsync_cmd>]
   [B<--include_filter> I<include_filter]>
   I<path1> [
   I<path2> 
   [I<pathN>] ]

=head1 DESCRIPTION

qdb implements a Quick and Dirty Backup to a remote server using rsync.  It uses a .qdb
file located in the folder(s) to be backed up, which controls how that folder and its
children will be rsync'd.  This has the distinct advantage of keeping backup information
close to the folder it pertains to.

The rsync-based backup uses hard links to create multiple snapshots of the backup files at different
points in time, without excessive disk usage.

=head1 OPTIONS

=over

=item B<--server I<servername>> 

Specifies the server to back up to.
   
=item B<--user I<username>> 

Specifies the username to connect to the server as.
   
=item B<--argfile I<argfile>>

Loads arguments from a file.  Each non-whitespace line is assumed to be the text of
a single option or argument on the command line.  

For example:

   --server whatever
   /home
   /var
   /tmp

=item B<--verbose>

Increases the verbosity of the output.  Use twice for extra verbosity; three times
for debug verbosity.

=item B<--num_snaps I<num_snaps>>

Sets the number of snapshots to keep before deleting the oldest.  The default is 10
snapshots.  NB: This limit applies to the current snapshot set only; other snapshot
sets may be used with other limits.  See B<--snap_set>.

=item B<--snap_set I<set_name>>

The base name of the snapshot set to backup to.  By default set to 'qdb'.  Snapshots
will be created of the form I<set_name>.I<snap_num>, where I<snap_num> is the one-based
number of the snapshot, with 1 being the most recent.

=item B<--prev_snap_set I<prev_set_name>>

The name of the snapshot set to compare with for the purposes of the differential
backup.  By default qdb uses the most recent snapshot in the remote path, regardless 
of the snap set to which it belongs.  By setting this to the name of a specific
snap set, qdb will use I<prev_set_name>.1 as the previous snap set, creating hard
links from there to I<set_name>.1 for files that have not changed.

=item B<--remote_path I<remote_path>>

The path on the remote machine where backups should be placed.  By default, ~/I<machine_name>
is used.

=item B<--ssh_cmd I<ssh_cmd>>

The command to use to invoke SSH.  Do not include the username or server name;
these will be appended automatically.

=item B<--rsync_cmd I<rsync_cmd>>

The command to use to invoke rsync.  Do not include the username or server name;
these will be appended automatically.

=item B<--include_filter I<include_filter>>

Specifies a perl expression of the same form as the include and exclude filters
in the .qdb files, which must evaluate to true for any file on the paths to be 
considered for inclusion in the backup.  The criteria become:
   Global include filter == true
   .qdb exclude fitler == false
   
=item B<path> 

Specifies a path to search for .qdb files.  If no paths are specified, the current directory
is searched.  Multiple (potentially overlapping) paths may be specified.  These paths aren't
necessarily backed up; that depends on the .qdb files stored therein.  However, these paths are searched
for .qdb files recursively.

=back

=cut

