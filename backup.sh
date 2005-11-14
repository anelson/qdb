#!/bin/sh

BACKUP_FOLDER=/usr/local/backup;
QDB_PATH=$BACKUP_FOLDER/qdb.pl;
FETCH=/usr/bin/fetch;
RSYNC=/usr/local/bin/rsync;

# Run the pre-backup steps 
$BACKUP_FOLDER/before_backup.sh;

# Backups bonzo after getting latest qdb.pl
if (test -e $QDB_PATH) then 
	rm $QDB_PATH
fi;

$FETCH -o $QDB_PATH http://bonzo.celatrix.com/svn/projects/QuickDirtyBack/trunk/qdb.pl
chmod 0700 $QDB_PATH

$QDB_PATH --server jane --username bonzo_backup --rsync_cmd $RSYNC /

