#!/system/bin/sh
##########################################################################################
#
# Magisk Boot Image Patcher
# by topjohnwu
#
# Usage: sh boot_patch.sh <bootimage>
#
# The following additional flags can be set in environment variables:
# KEEPVERITY, KEEPFORCEENCRYPT, HIGHCOMP
#
# This script should be placed in a directory with the following files:
#
# File name          Type      Description
#
# boot_patch.sh      script    A script to patch boot. Expect path to boot image as parameter.
#                  (this file) The script will use binaries and files in its same directory
#                              to complete the patching process
# util_functions.sh  script    A script which hosts all functions requires for this script
#                              to work properly
# magiskinit         binary    The binary to replace /init, which has the magisk binary embedded
# magiskboot         binary    A tool to unpack boot image, decompress ramdisk, extract ramdisk,
#                              and patch the ramdisk for Magisk support
# chromeos           folder    This folder should store all the utilities and keys to sign
#                  (optional)  a chromeos device. Used for Pixel C
#
# If the script is not running as root, then the input boot image should be a stock image
# or have a backup included in ramdisk internally, since we cannot access the stock boot
# image placed under /data we've created when previously installed
#
##########################################################################################
##########################################################################################
# Functions
##########################################################################################

# Pure bash dirname implementation
getdir() {
  case "$1" in
    */*) dir=${1%/*}; [ -z $dir ] && echo "/" || echo $dir ;;
    *) echo "." ;;
  esac
}

##########################################################################################
# Initialization
##########################################################################################

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "`getdir "${BASH_SOURCE:-$0}"`"
  # Load utility functions
  . ./util_functions.sh
fi

BOOTIMAGE="$1"
[ -e "$BOOTIMAGE" ] || abort "$BOOTIMAGE does not exist!"

# Flags
HIGHCOMP=false

chmod -R 755 .

##########################################################################################
# Unpack
##########################################################################################

CHROMEOS=false

ui_print "- Unpacking boot image"
./magiskboot --unpack "$BOOTIMAGE"

case $? in
  1 )
    abort "! Unable to unpack boot image"
    ;;
  2 )
    HIGHCOMP=true
    ;;
  3 )
    ui_print "- ChromeOS boot image detected"
    CHROMEOS=true
    ;;
  4 )
    ui_print "! Sony ELF32 format detected"
    abort "! Please use BootBridge from @AdrianDC to flash Magisk"
    ;;
  5 )
    ui_print "! Sony ELF64 format detected"
    abort "! Stock kernel cannot be patched, please use a custom kernel"
esac

##########################################################################################
# Fstab patches
##########################################################################################

if [ $(grep_prop ro.build.version.sdk) -ge 26 ]; then
  printed=false
  for i in /system/vendor/etc/fstab*; do
    [ -f "$i" ] || continue
    if ! $printed; then
      ui_print "- Disabling disk quota in vendor fstabs..."
      printed=true
    fi
    ui_print "  Patching: $i"
    sed -i "
      s/,quota//g
      s/quota,//g
      s/quota\b//g
    " "$i"
  done
fi

##########################################################################################
# Ramdisk restores
##########################################################################################

# Test patch status and do restore, after this section, ramdisk.cpio.orig is guaranteed to exist
ui_print "- Checking ramdisk status"
MAGISK_PATCHED=false
./magiskboot --cpio ramdisk.cpio test
case $? in
  0 )  # Stock boot
    ;;
  1 )  # Magisk patched
    HIGHCOMP=false
    ;;
  2 ) # High compression mode
    HIGHCOMP=true
    ;;
esac

if $HIGHCOMP; then
  ui_print "! Insufficient boot partition size detected"
  ui_print "- Enable high compression mode"
fi

##########################################################################################
# Ramdisk patches
##########################################################################################

ui_print "- Patching ramdisk"

mkdir ftmp
printed=false
for i in $(cpio -t -F ramdisk.cpio | grep "fstab."); do
  if ! $printed; then
    ui_print "- Disabling disk quota in kernel fstabs..."
    printed=true
  fi
  ui_print "   Patching $i"
  ./magiskboot --cpio ramdisk.cpio "extract $i ftmp/$i"
  sed -i "
    s/,quota//g
    s/quota,//g
    s/quota\b//g
  " "ftmp/$i"
  ./magiskboot --cpio ramdisk.cpio "add 0644 $i ftmp/$i"
done
rm -rf ftmp

##########################################################################################
# Binary patches
##########################################################################################

if [ -f kernel ]; then
  # Remove Samsung RKP in stock kernel
  ./magiskboot --hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054

  # skip_initramfs -> want_initramfs
  ./magiskboot --hexpatch kernel \
  736B69705F696E697472616D6673 \
  77616E745F696E697472616D6673
fi

##########################################################################################
# Repack and flash
##########################################################################################

ui_print "- Repacking boot image"
./magiskboot --repack "$BOOTIMAGE" || abort "! Unable to repack boot image!"

# Sign chromeos boot
$CHROMEOS && sign_chromeos

./magiskboot --cleanup