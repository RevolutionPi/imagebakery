#!/bin/sh
# customize raspbian image for revolution pi

if [ "$#" != 1 ] ; then
	echo 1>&1 "Usage: `basename $0` <image>"
	exit 1
fi

set -ex

IMAGEDIR=/tmp/img.$$
BAKERYDIR=`dirname $0`

# mount ext4 + FAT filesystems
losetup /dev/loop0 $1
partprobe /dev/loop0
mkdir $IMAGEDIR
mount /dev/loop0p2 $IMAGEDIR
mount /dev/loop0p1 $IMAGEDIR/boot

# copy templates
cp $BAKERYDIR/templates/cmdline.txt $IMAGEDIR/boot
cp $BAKERYDIR/templates/config.txt $IMAGEDIR/boot
cp $BAKERYDIR/templates/revpi-aliases.sh $IMAGEDIR/etc/profile.d
cp $BAKERYDIR/templates/rsyslog.conf $IMAGEDIR/etc

# limit disk space occupied by logs
ln -s ../cron.daily/logrotate $IMAGEDIR/etc/cron.hourly
sed -r -i -e 's/delaycompress/#delaycompress/' \
	  -e 's/sharedscripts/#sharedscripts/' \
	  $IMAGEDIR/etc/logrotate.d/rsyslog
sed -r -i -e 's/#compress/compress/' -e '2i \
\
# limit size of each log file\
maxsize 50M\
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
git clone https://github.com/RevolutionPi/piControl /tmp/piControl.$$
cp -pr /tmp/piControl.$$/piTest $IMAGEDIR/home/pi/demo
cp -p /tmp/piControl.$$/piControl.h $IMAGEDIR/home/pi/demo
sed -i -r -e 's%\.\./%%' $IMAGEDIR/home/pi/demo/Makefile
chown -R 1000:1000 $IMAGEDIR/home/pi/demo
chmod -R a+rX $IMAGEDIR/home/pi/demo
rm -r /tmp/piControl.$$

# customize settings
echo Europe/Berlin > $IMAGEDIR/etc/timezone
rm $IMAGEDIR/etc/localtime
echo RevPi > $IMAGEDIR/etc/hostname
sed -i -e 's/raspberrypi/RevPi/g' $IMAGEDIR/etc/hosts
echo piControl >> $IMAGEDIR/etc/modules
sed -i -r -e 's/^(XKBLAYOUT).*/\1="de"/'		\
	  -e 's/^(XKBVARIANT).*/\1="nodeadkeys"/'	\
	  $IMAGEDIR/etc/default/keyboard
install -d -m 755 -o root -g root $IMAGEDIR/etc/revpi
ln -s /var/www/pictory/projects/_config.rsc $IMAGEDIR/etc/revpi/config.rsc

# activate settings
chroot $IMAGEDIR dpkg-reconfigure -fnoninteractive keyboard-configuration
chroot $IMAGEDIR dpkg-reconfigure -fnoninteractive tzdata

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

# free up disk space
dpkg --root $IMAGEDIR --purge `egrep -v '^#' $BAKERYDIR/debs-to-remove`

# avoid installing unnecessary packages on this space-constrained machine
echo 'APT::Install-Recommends "false";' >> $IMAGEDIR/etc/apt/apt.conf

# download and install missing packages
chroot $IMAGEDIR apt-get update
chroot $IMAGEDIR apt-get -y install `egrep -v '^#' $BAKERYDIR/debs-to-download`
dpkg --root $IMAGEDIR --force-depends --purge pixel-wallpaper
chroot $IMAGEDIR apt-get -y install revpi-wallpaper
chroot $IMAGEDIR apt-get clean

# annoyingly, the postinstall script starts apache2 on fresh installs
mount -t proc procfs $IMAGEDIR/proc
chroot $IMAGEDIR /etc/init.d/apache2 stop
umount $IMAGEDIR/proc

# configure apache2
chroot $IMAGEDIR a2enmod ssl

# enable ssh daemon by default
chroot $IMAGEDIR systemctl enable ssh

# remove package lists, they will be outdated within days
rm $IMAGEDIR/var/lib/apt/lists/*Packages

# install local packages
if [ $(/bin/ls $BAKERYDIR/debs-to-install/*.deb 2>/dev/null) ] ; then
	dpkg --root $IMAGEDIR -i $BAKERYDIR/debs-to-install/*.deb
fi

# remove logs
find $IMAGEDIR/var/log -type f -delete

# clean up
umount $IMAGEDIR/boot
umount $IMAGEDIR
rmdir $IMAGEDIR
fsck.vfat -a /dev/loop0p1
fsck.ext4 -f -p /dev/loop0p2
delpart /dev/loop0 1
delpart /dev/loop0 2
losetup -d /dev/loop0
