#!/bin/bash
#
# Written by digitalcabbage (last update 2026-10-01)
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
# Set least significant bit in byte 0x14 of mode page 0x38 on hard drives
# removed from a HGST VSP system to enable them to accept SCSI_WRITE commands
# and be useful in other systems.
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
# Print some basic help
#
print_help() {
    cat << 'EOF'
Write enable drives taken from an Hitachi VSP system

  -h  print this help
  -f  format all drives with a block size of 520/4160 to 512/4096 respectively
  -t  test the drives for health issues and report only bad drives
  -T  test the drives for health issues and report on all drives
  -e  enable SCSI_WRITE on all the drives not currently enabled

with no options it displays the write state of VSP drives on the system
EOF
}


#
# Make sure the external executables needed are installed
#
check_dependencies() {
	local deps=(
		od
		lsscsi
		blockdev
		sg_modes
		sg_wr_mode
		sg_format
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
 
	# test with one big regex (not we don't check the capacity field is valid)
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

	local block=$(blockdev --getpbsz "$device" 2>/dev/null)
	local size=$(blockdev --getsize64 "$device" 2>/dev/null)

	if (( $size >= 1099511627776 )); then
		local capacity=$(printf "%.2f TiB" "$(echo "$size / 1099511627776" | bc -l)")
	else
		local capacity=$(printf "%.2f GiB" "$(echo "$size / 1073741824" | bc -l)")
	fi

	# only print health info if there is an issue
	if [[ $option == "-T" || "$health" != "OK" || ${defect:-0} -gt 0 ]]; then
		echo -e "$device\t$vendor\t$product\t$serial\t$block\t$capacity\t$defect\t$health"
	fi
}


#
# Get the writable status of a VSP drive from mode page 0x38
#
get_vsp_writeable() {
	local device="$1"

	local byte
	byte=$(sg_modes --page=0x38 --raw "$device" | od -An -j36 -N1 -tu1)

	echo $(( byte & 0x01 ))
}


#
# Write enable by setting the least significant bit on byte 0x14 of mode page 0x38
#
vsp_write_enable() {
	local device="$1"

	local contents="0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1"
	local mask="0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1"

	sg_wr_mode --page=0x38 --contents="$contents" --mask="$mask" --save "$device" 2>/dev/null

	return $?
}


# main logic
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
	-t)
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
		-e)
			block=$(blockdev --getpbsz "$device")

			if [[ "$block" != "512" && "$block" != "4096" ]]; then
				echo "$device needs formatting to a standard blocksize first" >&2
				continue
			fi

			if (( $(get_vsp_writeable "$device") == 0 )); then
				vsp_write_enable "$device"
			fi
			;;
		-f)
			format_drive "$device"
			;;
		-t)
			test_drive "$device"
			;;
		-T)
			test_drive "$device"
			;;
		*)
			echo "$device: $(get_vsp_writeable "$device")"
			;;
	esac
done < <(lsscsi)
