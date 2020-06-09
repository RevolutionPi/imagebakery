#!/bin/bash
# customize raspbian image for revolution pi

if [ "$#" != 1 ] ; then
	echo 1>&1 "Usage: `basename $0` <image>"
	exit 1
fi

set -ex

# pivot to new PID namespace
if [ $$ != 2 ] && [ -x /usr/bin/newpid ] ; then
	exec /usr/bin/newpid "$0" "$@"
fi

IMAGEDIR=`mktemp -d -p /tmp img.XXXXXXXX`
BAKERYDIR=`dirname $0`
LOOPDEVICE=$(losetup -f)

cleanup_umount() {
	if [ -e $IMAGEDIR ] ; then
		lsof -t $IMAGEDIR | xargs --no-run-if-empty kill
	fi
	if [ -e $IMAGEDIR/usr/bin/qemu-arm-static ] ; then
		rm -f $IMAGEDIR/usr/bin/qemu-arm-static
	fi
	if mountpoint -q $IMAGEDIR/tmp/debs-to-install ; then
		umount $IMAGEDIR/tmp/debs-to-install
	fi
	if [ -e $IMAGEDIR/tmp/debs-to-install ] ; then
		rmdir $IMAGEDIR/tmp/debs-to-install
	fi
	if mountpoint -q $IMAGEDIR/boot ; then
		umount $IMAGEDIR/boot
	fi
	if mountpoint -q $IMAGEDIR ; then
		umount $IMAGEDIR
	fi
	if [ -d $IMAGEDIR ] ; then
		rmdir $IMAGEDIR
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
losetup "$LOOPDEVICE" $1
partprobe "$LOOPDEVICE"
mount "$LOOPDEVICE"p2 $IMAGEDIR
mount "$LOOPDEVICE"p1 $IMAGEDIR/boot

# see https://wiki.debian.org/QemuUserEmulation
if [ -e /usr/bin/qemu-arm-static ] ; then
    cp /usr/bin/qemu-arm-static $IMAGEDIR/usr/bin
fi

# copy templates
cp $BAKERYDIR/templates/cmdline.txt $IMAGEDIR/boot
cp $BAKERYDIR/templates/revpi-aliases.sh $IMAGEDIR/etc/profile.d
cp $BAKERYDIR/templates/rsyslog.conf $IMAGEDIR/etc

# force HDMI mode even if no HDMI monitor is detected
sed -r -i -e 's/#hdmi_force_hotplug=1/hdmi_force_hotplug=1/' \
	  -e 's/#hdmi_drive=2/hdmi_drive=2/' \
	  $IMAGEDIR/boot/config.txt

# limit disk space occupied by logs
ln -s ../cron.daily/logrotate $IMAGEDIR/etc/cron.hourly
sed -r -i -e 's/delaycompress/#delaycompress/' \
	  -e 's/sharedscripts/#sharedscripts/' \
	  $IMAGEDIR/etc/logrotate.d/rsyslog
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
' $IMAGEDIR/etc/logrotate.conf

# bootstrap apt source, will be overwritten by revpi-repo package
cp $BAKERYDIR/templates/revpi.gpg $IMAGEDIR/etc/apt/trusted.gpg.d
cp $BAKERYDIR/templates/revpi.list $IMAGEDIR/etc/apt/sources.list.d

# copy piTest source code
PICONTROLDIR=`mktemp -d -p /tmp piControl.XXXXXXXX`
git clone https://github.com/RevolutionPi/piControl $PICONTROLDIR
cp -pr $PICONTROLDIR/piTest $IMAGEDIR/home/pi/demo
cp -p $PICONTROLDIR/piControl.h $IMAGEDIR/home/pi/demo
sed -i -r -e 's%\.\./%%' $IMAGEDIR/home/pi/demo/Makefile
chown -R 1000:1000 $IMAGEDIR/home/pi/demo
chmod -R a+rX $IMAGEDIR/home/pi/demo
rm -r $PICONTROLDIR

# customize settings
echo Europe/Berlin > $IMAGEDIR/etc/timezone
rm $IMAGEDIR/etc/localtime
echo RevPi > $IMAGEDIR/etc/hostname
sed -i -e 's/raspberrypi/RevPi/g' $IMAGEDIR/etc/hosts
if ! grep -qE '^i2c-dev$' $IMAGEDIR/etc/modules ; then
	echo i2c-dev >> $IMAGEDIR/etc/modules
fi
echo piControl >> $IMAGEDIR/etc/modules
sed -i -r -e 's/^(XKBLAYOUT).*/\1="de"/'		\
	  -e 's/^(XKBVARIANT).*/\1="nodeadkeys"/'	\
	  $IMAGEDIR/etc/default/keyboard
install -d -m 755 -o root -g root $IMAGEDIR/etc/revpi
ln -s /var/www/pictory/projects/_config.rsc $IMAGEDIR/etc/revpi/config.rsc
echo `basename "$1"` > $IMAGEDIR/etc/revpi/image-release
install -d -m 700 -o 1000 -g 1000 $IMAGEDIR/home/pi/.ssh

# activate settings
chroot $IMAGEDIR dpkg-reconfigure -fnoninteractive keyboard-configuration
chroot $IMAGEDIR dpkg-reconfigure -fnoninteractive tzdata
chroot $IMAGEDIR dpkg-reconfigure -fnoninteractive console-setup

# automatically bring up eth0 and eth1 again after a USB bus reset
sed -i -e '6i# allow-hotplug eth0\n# allow-hotplug eth1\n' $IMAGEDIR/etc/network/interfaces

# provide WPA template and prioritize wlan0 routes by default
sed -i -e '/country=GB/d' $IMAGEDIR/etc/wpa_supplicant/wpa_supplicant.conf
cat >> $IMAGEDIR/etc/wpa_supplicant/wpa_supplicant.conf <<-EOF
	
	# WiFi of Revolutionary Pastries, Inc.
	network={
	        ssid=""
	        psk=""
	        key_mgmt=WPA-PSK
	}
	EOF
cat >> $IMAGEDIR/etc/dhcpcd.conf <<-EOF
	
	# Prioritize wlan0 routes over eth0 routes.
	interface wlan0
	        metric 100
	EOF

# harden network configuration
chroot $IMAGEDIR /usr/bin/patch /etc/sysctl.conf	\
	< $BAKERYDIR/templates/sysctl.conf.patch

# display IP address at login prompt
sed -i -e '1s/$/ \\4 \\6/' $IMAGEDIR/etc/issue

# free up disk space
dpkg --root $IMAGEDIR --purge `egrep -v '^#' $BAKERYDIR/debs-to-remove`
rm -rf $IMAGEDIR/home/pi/MagPi

# avoid installing unnecessary packages on this space-constrained machine
echo 'APT::Install-Recommends "false";' >> $IMAGEDIR/etc/apt/apt.conf

# download and install missing packages (with CVE-2019-3462 fix)
sed -r -i -e '1iAcquire::http::AllowRedirect "false";' $IMAGEDIR/etc/apt/apt.conf
sed -r -i -e '1ideb http://ftp.gwdg.de/pub/linux/debian/raspbian/raspbian stretch main' $IMAGEDIR/etc/apt/sources.list
chroot $IMAGEDIR apt-get update
chroot $IMAGEDIR apt-get -y install apt apt-transport-https libapt-inst2.0 libapt-pkg5.0
sed -r -i -e '1d' $IMAGEDIR/etc/apt/apt.conf $IMAGEDIR/etc/apt/sources.list

chroot $IMAGEDIR apt-get -y install `egrep -v '^#' $BAKERYDIR/debs-to-download`
dpkg --root $IMAGEDIR --force-depends --purge rpd-wallpaper
chroot $IMAGEDIR apt-get -y install revpi-wallpaper
chroot $IMAGEDIR apt-get update
chroot $IMAGEDIR apt-get -y install teamviewer-revpi
chroot $IMAGEDIR apt-mark hold raspi-copies-and-fills
chroot $IMAGEDIR apt-get -y upgrade
chroot $IMAGEDIR apt-mark unhold raspi-copies-and-fills
chroot $IMAGEDIR apt-get clean

if [ -e "$IMAGEDIR/etc/init.d/apache2" ] ; then
	# annoyingly, the postinstall script starts apache2 on fresh installs
	mount -t proc procfs $IMAGEDIR/proc
	sed -r -i -e 's/pidof /pidof -x /' $IMAGEDIR/etc/init.d/apache2
	chroot $IMAGEDIR /etc/init.d/apache2 stop
	umount $IMAGEDIR/proc

	# configure apache2
	chroot $IMAGEDIR a2enmod ssl
	sed -r -i -e 's/^(\tOptions .*Indexes.*)/#\1/'		\
		$IMAGEDIR/etc/apache2/apache2.conf
fi

# enable ssh daemon by default, disable swap, disable bluetooth on mini-uart
chroot $IMAGEDIR systemctl enable ssh
chroot $IMAGEDIR systemctl disable dphys-swapfile
chroot $IMAGEDIR systemctl disable hciuart

# disable 3rd party software
chroot $IMAGEDIR systemctl disable logiclab
chroot $IMAGEDIR systemctl disable nodered
chroot $IMAGEDIR systemctl disable noderedrevpinodes-server
chroot $IMAGEDIR systemctl disable revpipyload

# boot to console by default, disable autologin
chroot $IMAGEDIR systemctl set-default multi-user.target
ln -fs /lib/systemd/system/getty@.service		\
	$IMAGEDIR/etc/systemd/system/getty.target.wants/getty@tty1.service
if [ -e $IMAGEDIR/etc/lightdm/lightdm.conf ] ; then
	sed -r -i -e "s/^autologin-user=/#autologin-user=/"	\
		$IMAGEDIR/etc/lightdm/lightdm.conf
fi

# peg cpu at 1200 MHz to maximize spi0 throughput and avoid jitter
chroot $IMAGEDIR /usr/bin/revpi-config enable perf-governor

# remove package lists, they will be outdated within days
rm $IMAGEDIR/var/lib/apt/lists/*Packages

# work around duplicate teamviewer apt source
rm $IMAGEDIR/etc/apt/sources.list.d/teamviewer-iot-agent.list

# install local packages
if [ "$(/bin/ls $BAKERYDIR/debs-to-install/*.deb 2>/dev/null)" ] ; then
	mkdir $IMAGEDIR/tmp/debs-to-install
	mount --bind $BAKERYDIR/debs-to-install $IMAGEDIR/tmp/debs-to-install
	chroot $IMAGEDIR sh -c "dpkg -i /tmp/debs-to-install/*.deb"
fi

# remove logs and ssh host keys
find $IMAGEDIR/var/log -type f -delete
find $IMAGEDIR/etc/ssh -name "ssh_host_*_key*" -delete

cleanup_umount

fsck.vfat -a "$LOOPDEVICE"p1
sleep 2
fsck.ext4 -f -p "$LOOPDEVICE"p2
sleep 2

# shrink image to speed up flashing
resize2fs -M "$LOOPDEVICE"p2
PARTSIZE=$(dumpe2fs -h "$LOOPDEVICE"p2 | egrep "^Block count:" | cut -d" " -f3-)
PARTSIZE=$(($PARTSIZE * 8))   # ext4 uses 4k blocks, partitions use 512 bytes
sfdisk --dump "$LOOPDEVICE" | /bin/sed -r -e "\$!n
\$s/size=[^,]+/size=$PARTSIZE/" | /sbin/sfdisk "$LOOPDEVICE"
PARTSTART=$(cat /sys/block/$(basename "$LOOPDEVICE")/$(basename "$LOOPDEVICE"p2)/start)
truncate -s $((512 * ($PARTSTART + $PARTSIZE))) "$1"

cleanup_losetup
