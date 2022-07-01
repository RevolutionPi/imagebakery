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

The script requires root privileges, an armhf system (RasPi or VM) and internet connectivity.

If no armhf system is available, a crossbuild can be done with the qemu user static tools:

```
sudo apt-get install qemu-user-static binfmt-support
```

In order to build an image with only software that is necessary for basic operation (eg. Pictory and other RevPi tools), you have to call the customization script with the `--minimize` option. This option is used to build our official lite image (based on the foundations lite image).

`customize_image.sh --minimize <raspbian-image>`

For an image with all additional components (like NodeRed, logi-rts and Teamviewer), you must call the customization script without any options:

`customize_image.sh <raspbian-image>`

### Collect sources on a physical medium for GPL compliance
(requires root and Internet connectivity):

`collect_sources.sh <raspbian-image> /media/usbstick`
