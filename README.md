# Create custom images for Revolution Pi

## Intended usage

### Download RaspiOS (previously called Raspbian) image
Works with both [RaspiOS](https://www.raspberrypi.org/software/operating-systems/#raspberry-pi-os-32-bit) desktop and lite images.

*Raspberry Pi OS with desktop*
```
curl -O https://downloads.raspberrypi.org/raspios_oldstable_armhf/images/raspios_oldstable_armhf-2022-01-28/2022-01-28-raspios-buster-armhf.zip
unzip 2022-01-28-raspios-buster-armhf.zip
```

*Raspberry Pi OS Lite*
```
curl -O https://downloads.raspberrypi.org/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2022-01-28/2022-01-28-raspios-buster-armhf-lite.zip
unzip 2022-01-28-raspios-buster-armhf-lite.zip
```

### Customize for Revolution Pi
(requires root, an armhf system (RasPi or VM) and Internet connectivity;
to cross-build, apt-get install qemu-user-static binfmt-support;
custom packages can be placed in debs-to-install/):

`customize_image.sh <raspbian-image>`

### Collect sources on a physical medium for GPL compliance
(requires root and Internet connectivity):

`collect_sources.sh <raspbian-image> /media/usbstick`
