#!/bin/sh
# shrink raspbian image to fit on the eMMC of a CM1 or CM3

if [ "$#" != 2 ] ; then
	echo 1>&1 "Usage: `basename $0` <source> <destination>"
	exit
fi

set -ex

SRC_LOOP_DEV=$(losetup -f)
# mount source ext4 filesystem
losetup "$SRC_LOOP_DEV" $1
partprobe "$SRC_LOOP_DEV"
mkdir /tmp/src.$$
mount "$SRC_LOOP_DEV"p2 /tmp/src.$$

# truncate files in wolfram-engine package to release 660 MBytes
set +x
dpkg --root /tmp/src.$$ -L wolfram-engine |
	while read name ; do
		if [ -f "/tmp/src.$$/$name" ] ; then
			> "/tmp/src.$$/$name"
		fi
	done
set -x

# create destination image, the eMMC on CM1 and CM3 has 7634944 sectors
dd if=/dev/zero of=$2 conv=sparse count=7634944

# copy partition table and FAT partition, the ext4 partition starts at 137216
dd if=$1 of=$2 conv=notrunc count=137215

# shrink ext4 partition to 7497728 sectors (= 7634944 - 137216)
sfdisk --dump $2 | sed -r '/(type|Id)=83$/s/size=[^,]+/size=7497728/' |
	sfdisk $2
partx $2

DEST_LOOP_DEV=$(losetup -f)
# mount destination ext4 filesystem
losetup "$DEST_LOOP_DEV" $2
partprobe "$DEST_LOOP_DEV"
mkfs.ext4 "$DEST_LOOP_DEV"p2
mkdir /tmp/dest.$$
mount "$DEST_LOOP_DEV"p2 /tmp/dest.$$

# copy contents of ext4 filesystem, this is more space efficient than resize2fs
cp -pr /tmp/src.$$/* /tmp/dest.$$

# clean up
umount /tmp/src.$$
delpart "$SRC_LOOP_DEV" 1
delpart "$SRC_LOOP_DEV" 2
losetup -d "$SRC_LOOP_DEV"
rmdir /tmp/src.$$
umount /tmp/dest.$$
delpart "$DEST_LOOP_DEV" 1
delpart "$DEST_LOOP_DEV" 2
losetup -d "$DEST_LOOP_DEV"
rmdir /tmp/dest.$$
