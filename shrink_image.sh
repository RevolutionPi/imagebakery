#!/bin/bash

# SPDX-FileCopyrightText: 2022-2024 KUNBUS GmbH
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Shrink an existing image for Revolution Pi

usage () {
	echo 'Usage: install_debs_into_image.sh [-h, -i, --help] <image>
	-h, --help		Print the usage page'
}

if [ ! -x "$(which fsck.vfat)" ]; then
	echo 1>&2 "Error: Command fsck.vfat not found."
	exit 1
fi

if [ ! -x "$(which lsof)" ]; then
	exit 1
fi

PARTED="$(which parted)"
if [ "x$PARTED" = "x" ] ; then
	echo 1>&2 "Error: Command parted not found."
	exit 1
fi

if [ ! -x "$PARTED" ] ; then
	echo 1>&2 "Error: Command $PARTED is not executable."
	exit 1
fi

set -e

# pivot to new PID namespace
if [ $$ != 2 ] && [ -x /usr/bin/newpid ] ; then
	exec /usr/bin/newpid "$0" "$@"
fi

# get the options
if ! MYOPTS=$(getopt -o h --long help -- "$@"); then
	usage
	exit 1
fi
eval set -- "$MYOPTS"

# extract options and their arguments into variables.
while true ; do
	case "$1" in
		-h|--help) usage ; exit 0;;
		*) shift; break ;;
	esac
done

IMAGEDIR=`mktemp -d -p /tmp img.XXXXXXXX`
LOOPDEVICE=$(losetup -f)

cleanup_umount() {
	if [ -e "$IMAGEDIR" ] ; then
		lsof -t "$IMAGEDIR" | xargs --no-run-if-empty kill
	fi
	if mountpoint -q "$IMAGEDIR" ; then
		umount "$IMAGEDIR"
	fi
	if [ -d "$IMAGEDIR" ] ; then
		rmdir "$IMAGEDIR"
	fi
}

cleanup_losetup() {
	if [ -e "$LOOPDEVICE"p1 ] ; then
		delpart "$LOOPDEVICE" 1
	fi
	if [ -e "$LOOPDEVICE"p2 ] ; then
		delpart "$LOOPDEVICE" 2
	fi
	if losetup "$LOOPDEVICE" 2>/dev/null ; then
		losetup -d "$LOOPDEVICE"
	fi
}

cleanup() {
	cleanup_umount
	cleanup_losetup
}

trap cleanup ERR SIGINT

# mount ext4 + FAT filesystems
losetup "$LOOPDEVICE" "$1"
partprobe "$LOOPDEVICE"

# Remove machine-id to trigger firstboot.service to increase file system
# on first boot of the new flashed device.
echo "Mounting image to check machine-id"
mount "$LOOPDEVICE"p2 "$IMAGEDIR"
if [ -f "$IMAGEDIR/etc/machine-id" ]; then
	echo "Removing machine-id to trigger firstboot.service"
	rm -f "$IMAGEDIR/etc/machine-id"
fi
sleep 2

cleanup_umount

fsck.ext4 -f -p "$LOOPDEVICE"p2
sleep 2

# shrink image to speed up flashing
resize2fs -M "$LOOPDEVICE"p2
PARTSIZE=$(dumpe2fs -h "$LOOPDEVICE"p2 | egrep "^Block count:" | cut -d" " -f3-)
PARTSIZE=$((($PARTSIZE) * 8))   # ext4 uses 4k blocks, partitions use 512 bytes
PARTSTART=$(cat /sys/block/$(basename "$LOOPDEVICE")/$(basename "$LOOPDEVICE"p2)/start)
echo Yes | $PARTED ---pretend-input-tty "$LOOPDEVICE" resizepart 2 "$(($PARTSTART+$PARTSIZE-1))"s
cleanup_losetup
truncate -s $((512 * ($PARTSTART + $PARTSIZE))) "$1"
