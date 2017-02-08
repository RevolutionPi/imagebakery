#!/bin/sh
# shrink raspbian image to fit on the eMMC of a CM1 or CM3

if [ "$#" != 2 ] ; then
	echo 1>&1 "Usage: `basename $0` <source> <destination>"
	exit
fi

set -ex

# mount source ext4 filesystem
losetup /dev/loop0 $1
partprobe /dev/loop0
mkdir /tmp/src.$$
mount /dev/loop0p2 /tmp/src.$$

# truncate files in wolfram-engine package to release 660 MBytes
set +x
dpkg --root /tmp/src.$$ -L wolfram-engine |
	while read name ; do
		if [ -f "/tmp/src.$$/$name" ] ; then
			> "/tmp/src.$$/$name"
		fi
	done
set -x

# create destination image, the eMCC on CM1 and CM3 has 7634944 sectors
dd if=/dev/zero of=$2 conv=sparse count=7634944

# copy partition table and FAT partition, the ext4 partition starts at 137216
dd if=$1 of=$2 conv=notrunc count=137215

# shrink ext4 partition to end at 7634944 minus 1
#sfdisk --delete $2 2 # requires util-linux 2.28
sfdisk --dump $2 | egrep -v '(type|Id)=83$' | sfdisk $2
parted $2 mkpart primary ext4 137216s 7634943s
partx $2

# mount destination ext4 filesystem
losetup /dev/loop1 $2
partprobe /dev/loop1
mkfs.ext4 /dev/loop1p2
mkdir /tmp/dest.$$
mount /dev/loop1p2 /tmp/dest.$$

# copy contents of ext4 filesystem, this is more space efficient than resize2fs
cp -pr /tmp/src.$$/* /tmp/dest.$$

# clean up
umount /tmp/src.$$
delpart /dev/loop0 1
delpart /dev/loop0 2
losetup -d /dev/loop0
rmdir /tmp/src.$$
umount /tmp/dest.$$
delpart /dev/loop1 1
delpart /dev/loop1 2
losetup -d /dev/loop1
rmdir /tmp/dest.$$
