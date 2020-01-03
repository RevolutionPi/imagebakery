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
	update

# try downloading the exact version of a package,
# fall back to latest version if not found
# (in the future we may additionally try downloading from
# snapshot.debian.org, e.g. using Debian::Snapshot on CPAN)
fetch_deb_src() {
	apt-get -o RootDir=$APTROOT --download-only source "$1" ||
	apt-get -o RootDir=$APTROOT --download-only source "$(echo $1 | cut -d= -f1)"
}

# exclude binary-only Raspbian packages
EXCLUDE='realvnc-vnc|oracle-java8-jdk'
# exclude Raspbian packages with missing source code
EXCLUDE+='|bluej|greenfoot|nodered|omxplayer|pifacedigital-scratch-handler|smartsim|wiringpi'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|logi-rts|pictory|piserial|revpi-(repo|wallpaper|webstatus)'
# exclude RevolutionPi packages whose source code is fetched from GitHub
EXCLUDE+='|raspberrypi-firmware|picontrol'

# fetch Raspbian sources
[ ! -d "$2" ] && mkdir -p "$2"
cd "$2"
dpkg-query --admindir $APTROOT/var/lib/dpkg -W		\
	-f='${source:Package}=${source:Version}\n'	\
	| egrep -v "^($EXCLUDE)=" | sort | uniq		\
	| while read package ; do fetch_deb_src "$package" ; done

# fetch missing Raspbian sources
wget -O omxplayer.tar.gz \
	https://github.com/popcornmix/omxplayer/archive/master.tar.gz
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' bluej | tr -dC '[0-9]')
wget http://www.bluej.org/download/files/source/BlueJ-source-$version.zip
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' greenfoot | tr -dC '[0-9].')
wget http://www.greenfoot.org/download/files/source/Greenfoot-source-$version.zip
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' nodered | tr -dC '[0-9].')
wget -O node-red_$version.tar.gz \
	https://github.com/node-red/node-red/archive/$version.tar.gz
wget -O node-red-nodes.tar.gz \
	https://github.com/node-red/node-red-nodes/archive/master.tar.gz
version=v$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' python3-pifacedigital-scratch-handler \
	| cut -d- -f1 | tr -dC '[0-9].')
wget -O pifacedigital-scratch-handler_$version.tar.gz \
	https://github.com/piface/pifacedigital-scratch-handler/archive/$version.tar.gz
version=v$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' smartsim \
	| cut -d- -f1 | tr -dC '[0-9].')
wget -O smartsim_$version.tar.gz \
	https://github.com/ashleynewson/SmartSim/archive/$version.tar.gz
version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' wiringpi | tr -dC '[0-9].')
wget -O wiringpi_$version.tar.gz \
	"https://git.drogon.net/?p=wiringPi;a=snapshot;h=$version;sf=tgz"

# fetch RevolutionPi sources
wget -O linux.tar.gz https://github.com/RevolutionPi/linux/archive/revpi-4.4.tar.gz
wget -O piControl.tar.gz https://github.com/RevolutionPi/piControl/archive/master.tar.gz

# clean up
rm -r $APTROOT
umount $IMAGEDIR/boot
umount $IMAGEDIR
rmdir $IMAGEDIR
delpart /dev/loop0 1
delpart /dev/loop0 2
losetup -d /dev/loop0
