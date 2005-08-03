#!/usr/bin/perl

use File::Path;

#Create .ssh if it doesn't exist
if (!-d "~/.ssh") {
   mkdir "~/.ssh", 0700;
}

#Add the qdb public key for qdb
open AUTHKEYS, ">>~/.ssh/authorized_keys" || die "Unable to append to authorized_keys";
print AUTHKEYS "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAtpZ3kBS7mycdk4UHga5/33XYbxXGUqzI27nzbNJMoK+U2L4n2I+b9gMJaUos+LCNPwYgbXQircie/RpfOh62xtnbe1UcdxxvFm70NYHh5aO/a0yd0X8rTGHNuuH+G+J7yciAo4yeBTr5bIj3ZxzYOs42svafKBIusf4/VrV65118jUxcTHRpENjX6PAamPkg8P428KgExQdUm7uT3f7brvQB3865EZM1tVIDYP2Nk5vjoJ8nzQMYBy6cBnOBs0A+2GxABiBoS1Q6GmLZGnIrUCx2Ln+lN7+Md/vh4ohM2DLdbxi/k7xFT3apeqPSZRpOHHzl3IKjf0rihb/frJfE3w== qdb.pl on prospertine
";
close AUTHKEYS;

#Make sure the privs are right
chmod 0600, "~/.ssh/authorized_keys";

print "Your qdb.pl key has been installed successfully.
";
