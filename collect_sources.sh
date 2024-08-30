#!/bin/bash

# SPDX-FileCopyrightText: 2017-2024 KUNBUS GmbH
#
# SPDX-License-Identifier: GPL-2.0-or-later

# collect sources for a given image in order to
# burn them on a physical medium for license compliance

if [ "$#" != 2 ]; then
    echo 1>&1 "Usage: $(basename "$0") <image> <destination>"
    exit 1
fi

set -ex

# exclude binary-only Raspbian packages
EXCLUDE='realvnc-vnc'
EXCLUDE+='|widevine'
# exclude Raspbian packages with missing source code
EXCLUDE+='|nodered|nodejs'
# exclude binary-only RevolutionPi packages
EXCLUDE+='|teamviewer-revpi'
# exclude RevolutionPi packages whose source code is fetched from GitLab
EXCLUDE+='|raspberrypi-firmware|picontrol|revpi-firmware'

IMAGENAME="$1"
DESTDIR="$2"
IMAGEDIR=/tmp/img.$$
APTROOT=/tmp/apt.$$
LOOPDEVICE=$(losetup -f)

mount_image() {
    # mount ext4 + FAT filesystems
    losetup "$LOOPDEVICE" "$IMAGENAME"
    partprobe "$LOOPDEVICE"
    mkdir $IMAGEDIR
    mount -o ro "$LOOPDEVICE"p2 $IMAGEDIR
    mount -o ro "$LOOPDEVICE"p1 $IMAGEDIR/boot

    trap cleanup ERR SIGINT EXIT
}

cleanup_umount() {
    if [ -e "$IMAGEDIR" ]; then
        lsof -t "$IMAGEDIR" | xargs --no-run-if-empty kill
    fi
    if mountpoint -q "$IMAGEDIR/boot"; then
        umount "$IMAGEDIR/boot"
    fi
    if mountpoint -q "$IMAGEDIR"; then
        umount "$IMAGEDIR"
    fi
    if [ -d "$IMAGEDIR" ]; then
        rmdir "$IMAGEDIR"
    fi
}

cleanup_losetup() {
    if [ -e "$LOOPDEVICE"p1 ]; then
        delpart "$LOOPDEVICE" 1
    fi
    if [ -e "$LOOPDEVICE"p2 ]; then
        delpart "$LOOPDEVICE" 2
    fi
    if losetup "$LOOPDEVICE" 2>/dev/null; then
        losetup -d "$LOOPDEVICE"
    fi
}

cleanup() {
    cleanup_umount
    cleanup_losetup
}

create_aptroot() {
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
}

# try downloading the exact version of a package,
# fall back to latest version if not found
#
# $1: name of source package
# $2: version of source package
fetch_deb_src() {
    package="$1"
    version="$2"

    found=0
    exact_version=0

    if apt-get -q -o RootDir=$APTROOT -o APT::Sandbox::User="" --download-only \
        source "$package=$version" >/dev/null 2>&1; then
        exact_version=1
        found=1
    elif apt-get -q -o RootDir=$APTROOT -o APT::Sandbox::User="" --download-only \
            source "$package" >/dev/null 2>&1; then
        found=1
    fi

    echo $found $exact_version

    return $((1 - found))
}

mount_image
create_aptroot

[[ ! -d "$DESTDIR" ]] && mkdir -p "$DESTDIR"
cd "$DESTDIR" || exit 1

# Generate list of installed packages (and strip architecture from name)
package_list="packages.csv"
echo "package,version,source,source_version" >"$package_list"
dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
    -f='${binary:Package},${Version},${source:Package},${source:Version}\n' |
    sort -u |
    # sort -u >> "$package_list"
    sed -E 's/^(.*?):(armhf|arm64)/\1/g'>> "$package_list"

# Extract source packages and versions from list and filter excludes
source_packages=$(
    awk -F',' '{print $3, $4}' "$package_list" |
        sort -u |
        grep -Ev "^($EXCLUDE) "
)

# Fetch source packages
while read -r item; do
    read -r package version <<<"$item"
    result=$(fetch_deb_src "$package" "$version")
    echo $package $version $result >> results.csv
done <<<"$source_packages"

# Fetch RevolutionPi sources
knl_version=$(dpkg-query --admindir $APTROOT/var/lib/dpkg -W \
    -f='${source:Version}' raspberrypi-kernel || true)
knl_tag="raspberrypi-kernel_$knl_version"
# GIT tags cannot contain the ':' character, therefore we substitute it with '%' (url-encoded).
# see https://dep-team.pages.debian.net/deps/dep14/ (Version mangling) for more details
knl_tag=${knl_tag//\:/%25}
wget -nv -O "linux-$knl_version.tar.gz" "https://gitlab.com/revolutionpi/linux/-/archive/$knl_tag/linux-$knl_tag.tar.gz"
wget -nv -O "piControl-$knl_version.tar.gz" "https://gitlab.com/revolutionpi/piControl/-/archive/$knl_tag/piControl-$knl_tag.tar.gz"
wget -nv -O IODeviceExample.tar.gz "https://gitlab.com/revolutionpi/IODeviceExample/-/archive/master/IODeviceExample-master.tar.gz"

# Take node modules sources from root directory of npm
test -d "$IMAGEDIR/usr/lib/node_modules" && tar -czvf node_modules.tar.gz "$IMAGEDIR/usr/lib/node_modules"
