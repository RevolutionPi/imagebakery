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

# mount ext4 + FAT filesystems
losetup /dev/loop0 "$1"
partprobe /dev/loop0
mkdir $IMAGEDIR
mount -o ro /dev/loop0p2 $IMAGEDIR
mount -o ro /dev/loop0p1 $IMAGEDIR/boot

# deb-src entries in sources.list are commented out by default;
# duplicate the config, patch it and download the package lists
mkdir -p $APTROOT/var/cache/apt/archives/partial
(cd $IMAGEDIR ; tar cf - --exclude=var/lib/dpkg/info	\
	etc/apt var/lib/apt var/lib/dpkg usr/share/dpkg)\
	| (cd $APTROOT ; tar xf -)
(cd / ; tar cf - /usr/lib/apt)	\
	| (cd $APTROOT ; tar xf -)
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
EXCLUDE='realvnc-vnc|oracle-java8-jdk'
# exclude Raspbian packages with missing source code
EXCLUDE+='|nodered|wiringpi'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|logi-rts|logiclab|piserial|procon-web-iot|teamviewer-revpi'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|pimodbus-master|pimodbus-slave'
# exclude non-binary RevolutionPi packages
EXCLUDE+='|pictory|revpi-(repo|tools|wallpaper|webstatus)|revpi7'
# exclude RevolutionPi packages whose source code is fetched from GitHub
EXCLUDE+='|linux-4.9|raspberrypi-firmware|picontrol|revpi-firmware'
# exclude RevolutionPi packages whose source code is fetched from GitHub
EXCLUDE+='|python-snap7|snap7'

# fetch Raspbian sources
[ ! -d "$2" ] && mkdir -p "$2"
cd "$2"
dpkg-query --admindir $APTROOT/var/lib/dpkg -W		\
	-f='${source:Package}=${source:Version}\n'	\
	| egrep -v "^($EXCLUDE)=" | sort | uniq		\
	| while read package ; do fetch_deb_src "$package" ; done

# fetch missing Raspbian sources
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' nodered | tr -dC '[0-9].')
[ -z "$version" ] && version=master
wget -O node-red_$version.tar.gz \
	https://github.com/node-red/node-red/archive/$version.tar.gz
wget -O node-red-nodes.tar.gz \
	https://github.com/node-red/node-red-nodes/archive/master.tar.gz
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' wiringpi | tr -dC '[0-9].')
wget -O wiringpi_$version.tar.gz \
	https://github.com/WiringPi/WiringPi/archive/final_official_$version.tar.gz

# fetch RevolutionPi sources
wget -O linux.tar.gz https://github.com/RevolutionPi/linux/archive/revpi-4.9.tar.gz
wget -O piControl.tar.gz https://github.com/RevolutionPi/piControl/archive/master.tar.gz
wget -O IODeviceExample.tar.gz https://github.com/RevolutionPi/IODeviceExample/archive/master.tar.gz
wget -O python-snap7.tar.gz https://github.com/RevolutionPi/python-snap7/archive/master.tar.gz
wget -O snap7-debian.tar.gz https://github.com/RevolutionPi/snap7-debian/archive/master.tar.gz

# clean up
rm -r $APTROOT
umount $IMAGEDIR/boot
umount $IMAGEDIR
rmdir $IMAGEDIR
delpart /dev/loop0 1
delpart /dev/loop0 2
losetup -d /dev/loop0
