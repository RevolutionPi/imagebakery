#!/bin/bash
# Customize packages of an existing image for Revolution Pi

usage () {
	echo 'Usage: install_debs_into_image.sh [-h, --help] <image>
  -h, --help		Print the usage page'
}

if [ ! -x "$(which fsck.vfat)" ]; then
	echo 1>&1 "Error: Command fsck.vfat not found."
	exit 1
fi

if [ ! -x "$(which lsof)" ]; then
	echo 1>&1 "Error: Command lsof not found."
	exit 1
fi

PARTED="$(which parted)"
if [ "x$PARTED" = "x" ] ; then
	echo 1>&1 "Error: Command parted not found."
	exit 1
fi

if [ ! -x "$PARTED" ] ; then
	echo 1>&1 "Error: Command $PARTED is not executable."
	exit 1
fi

set -e

# pivot to new PID namespace
if [ $$ != 2 ] && [ -x /usr/bin/newpid ] ; then
	exec /usr/bin/newpid "$0" "$@"
fi


# get the options
if ! MYOPTS=$(getopt -o mh --long minimize,help -- "$@"); then
	usage;
	exit 1;
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
BAKERYDIR=$(dirname "$0")
LOOPDEVICE=$(losetup -f)

cleanup_umount() {
	if [ -e "$IMAGEDIR" ] ; then
		lsof -t "$IMAGEDIR" | xargs --no-run-if-empty kill
	fi
	if [ -e "$IMAGEDIR/usr/bin/qemu-arm-static" ] ; then
		rm -f "$IMAGEDIR/usr/bin/qemu-arm-static"
	fi
	if mountpoint -q "$IMAGEDIR/tmp/debs-to-install" ; then
		umount "$IMAGEDIR/tmp/debs-to-install"
	fi
	if [ -e "$IMAGEDIR/tmp/debs-to-install" ] ; then
		rmdir "$IMAGEDIR/tmp/debs-to-install"
	fi
	if mountpoint -q "$IMAGEDIR/boot" ; then
		umount "$IMAGEDIR/boot"
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

# Block size is 512 bytes
blocksize=512
# Minimal eMMC size is 4 GB with an available disk size of 3909091328 bytes
disksize=3909091328
imgblocks=$(/sbin/blockdev --getsz "$1")
[ "$imgblocks" = "" ] && echo 1>&1 "Error: Cannot get image size" && exit 1
imgsize=$((imgblocks * blocksize))

# The smallest size of CM3-eMMC is 4 GB  , the available disksize for a system is 3909091328 bytes
# An image like raspios-lite just have 2 GB , so we need to resize rootfs first before
# we start processing the image. Otherwise build will fail with "no space left on device"
if [ "$imgsize" -lt 3900000000 ] ; then
	bcount=$(((disksize-imgsize)/blocksize))
	dd if=/dev/zero count=$bcount bs=$blocksize status=progress >> "$1"
	$PARTED "$1" resizepart 2 "$((disksize-1))"B
	losetup "$LOOPDEVICE" "$1"
	partprobe "$LOOPDEVICE"
	resize2fs "$LOOPDEVICE"p2
	e2fsck -p -f "$LOOPDEVICE"p2
	sync
	losetup -D
fi

# mount ext4 + FAT filesystems
losetup "$LOOPDEVICE" "$1"
partprobe "$LOOPDEVICE"
mount "$LOOPDEVICE"p2 "$IMAGEDIR"
mount "$LOOPDEVICE"p1 "$IMAGEDIR/boot"

# see https://wiki.debian.org/QemuUserEmulation
if [ -e /usr/bin/qemu-arm-static ] ; then
	cp /usr/bin/qemu-arm-static "$IMAGEDIR/usr/bin"
fi

# Move ld.so.preload until installation is finished. Otherwise we get errors
# from ld.so:
#   ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so'
#   from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
[[ -f "$IMAGEDIR/etc/ld.so.preload" ]] && mv "$IMAGEDIR/etc/ld.so.preload" "$IMAGEDIR/etc/ld.so.preload.bak"

# customize settings
echo `basename "$1"` > "$IMAGEDIR/etc/revpi/image-release"

chroot "$IMAGEDIR" apt-get update
chroot "$IMAGEDIR" apt-get -y install `egrep -v '^#' "$BAKERYDIR/debs-to-download"`
# remove package lists, they will be outdated within days
rm "$IMAGEDIR/var/lib/apt/lists/"*Packages

# install local packages
if [ "$(/bin/ls "$BAKERYDIR/debs-to-install/"*.deb 2>/dev/null)" ] ; then
	mkdir "$IMAGEDIR/tmp/debs-to-install"
	mount --bind "$BAKERYDIR/debs-to-install" "$IMAGEDIR/tmp/debs-to-install"
	chroot "$IMAGEDIR" sh -c "dpkg -i /tmp/debs-to-install/*.deb"
fi

# remove logs and ssh host keys
find "$IMAGEDIR/var/log" -type f -delete
find "$IMAGEDIR/etc/ssh" -name "ssh_host_*_key*" -delete

# restore ld.so.preload
[[ -f "$IMAGEDIR/etc/ld.so.preload.bak" ]] && mv "$IMAGEDIR/etc/ld.so.preload.bak" "$IMAGEDIR/etc/ld.so.preload"

cleanup_umount

fsck.vfat -a "$LOOPDEVICE"p1
sleep 2
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
