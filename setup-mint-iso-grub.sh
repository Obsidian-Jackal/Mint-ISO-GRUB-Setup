#!/usr/bin/env bash
# Add a GRUB menu entry to boot a Linux Mint or LMDE live ISO from a file on disk.
# Ubuntu-based Mint: casper/ + iso-scan/filename=. LMDE: live/ + findiso=.
# Both ship boot/grub/loopback.cfg. Does not repartition disks.
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
CUSTOM_GRUB=/etc/grub.d/40_custom
# Keep backups outside /etc/grub.d/ — executable files there are run by update-grub.
BACKUP_DIR=/var/backups/grub.d
BACKUP_SUFFIX=$(date +%Y%m%d-%H%M%S)

# Prompts and status go to standard error; function results go to standard output
# so command substitutions like path=$(ensure_no_space_path ...) capture only the path.

say() { printf '%s\n' "$*" >&2; }
blank() { printf '\n' >&2; }

ask() {
	local prompt=$1
	local reply
	read -r -p "$prompt" reply
	printf '%s' "$reply"
}

# default=y → Enter means yes; default=n → Enter means no.
ask_yes_no() {
	local prompt=$1
	local default=${2:-y}
	local reply
	if [[ "$default" == y ]]; then
		read -r -p "$prompt [Y/n] " reply || true
		reply=${reply:-y}
	else
		read -r -p "$prompt [y/N] " reply || true
		reply=${reply:-n}
	fi
	[[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

# Print a message and exit non-zero.
exit_with_error() {
	say "Error: $*"
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || exit_with_error "Missing command: $1"
}

strip_wrapping_quotes() {
	local value=$1
	value=${value#\"}
	value=${value%\"}
	value=${value#\'}
	value=${value%\'}
	printf '%s' "$value"
}

downloads_directory() {
	if command -v xdg-user-dir >/dev/null 2>&1; then
		xdg-user-dir DOWNLOAD
		return
	fi
	printf '%s' "$HOME/Downloads"
}

# List Mint / LMDE ISO paths under a directory (stdout, one per line).
find_mint_isos() {
	local search_root=$1
	find "$search_root" -type f \( -iname 'linuxmint-*.iso' -o -iname 'lmde-*.iso' \) 2>/dev/null | sort
}

# Given candidate paths as arguments, print the chosen absolute path (stdout).
pick_iso_from_candidates() {
	local -a candidates=("$@")
	local candidate_count=${#candidates[@]}
	local index=0
	local choice
	local selected

	if [[ "$candidate_count" -eq 0 ]]; then
		return 1
	fi

	if [[ "$candidate_count" -eq 1 ]]; then
		say "Found: ${candidates[0]}"
		if ask_yes_no "Use this ISO?"; then
			realpath "${candidates[0]}"
			return 0
		fi
		return 1
	fi

	say "Found $candidate_count ISO file(s):"
	for selected in "${candidates[@]}"; do
		index=$((index + 1))
		say "  $index) $selected"
	done
	choice=$(ask "Number (1-$candidate_count): ")
	[[ "$choice" =~ ^[0-9]+$ ]] || exit_with_error "Not a number: $choice"
	if [[ "$choice" -lt 1 || "$choice" -gt "$candidate_count" ]]; then
		exit_with_error "Choice out of range: $choice"
	fi
	realpath "${candidates[choice - 1]}"
}

ask_iso_path_manually() {
	local iso_input
	say "Enter the full path to your linuxmint-*.iso or lmde-*.iso file."
	say "Tip: drag the file into this terminal, or paste the path, then press Enter."
	iso_input=$(ask "ISO path: ")
	[[ -n "$iso_input" ]] || exit_with_error "No path given."
	iso_input=$(strip_wrapping_quotes "$iso_input")
	resolve_iso_path "$iso_input"
}

# Multiple-choice locator → absolute ISO path on stdout.
prompt_for_iso_absolute_path() {
	local choice
	local downloads_dir
	local search_root
	local -a found_isos=()

	downloads_dir=$(downloads_directory)

	say "How do you want to locate the ISO?"
	say "  1) Search under home ($HOME)"
	say "  2) Search under Downloads ($downloads_dir)"
	say "  3) Enter the full path"
	choice=$(ask "Choice [1-3]: ")
	blank

	case "$choice" in
		1)
			search_root=$HOME
			;;
		2)
			search_root=$downloads_dir
			if [[ ! -d "$search_root" ]]; then
				exit_with_error "Downloads directory not found: $search_root"
			fi
			;;
		3)
			ask_iso_path_manually
			return
			;;
		*)
			exit_with_error "Expected 1, 2, or 3 (got: ${choice:-empty})"
			;;
	esac

	say "Searching for linuxmint-*.iso / lmde-*.iso under $search_root …"
	mapfile -t found_isos < <(find_mint_isos "$search_root")
	if [[ "${#found_isos[@]}" -eq 0 ]]; then
		say "No matching ISO files found there."
		if ask_yes_no "Enter the path manually instead?"; then
			ask_iso_path_manually
			return
		fi
		exit_with_error "Stopped. No ISO selected."
	fi

	if ! pick_iso_from_candidates "${found_isos[@]}"; then
		if ask_yes_no "Enter the path manually instead?"; then
			ask_iso_path_manually
			return
		fi
		exit_with_error "Stopped. No ISO selected."
	fi
}

# Guess official checksum base URL (no trailing slash) from a Mint ISO basename.
# Example: …/stable/22.3  or  …/debian
guess_checksum_base_url() {
	local iso_basename=$1
	local mint_version

	if [[ "$iso_basename" =~ ^linuxmint-([0-9]+\.[0-9]+)- ]]; then
		mint_version=${BASH_REMATCH[1]}
		printf '%s' "https://mirrors.kernel.org/linuxmint/stable/${mint_version}"
		return 0
	fi
	if [[ "$iso_basename" =~ ^lmde- ]]; then
		printf '%s' "https://mirrors.kernel.org/linuxmint/debian"
		return 0
	fi
	return 1
}

download_url_to_file() {
	local file_url=$1
	local destination=$2

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$destination" "$file_url"
		return
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$destination" "$file_url"
		return
	fi
	exit_with_error "Need curl or wget to download checksum files."
}

# Linux Mint release-signing key (sha256sum.txt.gpg). Same as linuxmint.com/verify.php.
MINT_SIGNING_KEY_FINGERPRINT=27DEB15644C6B3CF3BD7D291300F846BA25BAE09

ensure_mint_signing_key() {
	need_cmd gpg
	if gpg --list-keys "$MINT_SIGNING_KEY_FINGERPRINT" >/dev/null 2>&1; then
		return 0
	fi
	say "Importing Linux Mint signing key ($MINT_SIGNING_KEY_FINGERPRINT)…"
	if ! gpg --keyserver hkp://keys.openpgp.org:80 --recv-key "$MINT_SIGNING_KEY_FINGERPRINT"; then
		exit_with_error "Could not import the Linux Mint signing key from keys.openpgp.org."
	fi
}

verify_sha256sum_signature() {
	local sums_path=$1
	local gpg_path=$2

	ensure_mint_signing_key
	say "Checking authenticity of sha256sum.txt with sha256sum.txt.gpg…"
	if ! gpg --verify "$gpg_path" "$sums_path"; then
		exit_with_error "GPG signature check failed for $sums_path"
	fi
	say "Signature OK (Linux Mint signing key)."
}

# Interactive SHA-256 (+ GPG on the checksum list) using local files or URLs from the ISO name.
verify_iso_checksum() {
	local iso_absolute=$1
	local iso_directory
	local iso_basename
	local expected_line
	local verify_status=0
	local sums_path=
	local gpg_path=
	local checksum_base_url=
	local sums_url=
	local gpg_url=
	local temp_dir=
	local cleanup_temp=0

	iso_directory=$(dirname "$iso_absolute")
	iso_basename=$(basename "$iso_absolute")

	blank
	say "Verify the ISO with SHA-256 (and GPG on the checksum list when available)."
	if ! ask_yes_no "Run checksum verification now?"; then
		say "Skipping verification."
		blank
		return 0
	fi
	need_cmd sha256sum

	if [[ -f "$iso_directory/sha256sum.txt" ]]; then
		sums_path="$iso_directory/sha256sum.txt"
		say "Found checksum file: $sums_path"
	fi
	if [[ -f "$iso_directory/sha256sum.txt.gpg" ]]; then
		gpg_path="$iso_directory/sha256sum.txt.gpg"
		say "Found signature file: $gpg_path"
	fi

	if [[ -z "$sums_path" || -z "$gpg_path" ]]; then
		if ! checksum_base_url=$(guess_checksum_base_url "$iso_basename"); then
			[[ -n "$sums_path" ]] || exit_with_error "Could not guess checksum URLs for: $iso_basename"
			say "Could not guess a download URL for the missing signature file; integrity check only."
		else
			sums_url="${checksum_base_url}/sha256sum.txt"
			gpg_url="${checksum_base_url}/sha256sum.txt.gpg"
			temp_dir=$(mktemp -d /tmp/mint-iso-verify.XXXXXX)
			cleanup_temp=1
			say "Fetching official checksum files for $iso_basename from:"
			say "  $checksum_base_url/"
			if [[ -z "$sums_path" ]]; then
				say "Downloading sha256sum.txt…"
				download_url_to_file "$sums_url" "$temp_dir/sha256sum.txt"
				sums_path="$temp_dir/sha256sum.txt"
			fi
			if [[ -z "$gpg_path" ]]; then
				say "Downloading sha256sum.txt.gpg…"
				if download_url_to_file "$gpg_url" "$temp_dir/sha256sum.txt.gpg"; then
					gpg_path="$temp_dir/sha256sum.txt.gpg"
				else
					say "Warning: could not download sha256sum.txt.gpg; integrity check only."
				fi
			fi
		fi
	fi

	[[ -n "$sums_path" && -f "$sums_path" ]] || exit_with_error "No sha256sum.txt available."

	if [[ -n "$gpg_path" && -f "$gpg_path" ]]; then
		if command -v gpg >/dev/null 2>&1; then
			verify_sha256sum_signature "$sums_path" "$gpg_path"
		else
			say "Warning: gpg not installed; skipping authenticity check of sha256sum.txt."
		fi
	else
		say "Warning: no sha256sum.txt.gpg; integrity check only (checksum list not authenticated)."
	fi

	expected_line=$(grep -F -- "$iso_basename" "$sums_path" || true)
	if [[ -z "$expected_line" ]]; then
		[[ "$cleanup_temp" -eq 1 ]] && rm -rf "$temp_dir"
		exit_with_error "No line for $iso_basename in $sums_path"
	fi

	say "Checking SHA-256 for $iso_basename (this can take a minute)…"
	# Run from the ISO's directory so relative paths in sha256sum.txt resolve.
	if ! (cd "$iso_directory" && printf '%s\n' "$expected_line" | sha256sum -c -); then
		verify_status=1
	fi

	[[ "$cleanup_temp" -eq 1 ]] && rm -rf "$temp_dir"

	if [[ "$verify_status" -ne 0 ]]; then
		exit_with_error "Checksum failed. Re-download the ISO (or the checksum file) and try again."
	fi
	say "Checksum OK."
	blank
}

# Archive listing of an ISO (stdout). Needs 7z or isoinfo.
iso_archive_listing() {
	local iso_path=$1

	if command -v 7z >/dev/null 2>&1; then
		7z l -ba "$iso_path" 2>/dev/null || true
		return 0
	fi
	if command -v isoinfo >/dev/null 2>&1; then
		isoinfo -l -i "$iso_path" 2>/dev/null || true
		return 0
	fi
	exit_with_error "Need 7z or isoinfo to inspect the ISO without mounting (install p7zip-full or genisoimage)."
}

# Detect flavor: prints "ubuntu" (casper) or "lmde" (live).
detect_mint_iso_flavor() {
	local iso_path=$1
	local listing

	listing=$(iso_archive_listing "$iso_path")

	if [[ "$listing" == *"casper/vmlinuz"* && "$listing" == *"casper/initrd.lz"* ]]; then
		printf '%s' ubuntu
		return 0
	fi
	if [[ "$listing" == *"live/vmlinuz"* && "$listing" == *"live/initrd.lz"* ]]; then
		printf '%s' lmde
		return 0
	fi
	# Joliet / Rock Ridge uppercase from isoinfo.
	if [[ "$listing" == *CASPER* && "$listing" == *VMLINUZ* && "$listing" == *INITRD* ]]; then
		printf '%s' ubuntu
		return 0
	fi
	if [[ "$listing" == *"/LIVE"* || "$listing" == *" LIVE"* ]] && [[ "$listing" == *VMLINUZ* && "$listing" == *INITRD* ]]; then
		printf '%s' lmde
		return 0
	fi

	exit_with_error "Unrecognized Mint ISO (need casper/ for Ubuntu-based Mint, or live/ for LMDE)."
}

path_has_spaces() {
	[[ "$1" == *" "* ]]
}

# Expand ~ and resolve to an absolute path; fail if the file is missing.
resolve_iso_path() {
	local raw=$1
	raw=${raw/#\~/$HOME}
	if [[ -f "$raw" ]]; then
		realpath "$raw"
		return
	fi
	exit_with_error "ISO not found: $1"
}

# iso-scan/filename= and findiso= break when the path has spaces. If needed,
# hardlink the ISO to <mount>/boot-isos/<basename> on the same filesystem.
# Prints the path GRUB should use (stdout).
ensure_no_space_path() {
	local source_iso=$1
	local mount_point=$2
	local basename_iso
	local target_dir
	local target_iso

	basename_iso=$(basename "$source_iso")
	if ! path_has_spaces "$source_iso" && ! path_has_spaces "$basename_iso"; then
		printf '%s' "$source_iso"
		return
	fi

	say "This ISO path has spaces. GRUB cannot pass it via iso-scan/filename= or findiso= until the path has no spaces."
	target_dir="$mount_point/boot-isos"
	say "A hard link will be created at: $target_dir/$basename_iso"
	say "(Same disk, no extra space used. Original file stays where it is.)"
	if ! ask_yes_no "Create that hard link now?"; then
		exit_with_error "Stopped. Move or hardlink the ISO to a path without spaces, then run $SCRIPT_NAME again."
	fi
	mkdir -p "$target_dir"
	target_iso="$target_dir/$basename_iso"
	if [[ -e "$target_iso" ]]; then
		say "Already exists: $target_iso"
	else
		# ln without -s = hard link; fails across filesystems.
		if ! ln "$source_iso" "$target_iso" 2>/dev/null; then
			exit_with_error "Hard link failed (ISO may be on a different filesystem). Copy or move the ISO onto this partition under a path with no spaces, then re-run."
		fi
		say "Hard link created."
	fi
	printf '%s' "$target_iso"
}

# Path of the ISO relative to the filesystem root (what GRUB sees after search).
# Example: file at /mnt/data/boot-isos/foo.iso → /boot-isos/foo.iso
grub_path_on_partition() {
	local absolute_iso=$1
	local mount_point=$2
	local relative
	relative=$(realpath --relative-to="$mount_point" "$absolute_iso")
	printf '/%s' "$relative"
}

# Primary entry for both flavors: ISO loopback.cfg (exports iso_path).
# Ubuntu Mint uses iso-scan/filename=${iso_path}; LMDE uses findiso=${iso_path}.
# \$isofile is escaped so bash does not expand it; GRUB expands $isofile at boot.
build_loopback_cfg_block() {
	local menu_title=$1
	local partition_uuid=$2
	local isofile_grub_path=$3
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
	insmod part_gpt
	insmod part_msdos
	insmod ext2
	search --no-floppy --fs-uuid --set=root $partition_uuid
	set isofile="$isofile_grub_path"
	loopback loop \$isofile
	set root=(loop)
	set iso_path=\$isofile
	export iso_path
	configfile /boot/grub/loopback.cfg
}
EOF
}

# Fallback: Ubuntu-based Mint — direct casper (no ISO GRUB submenu).
build_ubuntu_casper_fallback_block() {
	local menu_title=$1
	local partition_uuid=$2
	local isofile_grub_path=$3
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
	insmod part_gpt
	insmod part_msdos
	insmod ext2
	search --no-floppy --fs-uuid --set=root $partition_uuid
	set isofile="$isofile_grub_path"
	loopback loop \$isofile
	linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=\$isofile quiet noeject noprompt splash --
	initrd (loop)/casper/initrd.lz
}
EOF
}

# Fallback: LMDE — direct live kernel with findiso= (no ISO GRUB submenu).
build_lmde_live_fallback_block() {
	local menu_title=$1
	local partition_uuid=$2
	local isofile_grub_path=$3
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
	insmod part_gpt
	insmod part_msdos
	insmod ext2
	search --no-floppy --fs-uuid --set=root $partition_uuid
	set isofile="$isofile_grub_path"
	loopback loop \$isofile
	linux (loop)/live/vmlinuz boot=live live-config live-media-path=/live findiso=\$isofile quiet splash --
	initrd (loop)/live/initrd.lz
}
EOF
}

main() {
	need_cmd lsblk
	need_cmd findmnt
	need_cmd realpath
	need_cmd update-grub
	need_cmd sudo
	need_cmd find

	say "=== Boot Linux Mint / LMDE live ISO from GRUB (guided) ==="
	say "This adds a GRUB menu entry so you can boot a Mint or LMDE ISO file from disk."
	say "It will not repartition anything."
	blank
	if ! ask_yes_no "Continue?"; then
		say "Cancelled."
		exit 0
	fi
	blank

	local iso_absolute mount_point filesystem_type partition_uuid
	local iso_for_grub grub_relative_path menu_title entry_block fallback_block
	local custom_backup include_fallback
	local iso_flavor default_menu_title fallback_label

	iso_absolute=$(prompt_for_iso_absolute_path)
	say "Using: $iso_absolute"
	blank

	verify_iso_checksum "$iso_absolute"

	# findmnt --target walks up to the mount that owns this file.
	mount_point=$(findmnt -n -o TARGET --target "$iso_absolute") || exit_with_error "Could not find mount point for that file."
	filesystem_type=$(findmnt -n -o FSTYPE --target "$iso_absolute") || true
	partition_uuid=$(findmnt -n -o UUID --target "$iso_absolute") || exit_with_error "Could not read filesystem UUID (GRUB needs this)."

	say "Partition mount: $mount_point"
	say "Filesystem:      ${filesystem_type:-unknown}"
	say "UUID:            $partition_uuid"
	blank

	# ext2 GRUB module covers ext2/3/4. Other FS types need different insmod lines.
	case "${filesystem_type:-}" in
		ext2|ext3|ext4) ;;
		*)
			say "Warning: filesystem is '${filesystem_type:-unknown}'. This helper expects ext4 (or ext2/3)."
			if ! ask_yes_no "Continue anyway?" n; then
				exit_with_error "Stopped."
			fi
			;;
	esac

	say "Detecting ISO layout (Ubuntu-based Mint casper/ vs LMDE live/)…"
	iso_flavor=$(detect_mint_iso_flavor "$iso_absolute")
	if [[ "$iso_flavor" == ubuntu ]]; then
		say "Detected: Ubuntu-based Linux Mint (casper/)."
		default_menu_title="Linux Mint Live ISO"
		fallback_label="direct casper"
	else
		say "Detected: LMDE (live/ + findiso=)."
		default_menu_title="LMDE Live ISO"
		fallback_label="direct live"
	fi
	blank

	iso_for_grub=$(ensure_no_space_path "$iso_absolute" "$mount_point")
	grub_relative_path=$(grub_path_on_partition "$iso_for_grub" "$mount_point")
	if path_has_spaces "$grub_relative_path"; then
		exit_with_error "GRUB path still contains spaces: $grub_relative_path"
	fi

	# Name shown in GRUB — not a yes/no prompt (easy to confuse after [Y/n] questions).
	say "Choose the name that will appear in the GRUB boot menu."
	say "Press Enter to use the default: $default_menu_title"
	menu_title=$(ask "Menu name: ")
	menu_title=${menu_title:-$default_menu_title}
	case "${menu_title,,}" in
		y|n|yes|no)
			say "That looks like a yes/no answer; using the default name instead."
			menu_title=$default_menu_title
			;;
	esac
	blank

	say "Proposed primary entry (ISO loopback.cfg):"
	say "----------------------------------------"
	entry_block=$(build_loopback_cfg_block "$menu_title" "$partition_uuid" "$grub_relative_path")
	printf '%s\n' "$entry_block" >&2
	say "----------------------------------------"
	blank

	include_fallback=0
	if ask_yes_no "Also add a fallback '$fallback_label' entry?" n; then
		include_fallback=1
		if [[ "$iso_flavor" == ubuntu ]]; then
			fallback_block=$(build_ubuntu_casper_fallback_block "$menu_title ($fallback_label)" "$partition_uuid" "$grub_relative_path")
		else
			fallback_block=$(build_lmde_live_fallback_block "$menu_title ($fallback_label)" "$partition_uuid" "$grub_relative_path")
		fi
		say "Fallback entry will be added too."
		blank
	fi

	if [[ ! -f "$CUSTOM_GRUB" ]]; then
		exit_with_error "Missing $CUSTOM_GRUB (unexpected on Mint/Ubuntu). Install grub and try again."
	fi

	# Avoid silently duplicating the same isofile path.
	if grep -qF "set isofile=\"$grub_relative_path\"" "$CUSTOM_GRUB" 2>/dev/null; then
		say "An entry for this ISO path already exists in $CUSTOM_GRUB."
		if ! ask_yes_no "Append another copy anyway?" n; then
			say "No changes made."
			exit 0
		fi
	fi

	if ! ask_yes_no "Write this into $CUSTOM_GRUB and run update-grub?"; then
		say "Cancelled. No changes made."
		exit 0
	fi

	custom_backup="${BACKUP_DIR}/40_custom.bak.${BACKUP_SUFFIX}"
	sudo mkdir -p "$BACKUP_DIR"
	sudo cp -a "$CUSTOM_GRUB" "$custom_backup"
	say "Backup: $custom_backup"

	# Append only; keeps any other custom entries already in 40_custom.
	{
		printf '%s\n' "$entry_block"
		if [[ "$include_fallback" -eq 1 ]]; then
			printf '%s\n' "$fallback_block"
		fi
	} | sudo tee -a "$CUSTOM_GRUB" >/dev/null

	say "Running update-grub…"
	sudo update-grub
	blank
	say "Done."
	say "1. Reboot."
	say "2. At the GRUB menu, choose: $menu_title"
	say "   (If the menu is hidden, hold Shift or press Esc during boot.)"
	say "3. If boot fails with a loopback error, try with Secure Boot disabled."
	say "To undo: restore $custom_backup over $CUSTOM_GRUB, then sudo update-grub"
}

main "$@"
