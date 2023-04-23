# Create custom images for Revolution Pi

## Intended usage

> **NOTE:** When creating a custom image, always use the most recent release tag (available at https://github.com/RevolutionPi/imagebakery/tags), as the master branch may contain code that is still in development.

### Download Raspberry Pi OS (previously called Raspbian) image

Works with both [Raspberry Pi OS](https://www.raspberrypi.org/software/operating-systems/#raspberry-pi-os-32-bit) desktop and lite images.

*Raspberry Pi OS with desktop*
```
curl -O https://downloads.raspberrypi.org/raspios_oldstable_armhf/images/raspios_oldstable_armhf-2022-09-26/2022-09-22-raspios-buster-armhf.img.xz
xz -d 2022-09-22-raspios-buster-armhf.img.xz
```

*Raspberry Pi OS Lite*
```
curl -O https://downloads.raspberrypi.org/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2022-09-26/2022-09-22-raspios-buster-armhf-lite.img.xz
xz -d 2022-09-22-raspios-buster-armhf-lite.img.xz
```

### Customize for Revolution Pi

The script requires root privileges, an armhf system (eg. Raspberry Pi or VM) and internet connectivity.

If no armhf system is available, a crossbuild can be done with the qemu user static tools:

```
sudo apt-get install qemu-user-static binfmt-support
```

> **NOTE:** If you are using WSL2 on Windows you might experience issues as binfmt support is not enabled. This is done by systemd in a normal Debian installation. To resolve the issue you might need to run the following command:
> ```
> sudo update-binfmts --enable
> ```
> The issue is documented here: https://github.com/microsoft/WSL/issues/7181

#### Required packages on the build system

- curl
- dosfstools
- parted

#### Image flavors

In order to build an image with only software that is necessary for basic operation (eg. Pictory and other RevPi tools), you have to call the customization script with the `--minimize` option. This option is used to build our official lite image (based on the foundations lite image).

`customize_image.sh --minimize <raspberrypi-image> [output-image]`

For an image with all additional components (like NodeRed, logi-rts and Teamviewer), you must call the customization script without any options:

`customize_image.sh <raspberrypi-image> [output-image]`


### Install debian packages into Revolution Pi Image

If you would like to modify an existing image by only installing some packages (from repository or local file), you can use the script `install_debs_into_image.sh`. To add a package you can either add the package name to the file debs-to-download or put the package file into the folder `debs-to-install/`. After that you have to invoke the script as following:

`install_debs_into_image.sh <revpi-image>`

### Collect sources on a physical medium for GPL compliance

The script `collect_sources.sh` can be used to collect the sources of the packages shipped with our official image. The official images can be found on our [download page](https://revolutionpi.de/tutorials/downloads/#revpiimages). 

> **Note:** This step requires root access and Internet connectivity.

#### Usage

```
./collect_sources.sh <revpi-image> /media/usbstick

# eg. ./collect_sources.sh 2022-07-28-revpi-buster-lite.img /media/usbstick
```
