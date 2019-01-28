#!/bin/sh
# resize raspbian image to fit on the eMMC of a CM1 or CM3

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

# create destination image, the eMMC on CM1 and CM3 has 7634944 sectors
dd if=/dev/zero of=$2 conv=sparse count=7634944

# determine end sector of FAT partition (usually 93236)
FAT_END_SECTOR=$(sfdisk --dump $1 | awk '/start=/ {print $4 + $6 - 1; exit}')

# copy partition table and FAT partition
dd if=$1 of=$2 conv=notrunc count=$FAT_END_SECTOR

# determine start sector of ext4 partition (usually 94208)
EXT4_START_SECTOR=$(sfdisk --dump $1 | awk -F '[ ,]+' '/start=.*(type|Id)=83/ {print $4}')

# calculate size of ext4 partition (usually 7634944 - 94208 = 7542784)
EXT4_SIZE=$((7634944 - $EXT4_START_SECTOR))

# resize ext4 partition to calculated size
sfdisk --dump $2 | sed -r "/(type|Id)=83\$/s/size=[^,]+/size=$EXT4_SIZE/" |
	sfdisk -f $2
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
