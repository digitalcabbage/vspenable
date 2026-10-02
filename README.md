VSP Enable
==========

The information on this page may render drives unusable and irretrievably destroy data. I accept no liability for bricked drives or destroyed data under any circumstances.

It is assumed that you are running a vanilla Linux installation, the drives are attached via an LSI SAS card that is in IT mode, so no RAID controllers but expanders are permissible. They must have only a single connection i.e., no multipathing, so disconnect any secondary connection. You will need to install the sg3_utils package in particular. The script checks everything it needs is installed before attempting to do anything. The script, however, works on the latest [SystemRescue](https://www.system-rescue.org/) (formerly known as SystemRescueCd) so you don't need a machine with Linux installed, just the ability to boot a live CD/USB.

It is assumed that you are running the script as root.


Introduction
------------

From time to time, on various forums across the internet, the question of how to reuse a hard drive taken from a Hitachi Virtual Storage Processor (VSP) system springs up. Usually, this is because someone purchased one or more drives on eBay, etc., unaware they came from a Hitachi VSP system, and now needs help getting them working.

These drives have a twofold problem. First, as with drives from many enterprise storage systems, they are formatted with a larger physical block size than normal systems. This is either 520 bytes or 4160 bytes. The first step to making them usable is to reformat them down to a block size of 512 or 4096 bytes, respectively. This is easy with the sg_format utility, and you can format many drives in parallel by spawning them in a screen or tmux session.

The second, thornier problem is that drives from a VSP system use special firmware that accepts only SCSI_WRITE_AND_VERIFY commands. They reject the SCSI_WRITE commands that basically everything else uses. A couple of suggestions in various forum posts is that this is because the drives were not properly exported from the Hitachi VSP system. After speaking with the admin at work, this is likely because that process takes hours, so when they decommission the system, they mostly turn them off and have someone take them away and sanitise the drives.

Flashing the drives
-------------------

There are two ways to fix this second problem. The first is to flash the drive with a more standard firmware. I have had success with older Seagate drives and generic Seagate firmware. Unfortunately, newer Seagate drives (anything with a SAS-3/12Gbps or better interface) and all HGST drives appear to be cryptographically vendor-locked. If you can flash generic firmware this is the preferred method for making the drives usable.

The following is a list of Seagate drives taken from a VSP that I have been able to flash with generic Seagate firmware. The serial numbers have been gleaned from eBay photos and are valid for downloading the firmware from the [Seagate website](https://www.seagate.com/gb/en/support/downloads/) There will be other combinations that will work but I have very limited access to different SAS-2 Seagate drive models from VSP systems. If anyone has other model/serial number combinations to share, message me and I will update the table.

| Model        | Serial   |
|--------------|----------|
| ST9900805SS  | 6XS2BPEC |
| ST900MM0006  | S0N1WQH7 |
| ST4000NM0023 | Z1Z8CLYA |

A "Russian" person online can overcome these locks for a fee. His requirements are a Remote Desktop connection on a Windows 7 32-bit machine, which is sketchy as hell in 2026. Since Russia's full-scale invasion of Ukraine in 2022, transferring money to Russia is increasingly difficult and not a viable option for many people. I can't get this through my workplace procurement for example.

If you want to go down this route, the following web page has links to the service's terms and conditions.

https://disk.yandex.ru/d/FEXpvFoGJlccmg

Mode page 0x38
--------------

Fortunately, an alternative method exists. All drives with Hitachi VSP firmware have an undocumented mode page (0x38). On the drives I have flashed with generic Seagate firmware, this mode page disappears.

The basics of the method were discovered by user stefan in this thread on the HDD Guru forum

[https://forum.hddguru.com/viewtopic.php?f=1&t=43854](https://forum.hddguru.com/viewtopic.php?f=1&t=43854)

He had several drives, all the same model, taken from a VSP system; some worked, and some did not. He deduces that the difference between the Seagate drives is in byte 0x14 of mode page 0x38. On the working drives, it is 0x01, and on the nonworking drives, it is 0x00. By changing this on the drive, he can make the drives work.

However, this is not the full story: on the HGST drives, byte 0x14 of mode page 0x38 is 0x02 and not 0x00. Given that I had over two hundred 900GB 2.5" HGST drives and they were only worth around $10 each, I made an educated guess that it was more specifically the least significant bit of byte 0x14 that needed to be set to make the drives work. If I bricked a drive, and I have bricked a few over the last five years, then I hadn't lost much anyway.

This indeed worked, and I have tested it on all the drive types from VSP that I have access to. These are nine different drive types, a mixture of 2.5" 10K RPM drives and 3.5" nearline SAS drives of different capacities.

An interesting point is that I had one 1.2TB 2.5" drive that had been set to show a size of 900GB. This is presumably because it had been used to replace a failed 900GB drive. However, when formatted to a 512-byte block size, the capacity changed to 1.2 TB. When unlocked it just works!

Using the Script
----------------

The Bash shell script aims to simplify the processing of the hard drives you wish to enable. I have processed several hundred drives over the last five years and have around 800 to enable using mode page 0x38. The script works on **all** hard drives on the system that it identifies as coming from a VSP system. The three main functions are to format the drives to a standard block size, do some basic tests on the drives to show their health and finally display and change the least significant bit of byte 0x14 in mode page 0x38 to enable the drives to be usable.

My workflow is to test all the drives are there with lsscsi, run the script with the -f option to format the drives. It will automatically detect the appropriate block size to use based on the drives existing block size, 512 if it is 520 and 4096 if it is 4160. This sets the format off in individual named screens one per drive based on the device name. So a format for /dev/sda will be on a screen named sda. When the format of a drive is finished the screen will terminate, so you know they are all finished when there are no screens left to reattatch to. The formatting process can take many hours to complete. The exact amount of time is model dependant and don't assume a larger capacity drive will take longer. For example an ST4000NM0023 (4TB) drive takes around 18 hours, were as a HUH721010AL5204 (10TB) drive it is around 12 hours. By formatting the drives in parallel it takes the same for one drive as it would for 60 drives. It would be a **VERY** bad idea to try and format the drives using the script if you have multiple active paths such as if they are in a JBOD with both ESM's connected. The script makes some basic checks and bails if it detects active multipathing on the system but it is **NOT** fool proof.

Once the drives are formatted, it is prudent to check that they are fine. Low level formatting a drive to change it's physical block size is a very good stress test of the drive. It is also an excellent way to sanitize a drive. In my experience a non zero percentage of drives will fail at this stage. They either get a large number of reallocated sectors (elements in the grown defect list) or the SMART health changes to something other than "OK". If you run the script with -t it will display all VSP drives were the the number of reallocated sectors is non zero or the SMART health status is not "OK". Note any serial numbers of failed drives and take them out and mark them with a permanent marker as bad/failed. If you run the script with -T it displays the data for all drives attached.

Once that is done run the script without any options. It should show a zero for each drive. Then run it with the -e option to enable SCSI_WRITE. Finally run the script again without any options, it should now show a one next to each drive device.

VSP Drive device identification
-------------------------------

The device identification string for drives taken from a VSP system is unusual in that it has been changed from the underlying device. The format encodes a range of drive information and has mostly been decoded. It is of the format.

   AABCD-EFFFGG

where

- AA the type of device
   - DK for spinning disks
   - SL for flash 1DWD read intensive drives
   - SF for flash 10DWD write intensive drives
- B the manufacturer
   - B for Toshiba/Kioxia
   - M for Samsung
   - R for HGST/Hitachi
   - S for Seagate
- C the physical size of the drive
    - 2 for a 3.5" drive
    - 5 for a 2.5" drive
- D an uppercase letter which increases with new drive model series
- E indicates the speed of the drive
     - H 7200 RPM
     - J 10k RPM
     -  K 15k RPM
     -  M for an SSD
- FFF indicates the capacity of the drive
     - if it is three digits then it's the capacity in GB
     - if the 2nd or 3rd digit is an R it is a decimal point and the capacity is in TB
 - GG is the interface type of the drive
      - AT for SATA drives
      - SS for SAS drives
      - NC for NVMe drives

Because my sample size is limited, this is likely incomplete. For example I suspect that if you had drives from really old VSP systems, there would have been an interface code for Fibre Channel drives. There are also likely to be other letters for the manufacturers, both historic and current. There is also presumably a device type for 3DWD/mixed use drives. A partial table of model codes for Seagate drives is

| Code | Model series |
|------|--------------|
| C | Constellation |
| D | Constellation ES.3 |
| E | Savvio 10K.6 |
| F | Constellation ES.4 |
| G | Constellation ES.5 |
| H | Enterprise Performance 10K.8 |
| K | Exos X14 |
| N | Exos X16 |
| O | Exos X18 |
