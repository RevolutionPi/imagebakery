#!/bin/bash
# collect sources for a given Raspbian image in order to
# burn them on a physical medium for GPL compliance

if [ "$#" != 2 ]; then
	echo 1>&1 "Usage: $(basename "$0") <image> <destination>"
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
(
	cd $IMAGEDIR
	tar cf - --exclude=var/lib/dpkg/info \
		etc/apt var/lib/apt var/lib/dpkg usr/share/dpkg
) |
	(
		cd $APTROOT
		tar xf -
	)
(
	cd /
	tar cf - /usr/lib/apt
) |
	(
		cd $APTROOT
		tar xf -
	)

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
			source "$(echo "$1" | cut -d= -f1)"
}

# exclude binary-only Raspbian packages
EXCLUDE='realvnc-vnc'
EXCLUDE+='|widevine'
# exclude Raspbian packages with missing source code
EXCLUDE+='|nodered|nodejs'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|teamviewer-revpi'
# exclude RevolutionPi packages whose source code is fetched from GitHub
EXCLUDE+='|raspberrypi-firmware|picontrol|revpi-firmware'

# fetch Raspbian sources
[ ! -d "$2" ] && mkdir -p "$2"
cd "$2"
dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Package}=${source:Version}\n' |
	grep -E -v "^($EXCLUDE)=" | sort | uniq |
	while read -r package; do fetch_deb_src "$package"; done

# fetch RevolutionPi sources
knl_version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
	-f='${source:Version}' raspberrypi-kernel || true)
knl_tag="raspberrypi-kernel_$knl_version"
# GIT tags cannot contain the ':' character, therefore we substitute it with '%' (url-encoded).
# see https://dep-team.pages.debian.net/deps/dep14/ (Version mangling) for more details
knl_tag=${knl_tag//\:/%25}
wget -O "linux-$knl_version.tar.gz" "https://github.com/RevolutionPi/linux/archive/refs/tags/$knl_tag.tar.gz"
wget -O "piControl-$knl_version.tar.gz" "https://github.com/RevolutionPi/piControl/archive/refs/tags/$knl_tag.tar.gz"
wget -O IODeviceExample.tar.gz https://github.com/RevolutionPi/IODeviceExample/archive/master.tar.gz

# take node modules sources from root directory of npm
test -d "$IMAGEDIR/usr/lib/node_modules" && tar -czvf node_modules.tar.gz "$IMAGEDIR/usr/lib/node_modules"

# clean up
rm -r $APTROOT
umount $IMAGEDIR/boot
umount $IMAGEDIR
rmdir $IMAGEDIR
delpart "$LOOPDEVICE" 1
delpart "$LOOPDEVICE" 2
losetup -d "$LOOPDEVICE"
