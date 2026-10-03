#/bin/bash
#
# Written by Digital Cabbage (last update 2023-07-02)
#
# This is free and unencumbered software released into the public domain.
#
# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.
#
# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# For more information, please refer to <https://unlicense.org>
#
#
# Flash hard drives removed from a HGST VSP system with generic firmware to
# enable them to accept SCSI_WRITE commands and be useful in other systems.
# This *ONLY* works for SAS-2/6Gbps Seagate drives. You will need to acquire
# the firmware yourself.
#
# The drive will also need reformating to either a 512 or 4096 byte block size
# depending on drive in question. This script refuses to run if that has not
# already been done.
#
# If called with -f all the drives on the system identified as coming from a
# VSP system based on the model string with a block size of 520 or 4168 will be
# formatted to 512/4096 respectively individually in a screen. This can take
# many hours. Using this option if they have multiple paths such as if they are
# in a JBOD with both ESM's connected is a *VERY* bad idea.
#
# If called with -t it runs smartctl against all drives on the system identified
# as coming from a VSP system. If the health is not "OK" or the number of
# reallocated sectors is greater than zero prints information on the drive
# including the failed tests. If -T is used report for all drives tested.
#


#
# The following serial numbers will let you download generic Seagate firmware
# from the Seagate website for the relevant drive models
#
#   DKS2E-H3R0SS: Z1Y0JJ5J (ST3000NM0023)
#   DKS2E-H4R0SS: Z1Z8CLYA (ST4000NM0023)
#   DKS5D-J900SS: 6XS2BPEC (ST9900805SS) 
#   DKS5E-J900SS: S0N1WQH7 (ST900MM0006)
#
# You will need to extract the ZIP file and copy the firmware file to the
# directory pointed to by LOCATION. They should have the following MD5 sums
# and be named as below.
#
#   6a03b216b6c6a7cc98b61e55b709160e  MegalodonES3-SAS-STD-E007.LOD
#   13e3bab907633af124b3f07cd9ac7ebe  CP-SAS-0004.LOD
#   e0b9643f81b094d79e47307170e9c663  Lightningbug10K6-STD-0004.LOD
#
# Given the firmware file is the same for all model types in a drive generation
# the firmware files probably work for other drives. This is just the list of
# known working drive/firmwares combinations.
#

LOCATION="/usr/local/lib/firmware"

declare -A firmware=(
	["DKS2E-H3R0SS"]="MegalodonES3-SAS-STD-E007.LOD"
	["DKS2E-H4R0SS"]="MegalodonES3-SAS-STD-E007.LOD"
	["DKS5D-J900SS"]="CP-SAS-0004.LOD"
	["DKS5E-J900SS"]="Lightningbug10K6-STD-0004.LOD"
)


#
# Print some basic help
#
print_help() {
    cat << 'EOF'
Write enable drives taken from an Hitachi VSP system

  -h  print this help
  -f  format all drives with a block size of 520/4160 to 512/4096 respectively
  -t  test the drives for health issues and report only bad drives
  -T  test the drives for health issues and report on all drives
  -d  download firmware to drives you can flash with generic firmware
  -r  reload the SAS driver to activate firmware

EOF
}


#
# Make sure the external executables needed are installed
#
check_dependencies() {
	local deps=(
		bc
		od
		lsscsi
		blockdev
		modprobe
		rmmod
		sg_format
		sg_write_buffer
		smartctl
	)

	local missing=0

	for cmd in "${deps[@]}"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "Missing dependency: $cmd" >&2
			missing=1
		fi
	done

	(( missing == 0 )) || exit 1
}


