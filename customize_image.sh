#!/bin/bash
# customize raspbian image for revolution pi

usage () {
	echo 'Usage: customize_image.sh [-m, --minimize | -h, --help] <source-image> [<target-image>]
  -m, --minimize	Install only software that is necessary for basic operation (eg. Pictory and other RevPi tools)
  -f, --force		Force in-place modification of the source image if not output image was specfied
  -v, --verbose		Print all executed commands to the terminal (for debugging purposes)
  -h, --help		Print the usage page'
}

if [ ! -x "$(which curl)" ]; then
	echo 1>&1 "Error: Command curl not found."
	exit 1
fi

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

# set MINIMG as 0: build the normal image by default
MINIMG=0
FORCE=0

# get the options
if ! MYOPTS=$(getopt -o mfvh --long minimize,force,verbose,help -- "$@"); then
	usage;
	exit 1;
fi
eval set -- "$MYOPTS"

# extract options and their arguments into variables.
while true ; do
	case "$1" in
		-m|--minimize) MINIMG=1 ; shift ;;
		-f|--force) FORCE=1 ; shift ;;
  		-v|--verbose) set -ex ; shift ;;
		-h|--help) usage ; exit 0;;
		*) shift; break ;;
	esac
done

SOURCE_IMAGE=$1
OUTPUT_IMAGE=${2:-$1}

if [ "$SOURCE_IMAGE" == "$OUTPUT_IMAGE" ]; then
	echo "WARNING: No name for the output image was specified. The source image will be modfied in-place."

	if [ $FORCE -eq 0 ]; then
		echo ""
		echo -n "Do you want to continue? [Ny] "
		read -r choice

		if ! [[ "$choice" == "y" || "$choice" == "Y" ]]; then
			exit
		fi
	fi
else
	echo "Copying source image to ${OUTPUT_IMAGE}. This can take a while ..."
	cp "$SOURCE_IMAGE" "$OUTPUT_IMAGE"
fi

if [ "$MINIMG" != "1" ]; then
	echo "All additional applications will be built into the given image."
else
	echo "Only a reduced application set will be built into the given image."
fi

IMAGEDIR=`mktemp -d -p /tmp img.XXXXXXXX`
BAKERYDIR=$(dirname "$0")
LOOPDEVICE=$(losetup -f)

