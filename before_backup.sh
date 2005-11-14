#!/bin/sh

# Run before the file system backup, to prepare any data for backing up

# Dump the MySQL databases to a file
/usr/local/bin/mysqldump -uroot -pguess --all-databases --lock-all-tables > /usr/local/backup/mysqldump.sql

# Dump the Subversion repository to a file
/usr/local/bin/svnadmin dump /usr/local/apocryph_svn > /usr/local/backup/svndump
