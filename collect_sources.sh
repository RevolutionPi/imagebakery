#!/bin/bash
# collect sources for a given Raspbian image in order to
# burn them on a physical medium for GPL compliance

if [ "$#" != 2 ] ; then
	echo 1>&1 "Usage: `basename $0` <image> <destination>"
	exit 1
fi

set -ex

IMAGEDIR=/tmp/img.$$
APTROOT=/tmp/apt.$$
LOOPDEVICE=$(losetup -f)

# mount ext4 + FAT filesystems
losetup "$LOOPDEVICE" "$1"
partprobe "$LOOPDEVICE"
mkdir $IMAGEDIR
mount -o ro "$LOOPDEVICE"p2 $IMAGEDIR
mount -o ro "$LOOPDEVICE"p1 $IMAGEDIR/boot

# deb-src entries in sources.list are commented out by default;
# duplicate the config, patch it and download the package lists
mkdir -p $APTROOT/var/cache/apt/archives/partial
(cd $IMAGEDIR ; tar cf - --exclude=var/lib/dpkg/info	\
	etc/apt var/lib/apt var/lib/dpkg usr/share/dpkg)\
	| (cd $APTROOT ; tar xf -)
(cd / ; tar cf - /usr/lib/apt)	\
	| (cd $APTROOT ; tar xf -)

# no source package is provided by nodesource.list
rm -f $APTROOT/etc/apt/sources.list.d/nodesource.list

sed -i -r -e 's/#(deb-src.*)/\1/' $APTROOT/etc/apt/sources.list \
				  $APTROOT/etc/apt/sources.list.d/*
apt-get -o Dir=$APTROOT -o Dir::State::status=$APTROOT/var/lib/dpkg/status \
	--allow-releaseinfo-change \
	update

# try downloading the exact version of a package,
# fall back to latest version if not found
# (in the future we may additionally try downloading from
# snapshot.debian.org, e.g. using Debian::Snapshot on CPAN)
fetch_deb_src() {
	apt-get -o RootDir=$APTROOT -o APT::Sandbox::User="" --download-only \
		source "$1" ||
	apt-get -o RootDir=$APTROOT -o APT::Sandbox::User="" --download-only \
		source "$(echo $1 | cut -d= -f1)"
}

# exclude binary-only Raspbian packages
EXCLUDE='realvnc-vnc'
# exclude Raspbian packages with missing source code
EXCLUDE+='|nodered|wiringpi|nodejs'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|piserial|teamviewer-revpi|revpi-modbus'
# exclude non-binary RevolutionPi packages
EXCLUDE+='|pictory|revpi-(tools|webstatus)'
# exclude RevolutionPi packages whose source code is fetched from GitHub
EXCLUDE+='|raspberrypi-firmware|picontrol|revpi-firmware'

# fetch Raspbian sources
[ ! -d "$2" ] && mkdir -p "$2"
cd "$2"
dpkg-query --admindir $APTROOT/var/lib/dpkg -W		\
	-f='${source:Package}=${source:Version}\n'	\
	| egrep -v "^($EXCLUDE)=" | sort | uniq		\
	| while read package ; do fetch_deb_src "$package" ; done

# fetch missing Raspbian sources
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' wiringpi | tr -dC '[0-9].')
wget -O wiringpi_$version.tar.gz \
	https://github.com/WiringPi/WiringPi/archive/final_official_$version.tar.gz

# fetch RevolutionPi sources
knl_version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' raspberrypi-kernel || true)
knl_tag="raspberrypi-kernel_$knl_version"
knl_tag=$(sed 's/:/%25/g' <<< "$knl_tag")
wget -O "linux-$knl_version.tar.gz" "https://github.com/RevolutionPi/linux/archive/refs/tags/$knl_tag.tar.gz"
wget -O "piControl-$knl_version.tar.gz" "https://github.com/RevolutionPi/piControl/archive/refs/tags/$knl_tag.tar.gz"
wget -O IODeviceExample.tar.gz https://github.com/RevolutionPi/IODeviceExample/archive/master.tar.gz
wget -O python-snap7.tar.gz https://github.com/RevolutionPi/python-snap7/archive/master.tar.gz
wget -O snap7-debian.tar.gz https://github.com/RevolutionPi/snap7-debian/archive/master.tar.gz
wget -O python3-revpimodio2.tar.gz https://github.com/naruxde/revpimodio2/archive/master.tar.gz

# clean up
rm -r $APTROOT
umount $IMAGEDIR/boot
umount $IMAGEDIR
rmdir $IMAGEDIR
delpart "$LOOPDEVICE" 1
delpart "$LOOPDEVICE" 2
losetup -d "$LOOPDEVICE"
