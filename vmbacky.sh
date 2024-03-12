#!/bin/bash

SOURCEPOOL="libvirt-data"
SOURCEPOOL2="libvirt-ssd"

function initial_backup {
    # call: initial_backup rbd vm1
    POOL="$1"
    VM="$2"

    SNAPNAME=$(date "+%Y-%m-%dT%H:%M:%S")  # 2017-04-19T11:33:23
    TEMPFILE=$(tempfile)

    echo "Performing initial backup of $POOL/$VM."

    rbd snap create "$POOL"/"$VM"@"$SNAPNAME"
    rbd diff --whole-object "$POOL"/"$VM"@"$SNAPNAME" --format=json > "$TEMPFILE"
    backy2 backup -s "$SNAPNAME" -r "$TEMPFILE" rbd://"$POOL"/"$VM"@"$SNAPNAME" $VM

    rm $TEMPFILE
}

function differential_backup {
    # call: differential_backup rbd vm1 old_rbd_snap old_backy2_version
    POOL="$1"
    VM="$2"
    LAST_RBD_SNAP="$3"
    BACKY_SNAP_VERSION_UID="$4"

    SNAPNAME=$(date "+%Y-%m-%dT%H:%M:%S")  # 2017-04-20T11:33:23
    TEMPFILE=$(tempfile)

    echo "Performing differential backup of $POOL/$VM from rbd snapshot $LAST_RBD_SNAP and backy2 version $BACKY_SNAP_VERSION_UID."

    rbd snap create "$POOL"/"$VM"@"$SNAPNAME"
    rbd diff --whole-object "$POOL"/"$VM"@"$SNAPNAME" --from-snap "$LAST_RBD_SNAP" --format=json > "$TEMPFILE"
    # delete old snapshot
    rbd snap rm "$POOL"/"$VM"@"$LAST_RBD_SNAP"
    # and backup
    backy2 backup -s "$SNAPNAME" -r "$TEMPFILE" -f "$BACKY_SNAP_VERSION_UID" rbd://"$POOL"/"$VM"@"$SNAPNAME" "$VM"
}

function backup {
    # call as backup rbd vm1
    POOL="$1"
    VM="$2"

    # find the latest snapshot name from rbd
    LAST_RBD_SNAP=$(rbd snap ls "$POOL"/"$VM"|tail -n +2|awk '{ print $2 }'|sort|tail -n1)
    if [ -z $LAST_RBD_SNAP ]; then
        echo "No previous snapshot found, reverting to initial backup."
        initial_backup "$POOL" "$VM"
    else
        # check if this snapshot exists in backy2
        BACKY_SNAP_VERSION_UID=$(backy2 -ms ls -s "$LAST_RBD_SNAP" "$VM"|awk -F '|' '{ print $6 }')
        if [ -z $BACKY_SNAP_VERSION_UID ]; then
            echo "Existing rbd snapshot not found in backy2, reverting to initial backup."
            initial_backup "$POOL" "$VM"
        else
            differential_backup "$POOL" "$VM" "$LAST_RBD_SNAP" "$BACKY_SNAP_VERSION_UID"
        fi
    fi
}

for image in $(rbd ls $SOURCEPOOL)
do
	backup "$SOURCEPOOL" "$image"
done
date

for image in $(rbd ls $SOURCEPOOL2)
do
	backup "$SOURCEPOOL2" "$image"
done
date

echo Housekeeping
for backup in `backy2 -ms ls -f name,snapshot_name,uid,tags |grep -i b_daily | grep -iv b_weekly | grep -iv b_monthly`
do
        a=`echo $backup | cut -d "|" -f 1`
        date=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 1`
	time=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 2`
        uid=`echo $backup | cut -d "|" -f 3`
        expire="`date +%Y-%m-%d -d \"$date+8 days\"`T$time"
        echo "$a -- $date -- $uid -- $expire"
	backy2 expire $uid $expire
done

for backup in `backy2 -ms ls -f name,snapshot_name,uid,tags |grep -i b_weekly | grep -iv b_monthly`
do
        a=`echo $backup | cut -d "|" -f 1`
        date=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 1`
	time=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 2`
        uid=`echo $backup | cut -d "|" -f 3`
        expire="`date +%Y-%m-%d -d \"$date+1 month\"`T$time"
        echo "$a -- $date -- $uid -- $expire"
	backy2 expire $uid $expire
done

for backup in `backy2 -ms ls -f name,snapshot_name,uid,tags |grep -i b_monthly`
do
	a=`echo $backup | cut -d "|" -f 1`
	date=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 1`
	time=`echo $backup | cut -d "|" -f 2 | cut -d "T" -f 2`
	uid=`echo $backup | cut -d "|" -f 3`
	expire="`date +%Y-%m-%d -d \"$date+3 months\"`T$time"
	echo "$a -- $date -- $uid -- $expire"
	backy2 expire $uid $expire
done
for version in `backy2 -ms ls -e -f uid`
do
	backy2 rm $version
done

date

backy2 cleanup

mkdir /cephfs/vmbacky-pg/.snap/snap
rsync -aHhXxS --delete /cephfs/vmbacky-pg/.snap/snap/ /mnt/vmbackup/postgres/
rmdir /cephfs/vmbacky-pg/.snap/snap

date
echo Job ended.