#
# Check to see if the drive is a suitable spinning SAS drive from a VSP system
#
# On drives taken from a VSP, the product identifier string is of the format
#
#   AABCD-EFFFGG
#
# where
#
#   AA  DK for spinning disks, SL for flash 1DWD drives and SF for flash 10DWD drives
#   B	B for Toshiba/Kioxia, M for Samsung, R for HGST/Hitachi and S for Seagate
#   C	2 for 3.5" drive and 5 for 2.5" drive
#   D	an uppercase letter which increases with new model series
#   E	H for 7200 RPM, J for 10k RPM, K for 15k RPM and M for SSD
#   FFF indicates the capacity of the drive
#         if it is three digits then it's the capacity in GB
#         if the 2nd or 3rd digit is an R it is a decimal point and the capacity is in TB
#   GG  AT for SATA drives, SS for SAS drives and NC for NVMe drives (there is probably a code for FC drives)
#
is_vsp() {
	local model="$1"

	# test product identifier string length
	[[ ${#model} -eq 12 ]] || return 1
 
	# test with one big regex (note we don't check the capacity field is valid)
	[[ "$model" =~ ^DK[RS][25][A-Z]-[HJK]...SS$ ]] || return 1
 
	 return 0
}


#
# Format a hard drive to either 512 or 4096 byte block size in a screen
#
format_drive() {
	local device="$1"

	block=`blockdev --getpbsz $device`
	if [[ "$block" == "520" ]]; then
		echo formatting $device to physical block size 512
		screen -S ${device:5:4} -d -m sg_format -v --format --size=512 $device
	elif [[ "$block" == "4160" ]]; then
		echo formatting $device to physical block size 4096
		screen -S ${device:5:4} -d -m sg_format -v --format --size=4096 $device
	fi

	return 0
}


#
# Perform some basic testing of the disk drive
#
test_drive() {
	local device="$1"

	local vendor=""
	local product=""
	local serial=""
	local health=""
	local defect=""

	# extract the required fields from the output of smartctl
	while IFS= read -r line; do
		if [[ $line =~ ^Vendor:[[:space:]]+(.+)$ ]]; then
			vendor="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^Product:[[:space:]]+(.+)$ ]]; then
			product="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^Serial[[:space:]]number:[[:space:]]+(.+)$ ]]; then
			serial="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^SMART[[:space:]]Health[[:space:]]Status:[[:space:]]+(.+)$ ]]; then
			health="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^Elements[[:space:]]in[[:space:]]grown[[:space:]]defect[[:space:]]list:[[:space:]]+([0-9]+)$ ]]; then
			defect="${BASH_REMATCH[1]}"
		fi
	done < <(smartctl --info --health --attributes "$device" 2>/dev/null)

	# trim Seagate serial numbers to match the label
	if [[ $vendor == "SEAGATE" ]]; then
		serial=${serial:0:8}
	fi

	local block=$(blockdev --getpbsz "$device" 2>/dev/null)
	local size=$(blockdev --getsize64 "$device" 2>/dev/null)

	if (( $size >= 1099511627776 )); then
		local capacity=$(printf "%.2f TiB" "$(echo "$size / 1099511627776" | bc -l)")
	else
		local capacity=$(printf "%.2f GiB" "$(echo "$size / 1073741824" | bc -l)")
	fi

	# print health info if requested or there is an issue
	if [[ $option == "-T" || "$health" != "OK" || ${defect:-0} -gt 0 ]]; then
		echo -e "$device\t$vendor\t$product\t$serial\t$block\t$capacity\t$defect\t$health"
	fi
}


#
# Attempt to flash a drive using sg_write_buffer
#
flash_drive() {
	local device="$1"
	local model="$2"

	local file="$LOCATION/${firmware[$model]}"

	if [[ -n "$file" ]]; then
		echo "sg_write_buffer -v --mode=dmc_save --in=$file $device"
#		sg_write_buffer -v --mode=dmc_save --in="$file" "$device"
	else
		echo "No firmware file defined for $model" >&2
		return 1
	fi

	return 0
}


# main logic

# only run if root
if (( EUID != 0 )); then
	echo "This script must be run as root" >&2
	exit 1
fi

check_dependencies

# a very basic test to see if the drives are multipathed 
if compgen -G "/dev/mapper/mpath*" > /dev/null; then
	echo "multipathing is enabled exiting before something is screwed up" >&2
	exit 1
fi

# some simple command line processing
option="${1:-}"

case "$option" in
	-h)
		print_help
		exit 0
		;;
	-t|-T)
		echo -e "DEVICE\t\tVENDOR\tMODEL\t\tSERIAL NO\tBLOCK\tCAPACITY\tREALLOCATED\tHEALTH"
		;;		
esac

# loop through the drives on the system
while read -r line; do
	read -ra fields <<< "$line"

	[[ "${fields[1]}" == "disk" ]] || continue

	model="${fields[${#fields[@]}-3]}"
	is_vsp "$model" || continue

	device="${fields[${#fields[@]}-1]}"

	case "$option" in
		-d)
			flash_drive "$device" "$model"
			;;
		-f)
			format_drive "$device"
			;;
		-t|-T)
			test_drive "$device"
			;;
		-r)
			rmmod mpt3sas
			modprobe mpt3sas
			;;
	esac
done < <(lsscsi)

exit 0
