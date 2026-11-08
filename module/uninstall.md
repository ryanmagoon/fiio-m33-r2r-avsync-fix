# Uninstall / rollback

**Revert the patch only:** open the Magisk app, go to Modules, disable or remove
"FiiO M33 R2R A/V sync fix", and reboot. The stock `/system/lib64/libaudioclient.so`
is untouched on disk; Magisk only overlays it while the module is enabled.

Without the Magisk app, from `adb shell` with root:

    su -c 'touch /data/adb/modules/fiio_m33_audiotrack_noretrack/remove'
    reboot

**Full unroot:** flash your own stock `init_boot` image back (the one you backed up
before patching it with Magisk) to the active slot, for example:

    fastboot flash init_boot_b init_boot_stock.img
    fastboot reboot

Never flash `vbmeta` or any other partition for this fix.