cleanup_umount() {
	if [ -e "$IMAGEDIR" ] ; then
		lsof -t "$IMAGEDIR" | xargs --no-run-if-empty kill
	fi
	if [ -e "$IMAGEDIR/etc/resolv.conf" ] ; then
		umount "$IMAGEDIR/etc/resolv.conf"
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

cleanup_with_error() {
    echo "#################### BUILD PROCESS INCOMPLETE ####################"
    cleanup
}

trap cleanup_with_error ERR SIGINT

# Block size is 512 bytes
blocksize=512
# Minimal eMMC size is 4 GB with an available disk size of 3909091328 bytes
disksize=3909091328
imgblocks=$(/sbin/blockdev --getsz "$OUTPUT_IMAGE")
[ "$imgblocks" = "" ] && echo 1>&1 "Error: Cannot get image size" && exit 1
imgsize=$((imgblocks * blocksize))

# The smallest size of CM3-eMMC is 4 GB  , the available disksize for a system is 3909091328 bytes
# An image like raspios-lite just have 2 GB , so we need to resize rootfs first before
# we start processing the image. Otherwise build will fail with "no space left on device"
if [ "$imgsize" -lt 3900000000 ] ; then
    echo "Partition is being expanded for installation... This may take a while!"
	bcount=$(((disksize-imgsize)/blocksize))
	dd if=/dev/zero count=$bcount bs=$blocksize status=progress >> "$OUTPUT_IMAGE"
	$PARTED "$OUTPUT_IMAGE" resizepart 2 "$((disksize-1))"B
	losetup "$LOOPDEVICE" "$OUTPUT_IMAGE"
	partprobe "$LOOPDEVICE"
	resize2fs "$LOOPDEVICE"p2
	e2fsck -p -f "$LOOPDEVICE"p2
	sync
	losetup -D
fi

# mount ext4 + FAT filesystems
losetup "$LOOPDEVICE" "$OUTPUT_IMAGE"
partprobe "$LOOPDEVICE"
mount "$LOOPDEVICE"p2 "$IMAGEDIR"
mount "$LOOPDEVICE"p1 "$IMAGEDIR/boot"
mount --bind /etc/resolv.conf "$IMAGEDIR/etc/resolv.conf"

# see https://wiki.debian.org/QemuUserEmulation
if [ -e /usr/bin/qemu-arm-static ] ; then
	cp /usr/bin/qemu-arm-static "$IMAGEDIR/usr/bin"
fi

# copy templates
cp "$BAKERYDIR/templates/config.txt" "$IMAGEDIR/boot"
cp "$BAKERYDIR/templates/cmdline.txt" "$IMAGEDIR/boot"
cp "$BAKERYDIR/templates/revpi-aliases.sh" "$IMAGEDIR/etc/profile.d"
cp "$BAKERYDIR/templates/rsyslog.conf" "$IMAGEDIR/etc"

# dwc_otg is broken on 64-bit and shows a kernel panic on newer Cores and Connects
# prevent this by using dwc2 also for CM3 based devices
if [ -e "$IMAGEDIR/boot/kernel8.img" ]; then
	sed -i '/^\[all\]/a dtoverlay=dwc2,dr_mode=host' "$IMAGEDIR/boot/config.txt"
fi

# limit disk space occupied by logs
ln -s ../cron.daily/logrotate "$IMAGEDIR/etc/cron.hourly"
sed -r -i -e 's/delaycompress/#delaycompress/' \
	  -e 's/sharedscripts/#sharedscripts/' \
	  "$IMAGEDIR/etc/logrotate.d/rsyslog"
sed -r -i -e 's/#compress/compress/' -e '2i \
\
# limit size of each log file\
maxsize 10M\
\
# compress harder\
compresscmd /usr/bin/nice\
compressoptions /usr/bin/xz\
compressext .xz\
uncompresscmd /usr/bin/unxz\
' "$IMAGEDIR"/etc/logrotate.conf

# bootstrap apt source, will be overwritten by revpi-repo package
cp "$BAKERYDIR/templates/revpi.gpg" "$IMAGEDIR/etc/apt/trusted.gpg.d"
cp "$BAKERYDIR/templates/revpi.list" "$IMAGEDIR/etc/apt/sources.list.d"

# Move ld.so.preload until installation is finished. Otherwise we get errors
# from ld.so:
#   ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so'
#   from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
[[ -f "$IMAGEDIR/etc/ld.so.preload" ]] && mv "$IMAGEDIR/etc/ld.so.preload" "$IMAGEDIR/etc/ld.so.preload.bak"

# copy piTest source code
PITESTDIR=`mktemp -d -p /tmp pitest.XXXXXXXX`
git clone --recursive https://github.com/RevolutionPi/revpi-pitest $PITESTDIR
mkdir -p "$IMAGEDIR/home/pi/demo"
mv $PITESTDIR "$IMAGEDIR/home/pi/demo/piTest"
chown -R 1000:1000 "$IMAGEDIR/home/pi/demo"
chmod -R a+rX "$IMAGEDIR/home/pi/demo"

# remove bookshelf if present
if [[ -d $IMAGEDIR/home/pi/Bookshelf ]]; then
    rm -r $IMAGEDIR/home/pi/Bookshelf
fi

# customize settings
echo UTC > "$IMAGEDIR/etc/timezone"
rm "$IMAGEDIR/etc/localtime"
echo RevPi > "$IMAGEDIR/etc/hostname"
sed -i -e 's/raspberrypi/RevPi/g' "$IMAGEDIR/etc/hosts"
if ! grep -qE '^i2c-dev$' "$IMAGEDIR/etc/modules" ; then
	echo i2c-dev >> "$IMAGEDIR/etc/modules"
fi
echo piControl >> "$IMAGEDIR/etc/modules"
sed -i -r -e 's/^(XKBMODEL).*/\1="pc104"/' \
	-e 's/^(XKBLAYOUT).*/\1="us"/' \
	-e 's/^(XKBVARIANT).*/\1=""/' \
	  "$IMAGEDIR/etc/default/keyboard"
sed -i -r -e 's/^(LANG).*/\1="en_US.UTF-8"/' "$IMAGEDIR/etc/default/locale"
sed -i -r -e 's/^(# en_US.UTF-8 UTF-8)/en_US.UTF-8 UTF-8/' "$IMAGEDIR/etc/locale.gen"
sed -i -r -e 's/^(en_GB.UTF-8 UTF-8)/# en_GB.UTF-8 UTF-8/' "$IMAGEDIR/etc/locale.gen"
install -d -m 755 -o root -g root "$IMAGEDIR/etc/revpi"
basename "$OUTPUT_IMAGE" > "$IMAGEDIR/etc/revpi/image-release"

# activate settings
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive keyboard-configuration
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive tzdata
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive locales

# automatically bring up eth0 and eth1 again after a USB bus reset
sed -i -e '6i# allow-hotplug eth0\n# allow-hotplug eth1\n' "$IMAGEDIR/etc/network/interfaces"

# harden network configuration
chroot "$IMAGEDIR" /usr/bin/patch /etc/sysctl.conf	\
	< "$BAKERYDIR/templates/sysctl.conf.patch"

# display IP address at login prompt
sed -i -e '1s/$/ \\4 \\6/' "$IMAGEDIR/etc/issue"

# free up disk space
dpkg --root "$IMAGEDIR" --purge `egrep -v '^#' "$BAKERYDIR/debs-to-remove"`
chroot "$IMAGEDIR" apt-get -y autoremove --purge
rm -rf "$IMAGEDIR/home/pi/MagPi"

# avoid installing unnecessary packages on this space-constrained machine
echo 'APT::Install-Recommends "false";' >> "$IMAGEDIR/etc/apt/apt.conf"

# download and install missing packages
chroot "$IMAGEDIR" apt-get update --allow-releaseinfo-change -y

chroot "$IMAGEDIR" apt-get -y install `egrep -v '^#' "$BAKERYDIR/min-debs-to-download"`
if [ "$MINIMG" != "1" ]; then
	chroot "$IMAGEDIR" apt-get -y install `egrep -v '^#' "$BAKERYDIR/debs-to-download"`
fi
dpkg --root "$IMAGEDIR" --force-depends --purge rpd-wallpaper
chroot "$IMAGEDIR" apt-get -y install revpi-wallpaper
chroot "$IMAGEDIR" apt-mark hold raspi-copies-and-fills
chroot "$IMAGEDIR" apt-get -y upgrade
chroot "$IMAGEDIR" apt-mark unhold raspi-copies-and-fills

if [ -e "$IMAGEDIR/etc/init.d/apache2" ] ; then
	# annoyingly, the postinstall script starts apache2 on fresh installs
	mount -t proc procfs "$IMAGEDIR/proc"
	sed -r -i -e 's/pidof /pidof -x /' "$IMAGEDIR/etc/init.d/apache2"
	chroot "$IMAGEDIR" /etc/init.d/apache2 stop
	umount "$IMAGEDIR/proc"

	# configure apache2
	chroot "$IMAGEDIR" a2enmod ssl
	sed -r -i -e 's/^(\tOptions .*Indexes.*)/#\1/'		\
		"$IMAGEDIR/etc/apache2/apache2.conf"
fi

if [ "$MINIMG" != "1" ]; then
	# Use NodeJS sources from `nodesource.list`
	cp "$BAKERYDIR/templates/nodered/nodesource.gpg" "$IMAGEDIR/etc/apt/trusted.gpg.d"
	cp "$BAKERYDIR/templates/nodered/nodesource.list" "$IMAGEDIR/etc/apt/sources.list.d"

	# Install the nodejs version from `nodesource.list` added above, including npm
	chroot "$IMAGEDIR" apt-get update
	chroot "$IMAGEDIR" apt-get -y install nodejs

	# Install node-red via npm as explained in the node-red documentation
	NODERED_VER="3.0.2"
	chroot "$IMAGEDIR" npm install -g --unsafe-perm node-red@${NODERED_VER} || true
 	# This will just check successful installation, because npm will return an exit code != 0 in a chroot environment
	chroot "$IMAGEDIR" npm list -g node-red@${NODERED_VER}

	# Install systemd-unit file which uses pi user
	cp "$BAKERYDIR/templates/nodered/nodered.service" "$IMAGEDIR/usr/lib/systemd/system"
fi
# enable ssh daemon by default, disable swap, disable bluetooth on mini-uart
chroot "$IMAGEDIR" systemctl enable ssh
chroot "$IMAGEDIR" systemctl disable dphys-swapfile
chroot "$IMAGEDIR" systemctl disable hciuart

# disable 3rd party software
if [ "$MINIMG" != "1" ]; then
	chroot "$IMAGEDIR" systemctl disable logiclab
fi
chroot "$IMAGEDIR" systemctl disable noderedrevpinodes-server
chroot "$IMAGEDIR" systemctl disable revpipyload

# boot to console by default, disable autologin
chroot "$IMAGEDIR" systemctl set-default multi-user.target
chroot "$IMAGEDIR" systemctl enable getty@tty1.service
if [ -e "$IMAGEDIR/etc/lightdm/lightdm.conf" ] ; then
	sed -r -i -e "s/^autologin-user=/#autologin-user=/"	\
		"$IMAGEDIR/etc/lightdm/lightdm.conf"
fi

# autologin.conf enables autologin in raspios and raspios-full
# but not in raspios-lite
if [ -e "$IMAGEDIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" ] ; then
	rm -f "$IMAGEDIR/etc/systemd/system/getty@tty1.service.d/autologin.conf"
fi

# Disable cpufrequtils to keep the default cpu governor
chroot "$IMAGEDIR" systemctl disable cpufrequtils.service
chroot "$IMAGEDIR" systemctl disable raspi-config.service

# Since Raspberry Pi OS Bullseye the default user pi will only be used for the first
# boot and then replaced by a username which has to be defined in the first boot wizard.
# Therefore we need to disable the userconfig and set the password to the previous default `raspberry`
if [[ ! $(grep -q -E '^pi:\*' "$IMAGEDIR/etc/shadow") ]]; then
	echo 'pi:raspberry' | chroot "$IMAGEDIR" /usr/sbin/chpasswd
	chroot "$IMAGEDIR" systemctl disable userconfig
fi

# Remove banner warning which is shows on every ssh login (present since Bullseye)
if [[ -f "$IMAGEDIR/etc/ssh/sshd_config.d/rename_user.conf" ]]; then
	rm "$IMAGEDIR/etc/ssh/sshd_config.d/rename_user.conf"
fi

# Use NetworkManager instead of dhcpcd
chroot "$IMAGEDIR" raspi-config nonint do_netconf 2

# Don't manage pileft / piright with NetworkManager
install -o root -m 0644 "$BAKERYDIR/templates/network-manager/99-revpi.conf" "$IMAGEDIR/etc/NetworkManager/conf.d/99-revpi.conf"

# Use fallback to dhcp if no connection is configured
install -o root -m 0600 "$BAKERYDIR/templates/network-manager/dhcp-eth0.nmconnection" "$IMAGEDIR/etc/NetworkManager/system-connections"
install -o root -m 0600 "$BAKERYDIR/templates/network-manager/dhcp-eth1.nmconnection" "$IMAGEDIR/etc/NetworkManager/system-connections"

# Use fallback to link-local if dhcp fails
install -o root -m 0600 "$BAKERYDIR/templates/network-manager/fallback-link-local-eth0.nmconnection" "$IMAGEDIR/etc/NetworkManager/system-connections"
install -o root -m 0600 "$BAKERYDIR/templates/network-manager/fallback-link-local-eth1.nmconnection" "$IMAGEDIR/etc/NetworkManager/system-connections"

# clean up image and free as much as possible space
rm -rf "$IMAGEDIR"/var/cache/apt/archives/*.deb || true
rm -rf "$IMAGEDIR"/var/cache/apt/*.bin || true
rm -rf "$IMAGEDIR"/var/lib/apt/lists/* || true
rm -rf "$IMAGEDIR"/tmp/* || true
rm -rf "$IMAGEDIR"/var/tmp/* || true

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

# after package raspberrypi-kernel installed, install revpi-dt-blob.dtbo as default dt-blob
install -T "$IMAGEDIR/boot/overlays/revpi-dt-blob.dtbo" "$IMAGEDIR/boot/dt-blob.bin"

# Remove machine-id to match the systemd firstboot condition on first boot of image
rm "$IMAGEDIR/etc/machine-id"

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
truncate -s $((512 * ($PARTSTART + $PARTSIZE))) "$OUTPUT_IMAGE"
