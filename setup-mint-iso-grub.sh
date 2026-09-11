#!/usr/bin/env bash
# Add a GRUB menu entry to boot a Linux Mint or LMDE live ISO from a file on disk.
# Ubuntu-based Mint: casper/ + iso-scan/filename=. LMDE: live/ + findiso=.
# Prefers boot/grub/loopback.cfg when present. Does not repartition disks.
# Optional: --dry-run (preview only; may use temp files).
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
CUSTOM_GRUB=/etc/grub.d/40_custom
# Keep backups outside /etc/grub.d/ — executable files there are run by update-grub.
BACKUP_DIR=/var/backups/grub.d
BACKUP_SUFFIX=$(date +%Y%m%d-%H%M%S)
DRY_RUN=0

CLEANUP_PATHS=()
register_cleanup_path() {
	CLEANUP_PATHS+=("$1")
}
unregister_cleanup_path() {
	local path=$1
	local -a retained=()
	local item

	for item in "${CLEANUP_PATHS[@]}"; do
		[[ "$item" == "$path" ]] || retained+=("$item")
	done
	if [[ ${#retained[@]} -eq 0 ]]; then
		CLEANUP_PATHS=()
	else
		CLEANUP_PATHS=("${retained[@]}")
	fi
}
cleanup_registered_paths() {
	local cleanup_path
	for cleanup_path in "${CLEANUP_PATHS[@]}"; do
		rm -rf -- "$cleanup_path"
	done
}
trap cleanup_registered_paths EXIT

# Linux Mint release-signing key (sha256sum.txt.gpg). Same as linuxmint.com/verify.php.
MINT_SIGNING_KEY_FINGERPRINT=27DEB15644C6B3CF3BD7D291300F846BA25BAE09

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

# Exact basename match in sha256sum.txt (stdout). Fails unless exactly one hit.
checksum_line_for_basename() {
	local sums_path=$1
	local iso_basename=$2
	local matched_line

	matched_line=$(
		awk -v name="$iso_basename" '
			NF >= 2 {
				filename = $2
				sub(/^\*/, "", filename)
				if (filename == name) {
					print
					found++
				}
			}
			END {
				if (found != 1) exit 1
			}
		' "$sums_path"
	) || return 1
	printf '%s' "$matched_line"
}

# Verify sha256sum.txt.gpg in an isolated GNUPGHOME.
verify_sha256sum_signature() {
	local sums_path=$1
	local gpg_path=$2
	local gpg_home
	local listed_fingerprint

	need_cmd gpg
	gpg_home=$(mktemp -d /tmp/mint-iso-gpg.XXXXXX)
	chmod 700 "$gpg_home"
	register_cleanup_path "$gpg_home"

	say "Importing Linux Mint signing key into a temporary GPG home…"
	if ! GNUPGHOME="$gpg_home" gpg --keyserver hkps://keys.openpgp.org \
		--recv-key "$MINT_SIGNING_KEY_FINGERPRINT"; then
		say "HKPS key fetch failed; retrying over plaintext HKP (fingerprint is still checked)."
		if ! GNUPGHOME="$gpg_home" gpg --keyserver hkp://keys.openpgp.org:80 \
			--recv-key "$MINT_SIGNING_KEY_FINGERPRINT"; then
			exit_with_error "Could not import the Linux Mint signing key from keys.openpgp.org."
		fi
	fi

	listed_fingerprint=$(
		GNUPGHOME="$gpg_home" gpg --with-colons --fingerprint "$MINT_SIGNING_KEY_FINGERPRINT" 2>/dev/null \
			| awk -F: '/^fpr:/ { print $10; exit }'
	)
	if [[ "${listed_fingerprint^^}" != "${MINT_SIGNING_KEY_FINGERPRINT^^}" ]]; then
		exit_with_error "Imported key fingerprint mismatch (got ${listed_fingerprint:-none})."
	fi

	say "Checking authenticity of sha256sum.txt with sha256sum.txt.gpg…"
	if ! GNUPGHOME="$gpg_home" gpg --verify "$gpg_path" "$sums_path"; then
		exit_with_error "GPG signature check failed for $sums_path"
	fi
	say "Signature valid under the expected Linux Mint release-key hierarchy."
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
			register_cleanup_path "$temp_dir"
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
		need_cmd gpg
		verify_sha256sum_signature "$sums_path" "$gpg_path"
	else
		say "Warning: no sha256sum.txt.gpg; integrity check only (checksum list not authenticated)."
		if ! ask_yes_no "Continue without authenticating the checksum list?" n; then
			exit_with_error "Stopped. Download sha256sum.txt.gpg next to the ISO (or re-run and allow the download) and try again."
		fi
	fi

	if ! expected_line=$(checksum_line_for_basename "$sums_path" "$iso_basename"); then
		exit_with_error "Could not find exactly one checksum entry for $iso_basename in $sums_path"
	fi
	if [[ ! "$expected_line" =~ ^[[:xdigit:]]{64}[[:space:]] ]]; then
		exit_with_error "Malformed SHA-256 entry for $iso_basename"
	fi

	say "Checking SHA-256 for $iso_basename (this can take a minute)…"
	# Run from the ISO's directory so relative paths in sha256sum.txt resolve.
	if ! (cd "$iso_directory" && printf '%s\n' "$expected_line" | sha256sum -c -); then
		verify_status=1
	fi

	if [[ "$verify_status" -ne 0 ]]; then
		exit_with_error "Checksum failed. Re-download the ISO (or the checksum file) and try again."
	fi
	say "Checksum OK."
	blank
}

# Write an archive listing of an ISO to a file. Prefer 7z; isoinfo is best-effort.
# Sets ISO_LISTING_TOOL to 7z or isoinfo.
ISO_LISTING_TOOL=
iso_archive_listing_to_file() {
	local iso_path=$1
	local listing_file=$2

	ISO_LISTING_TOOL=
	if command -v 7z >/dev/null 2>&1; then
		if ! 7z l -ba "$iso_path" >"$listing_file" 2>/dev/null; then
			exit_with_error "Could not inspect the ISO with 7z (unreadable or corrupt?): $iso_path"
		fi
		ISO_LISTING_TOOL=7z
		return 0
	fi
	if command -v isoinfo >/dev/null 2>&1; then
		say "7z not found; using isoinfo (best-effort listing format)."
		if ! isoinfo -l -i "$iso_path" >"$listing_file" 2>/dev/null; then
			exit_with_error "Could not inspect the ISO with isoinfo (unreadable or corrupt?): $iso_path"
		fi
		ISO_LISTING_TOOL=isoinfo
		return 0
	fi
	exit_with_error "Need 7z (preferred) or isoinfo to inspect the ISO without mounting (install p7zip-full or genisoimage)."
}

# True when path_lower is casper|live / initrd with no slash or space in the basename.
is_safe_initrd_grub_path_lower() {
	local path_lower=$1
	local rest

	case "$path_lower" in
		casper/initrd|casper/initrd.*|live/initrd|live/initrd.*)
			rest=${path_lower#*/}
			case "$rest" in
				*[/[:space:]]*) return 1 ;;
				*) return 0 ;;
			esac
			;;
		*)
			return 1
			;;
	esac
}

# Pick casper|live initrd* from a listing file (stdout). Preserves archive path case.
pick_initrd_path_from_listing_file() {
	local listing_file=$1
	local prefix=$2
	local candidate
	local candidate_lower
	local best=
	local preferred=
	local rest

	case "$prefix" in
		casper|live) ;;
		*) return 1 ;;
	esac

	while IFS= read -r candidate; do
		candidate=${candidate#./}
		candidate=${candidate//$'\r'/}
		candidate_lower=${candidate,,}
		case "$candidate_lower" in
			"${prefix}/initrd.lz"|"${prefix}/initrd.gz"|"${prefix}/initrd")
				preferred=$candidate
				break
				;;
			"${prefix}/initrd"*)
				rest=${candidate_lower#"${prefix}/"}
				case "$rest" in
					*[/[:space:]]*) ;;
					initrd|initrd.*)
						[[ -z "$best" ]] && best=$candidate
						;;
				esac
				;;
		esac
	done < <(
		awk -v prefix="$prefix" 'BEGIN{IGNORECASE=1}
			{
				for (field_index = 1; field_index <= NF; field_index++) {
					path = $field_index
					gsub(/^\.\//, "", path)
					gsub(/\r/, "", path)
					if (path ~ ("^" prefix "/initrd[^/[:space:]]*$")) print path
				}
			}' "$listing_file"
	)

	if [[ -n "$preferred" ]]; then
		printf '%s' "$preferred"
		return 0
	fi
	if [[ -n "$best" ]]; then
		printf '%s' "$best"
		return 0
	fi
	return 1
}

require_initrd_grub_path() {
	local initrd_path=$1
	local path_lower=${initrd_path,,}

	if ! is_safe_initrd_grub_path_lower "$path_lower"; then
		exit_with_error "Detected unsafe or invalid initrd path: ${initrd_path:-empty}"
	fi
}

listing_file_has_loopback_cfg() {
	local listing_file=$1
	grep -Eiq '(^|[[:space:]/])boot/grub/loopback\.cfg($|[[:space:]])' "$listing_file" \
		|| grep -Eiq '(^|[[:space:]/])BOOT/GRUB/LOOPBACK\.CFG($|[[:space:]])' "$listing_file"
}

# Detect flavor from a listing file: prints "ubuntu"|"lmde", then the initrd path.
detect_mint_iso_layout_from_listing_file() {
	local listing_file=$1
	local initrd_path

	if grep -Eiq '(^|[[:space:]/])casper/vmlinuz($|[[:space:]])' "$listing_file"; then
		if initrd_path=$(pick_initrd_path_from_listing_file "$listing_file" casper); then
			require_initrd_grub_path "$initrd_path"
			printf '%s %s' ubuntu "$initrd_path"
			return 0
		fi
	fi
	if grep -Eiq '(^|[[:space:]/])live/vmlinuz($|[[:space:]])' "$listing_file"; then
		if initrd_path=$(pick_initrd_path_from_listing_file "$listing_file" live); then
			require_initrd_grub_path "$initrd_path"
			printf '%s %s' lmde "$initrd_path"
			return 0
		fi
	fi
	# Joliet / Rock Ridge uppercase from isoinfo.
	if grep -Eiq 'CASPER' "$listing_file" \
		&& grep -Eiq 'VMLINUZ' "$listing_file" \
		&& initrd_path=$(pick_initrd_path_from_listing_file "$listing_file" casper); then
		require_initrd_grub_path "$initrd_path"
		printf '%s %s' ubuntu "$initrd_path"
		return 0
	fi
	if grep -Eiq '(^|[[:space:]/])LIVE($|[[:space:]/])' "$listing_file" \
		&& grep -Eiq 'VMLINUZ' "$listing_file" \
		&& initrd_path=$(pick_initrd_path_from_listing_file "$listing_file" live); then
		require_initrd_grub_path "$initrd_path"
		printf '%s %s' lmde "$initrd_path"
		return 0
	fi

	exit_with_error "Unrecognized Mint ISO (need casper/ for Ubuntu-based Mint, or live/ for LMDE, with an initrd*)."
}

# True when path is safe to embed in generated GRUB config.
path_safe_for_grub() {
	[[ "$1" =~ ^[A-Za-z0-9._+/()-]+$ ]]
}

sanitize_menu_title() {
	local menu_title=$1
	local cleaned
	cleaned=$(printf '%s' "$menu_title" | tr -cd 'A-Za-z0-9 _.()+:/-')
	if [[ -z "$menu_title" || "$cleaned" != "$menu_title" ]]; then
		exit_with_error "Menu name contains unsupported characters. Use letters, numbers, spaces, and ._()+:/- only."
	fi
	printf '%s' "$menu_title"
}

require_filesystem_uuid() {
	local filesystem_uuid=$1
	if [[ ! "$filesystem_uuid" =~ ^[[:alnum:]_.:-]+$ ]]; then
		exit_with_error "Unexpected filesystem UUID format: ${filesystem_uuid:-empty}"
	fi
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

# True if module.mod exists under /boot/grub or /usr/lib/grub.
grub_module_exists() {
	local module=$1
	local found
	found=$(find /boot/grub /usr/lib/grub -type f -name "${module}.mod" -print -quit 2>/dev/null || true)
	[[ -n "$found" ]]
}

require_grub_module() {
	local module=$1
	grub_module_exists "$module" || exit_with_error "GRUB module not found on this system: ${module}.mod"
}

# Entries use the GRUB `search` command; require search.mod.
grub_search_module() {
	require_grub_module search
	printf '%s' search
}

require_loopback_iso_modules() {
	if ! grub_module_exists part_gpt && ! grub_module_exists part_msdos; then
		exit_with_error "Neither part_gpt.mod nor part_msdos.mod is installed."
	fi
	require_grub_module search
	require_grub_module loopback
	if ! grub_module_exists iso9660 && ! grub_module_exists udf; then
		exit_with_error "Neither iso9660.mod nor udf.mod is installed."
	fi
}

# GRUB filesystem module for a findmnt FSTYPE (empty if unsupported).
grub_fs_module_for_fstype() {
	case "${1,,}" in
		ext2|ext3|ext4|ext4dev) printf '%s' 'ext2' ;;
		xfs) printf '%s' 'xfs' ;;
		vfat|fat|msdos|fat32) printf '%s' 'fat' ;;
		exfat|fuse.exfat) printf '%s' 'exfat' ;;
		btrfs) printf '%s' 'btrfs' ;;
		*) printf '%s' '' ;;
	esac
}

filesystem_allows_hardlinks() {
	case "${1,,}" in
		ext2|ext3|ext4|ext4dev|xfs|btrfs) return 0 ;;
		*) return 1 ;;
	esac
}

same_file_inode() {
	local left=$1
	local right=$2
	[[ -e "$left" && -e "$right" ]] \
		&& [[ "$(stat -c '%d:%i' "$left")" == "$(stat -c '%d:%i' "$right")" ]]
}

same_filesystem_device() {
	local left=$1
	local right=$2
	[[ -e "$left" && -e "$right" ]] \
		&& [[ "$(stat -c '%d' "$left")" == "$(stat -c '%d' "$right")" ]]
}

# Copy ISO to target via a unique temporary file, then rename.
copy_iso_to_target() {
	local source_iso=$1
	local target_iso=$2
	local target_dir
	local temp_target

	target_dir=$(dirname -- "$target_iso")
	require_free_space_for_copy "$target_dir" "$source_iso"

	temp_target=$(mktemp --tmpdir="$target_dir" \
		".$(basename -- "$target_iso").part.XXXXXX") \
		|| exit_with_error "Could not create temporary copy path under $target_dir."
	register_cleanup_path "$temp_target"

	if ! cp -- "$source_iso" "$temp_target"; then
		rm -f -- "$temp_target"
		exit_with_error "Copy failed; incomplete file removed."
	fi
	if ! mv -f -- "$temp_target" "$target_iso"; then
		rm -f -- "$temp_target"
		exit_with_error "Could not finalize copied ISO at $target_iso."
	fi
	unregister_cleanup_path "$temp_target"
}

require_free_space_for_copy() {
	local target_dir=$1
	local source_iso=$2
	local iso_bytes
	local free_bytes

	iso_bytes=$(stat -c '%s' "$source_iso")
	free_bytes=$(df -P -B1 "$target_dir" | awk 'NR==2 { print $4 }')
	if [[ ! "$free_bytes" =~ ^[0-9]+$ ]]; then
		exit_with_error "Could not determine free space under $target_dir."
	fi
	if [[ "$free_bytes" -lt "$iso_bytes" ]]; then
		exit_with_error "Not enough free space to copy the ISO (${iso_bytes} bytes needed, ${free_bytes} available under $target_dir)."
	fi
}

warn_if_fat32_iso_too_large() {
	local iso_path=$1
	local filesystem_type=$2
	local iso_bytes
	local fat32_max=$((4 * 1024 * 1024 * 1024 - 1))

	case "${filesystem_type,,}" in
		vfat|fat|msdos|fat32) ;;
		*) return 0 ;;
	esac
	iso_bytes=$(stat -c '%s' "$iso_path" 2>/dev/null || echo 0)
	if ((iso_bytes > fat32_max)); then
		exit_with_error "FAT32 cannot store files larger than 4 GiB − 1 (this ISO is ${iso_bytes} bytes). Use exFAT, XFS, ext4, or Btrfs."
	fi
}

require_supported_filesystem() {
	local filesystem_type=$1
	local grub_fs_module

	grub_fs_module=$(grub_fs_module_for_fstype "$filesystem_type")
	if [[ -z "$grub_fs_module" ]]; then
		exit_with_error "Unsupported filesystem for this helper: ${filesystem_type:-unknown}. Supported: ext2/3/4, XFS, FAT32 (vfat), exFAT, Btrfs."
	fi
	require_grub_module "$grub_fs_module"
	if [[ "${filesystem_type,,}" == btrfs ]]; then
		say "Note: Btrfs support uses search --fs-uuid. If the ISO lives on a non-default subvolume, GRUB may not see that path; keep the ISO on the subvolume GRUB mounts for this UUID."
	fi
	printf '%s' "$grub_fs_module"
}

# Basename safe for GRUB under <mount>/boot-isos/.
safe_boot_iso_basename() {
	local source_basename=$1
	local cleaned

	cleaned=${source_basename// /-}
	cleaned=${cleaned//[^A-Za-z0-9._+-]/}
	if [[ -z "$cleaned" ]]; then
		cleaned=mint-live.iso
	elif [[ "${cleaned,,}" == *.iso ]]; then
		cleaned="${cleaned:0:$((${#cleaned} - 4))}.iso"
	else
		cleaned="${cleaned}.iso"
	fi
	if ! path_safe_for_grub "$cleaned"; then
		cleaned=mint-live.iso
	fi
	printf '%s' "$cleaned"
}

# Choose a free or reusable name under target_dir (creates nothing).
choose_boot_iso_target() {
	local source_iso=$1
	local target_dir=$2
	local preferred_basename=$3
	local stem=${preferred_basename%.iso}
	local candidate=$preferred_basename
	local index=2
	local target_iso

	while true; do
		target_iso="$target_dir/$candidate"
		if [[ ! -e "$target_iso" ]]; then
			printf '%s' "$target_iso"
			return 0
		fi
		if same_file_inode "$source_iso" "$target_iso"; then
			printf '%s' "$target_iso"
			return 0
		fi
		if [[ "$DRY_RUN" -eq 0 ]] && [[ -f "$target_iso" ]] && cmp -s -- "$source_iso" "$target_iso" 2>/dev/null; then
			printf '%s' "$target_iso"
			return 0
		fi
		candidate="${stem}-${index}.iso"
		index=$((index + 1))
		if [[ "$index" -gt 100 ]]; then
			exit_with_error "Could not find a free name under $target_dir"
		fi
	done
}

# iso-scan/filename= and findiso= break on spaces; hardlink or copy to boot-isos/ if needed.
# Prints the path GRUB should use (stdout).
ensure_no_space_path() {
	local source_iso=$1
	local mount_point=$2
	local filesystem_type=${3:-}
	local basename_iso
	local safe_basename
	local target_dir
	local target_iso
	local source_grub_path

	basename_iso=$(basename "$source_iso")
	source_grub_path=$(grub_path_on_partition "$source_iso" "$mount_point")
	if path_safe_for_grub "$source_grub_path"; then
		printf '%s' "$source_iso"
		return
	fi

	say "This ISO path has spaces or GRUB-unsafe characters. GRUB cannot use it as-is for iso-scan/filename= or findiso=."
	safe_basename=$(safe_boot_iso_basename "$basename_iso")
	target_dir="$mount_point/boot-isos"
	target_iso=$(choose_boot_iso_target "$source_iso" "$target_dir" "$safe_basename")
	if [[ "$DRY_RUN" -eq 1 ]]; then
		say "Preview target path: $target_iso"
		if [[ -e "$target_iso" ]]; then
			say "Dry-run: existing target contents were not compared; the selected name is conservative."
		fi
	else
		say "Intended path without spaces: $target_iso"
	fi
	if filesystem_allows_hardlinks "$filesystem_type"; then
		say "(Hard link on the same filesystem when possible; no extra space used.)"
	else
		say "(Hard links are not supported on ${filesystem_type:-this filesystem}; a copy will be used and needs disk space.)"
	fi

	if [[ "$DRY_RUN" -eq 1 ]]; then
		say "Dry-run: not creating that path."
		printf '%s' "$target_iso"
		return
	fi

	if [[ ! -d "$mount_point" ]]; then
		exit_with_error "Mount point does not exist: $mount_point"
	fi

	if ! ask_yes_no "Create that path now?"; then
		exit_with_error "Stopped. Move or link the ISO to a path without spaces, then run $SCRIPT_NAME again."
	fi
	if ! mkdir -p "$target_dir"; then
		exit_with_error "Could not create $target_dir (is the filesystem writable?)."
	fi
	if same_file_inode "$source_iso" "$target_iso"; then
		say "Already linked to this ISO: $target_iso"
	elif [[ -f "$target_iso" ]] && cmp -s -- "$source_iso" "$target_iso" 2>/dev/null; then
		say "Already exists with identical content: $target_iso"
	elif filesystem_allows_hardlinks "$filesystem_type" \
		&& same_filesystem_device "$source_iso" "$target_dir"; then
		# ln without -s = hard link; fails across filesystems.
		if ! ln "$source_iso" "$target_iso" 2>/dev/null; then
			say "Hard link failed; copying instead…"
			copy_iso_to_target "$source_iso" "$target_iso"
			say "Copy created."
		else
			say "Hard link created."
		fi
	else
		copy_iso_to_target "$source_iso" "$target_iso"
		say "Copy created."
	fi
	printf '%s' "$target_iso"
}

# Path of the ISO relative to the filesystem root (what GRUB sees after search).
# Example: /mnt/data/boot-isos/foo.iso → /boot-isos/foo.iso
grub_path_on_partition() {
	local absolute_iso=$1
	local mount_point=$2
	local relative

	if [[ "$mount_point" == / ]]; then
		if [[ "$absolute_iso" == / ]]; then
			exit_with_error "ISO path is the mount point itself: $absolute_iso"
		fi
		if [[ "$absolute_iso" != /* ]]; then
			exit_with_error "ISO path is not under mount point /"
		fi
	elif [[ "$absolute_iso" == "$mount_point" ]]; then
		exit_with_error "ISO path is the mount point itself: $absolute_iso"
	elif [[ "$absolute_iso" != "$mount_point"/* ]]; then
		exit_with_error "ISO path is not under mount point $mount_point"
	fi

	if [[ -e "$absolute_iso" ]]; then
		relative=$(realpath --relative-to="$mount_point" "$absolute_iso")
		printf '/%s' "$relative"
		return
	fi

	if [[ "$mount_point" == / ]]; then
		printf '%s' "$absolute_iso"
		return
	fi
	relative=${absolute_iso#"$mount_point"}
	if [[ "$relative" != /* ]]; then
		relative="/$relative"
	fi
	printf '%s' "$relative"
}

# Common insmod lines for generated menuentry blocks.
# iso9660 for typical Mint ISOs; udf when present.
grub_common_insmods() {
	local grub_fs_module=$1
	local search_module

	if ! grub_module_exists part_gpt && ! grub_module_exists part_msdos; then
		exit_with_error "Neither part_gpt.mod nor part_msdos.mod is installed."
	fi
	require_grub_module "$grub_fs_module"
	require_grub_module loopback
	search_module=$(grub_search_module)
	if ! grub_module_exists iso9660 && ! grub_module_exists udf; then
		exit_with_error "Neither iso9660.mod nor udf.mod is installed."
	fi

	if grub_module_exists part_gpt; then
		printf '%s\n' "	insmod part_gpt"
	fi
	if grub_module_exists part_msdos; then
		printf '%s\n' "	insmod part_msdos"
	fi
	printf '%s\n' "	insmod $grub_fs_module"
	printf '%s\n' "	insmod $search_module"
	printf '%s\n' "	insmod loopback"
	if grub_module_exists iso9660; then
		printf '%s\n' "	insmod iso9660"
	fi
	if grub_module_exists udf; then
		printf '%s\n' "	insmod udf"
	fi
}

# Primary entry for both flavors: ISO loopback.cfg (exports iso_path).
# Ubuntu Mint uses iso-scan/filename=${iso_path}; LMDE uses findiso=${iso_path}.
# \$isofile is escaped so bash does not expand it; GRUB expands $isofile at boot.
build_loopback_cfg_block() {
	local menu_title=$1
	local filesystem_uuid=$2
	local isofile_grub_path=$3
	local grub_fs_module=$4
	local insmod_block
	insmod_block=$(grub_common_insmods "$grub_fs_module")
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
$insmod_block
	search --no-floppy --fs-uuid --set=root $filesystem_uuid
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
	local filesystem_uuid=$2
	local isofile_grub_path=$3
	local grub_fs_module=$4
	local initrd_grub_path=$5
	local insmod_block
	insmod_block=$(grub_common_insmods "$grub_fs_module")
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
$insmod_block
	search --no-floppy --fs-uuid --set=root $filesystem_uuid
	set isofile="$isofile_grub_path"
	loopback loop \$isofile
	linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=\$isofile quiet noeject noprompt splash --
	initrd (loop)/$initrd_grub_path
}
EOF
}

# Fallback: LMDE — direct live kernel with findiso= (no ISO GRUB submenu).
build_lmde_live_fallback_block() {
	local menu_title=$1
	local filesystem_uuid=$2
	local isofile_grub_path=$3
	local grub_fs_module=$4
	local initrd_grub_path=$5
	local insmod_block
	insmod_block=$(grub_common_insmods "$grub_fs_module")
	cat <<EOF

menuentry "$menu_title" --class linuxmint {
$insmod_block
	search --no-floppy --fs-uuid --set=root $filesystem_uuid
	set isofile="$isofile_grub_path"
	loopback loop \$isofile
	linux (loop)/live/vmlinuz boot=live live-config live-media-path=/live findiso=\$isofile quiet splash --
	initrd (loop)/$initrd_grub_path
}
EOF
}

restore_custom_grub_from_backup() {
	local custom_backup=$1
	if sudo cp -a "$custom_backup" "$CUSTOM_GRUB"; then
		return 0
	fi
	say "CRITICAL: automatic restoration of $CUSTOM_GRUB failed."
	say "Restore manually from: $custom_backup"
	return 1
}

parse_args() {
	local argument
	for argument in "$@"; do
		case "$argument" in
			--dry-run)
				DRY_RUN=1
				;;
			-h|--help)
				say "Usage: $SCRIPT_NAME [--dry-run]"
				exit 0
				;;
			*)
				exit_with_error "Unknown option: $argument (try --help)"
				;;
		esac
	done
}

main() {
	parse_args "$@"

	need_cmd findmnt
	need_cmd realpath
	need_cmd find
	need_cmd awk
	need_cmd stat
	need_cmd tr
	need_cmd cmp
	need_cmd mktemp
	need_cmd mv
	need_cmd cp

	if ! findmnt --raw -n -o TARGET --target / >/dev/null 2>&1; then
		exit_with_error "This findmnt does not support usable --raw output."
	fi

	say "=== Boot Linux Mint / LMDE live ISO from GRUB (guided) ==="
	say "This adds a GRUB menu entry so you can boot a Mint or LMDE ISO file from disk."
	say "It will not repartition anything."
	say "GRUB modules are checked under this system's /boot/grub and /usr/lib/grub."
	say "Run from the installed system with /boot and those GRUB module directories available."
	if [[ "$DRY_RUN" -eq 1 ]]; then
		say "Dry-run: no system or GRUB changes; temporary verification files may be created and removed."
	fi
	blank
	if ! ask_yes_no "Continue?"; then
		say "Cancelled."
		exit 0
	fi
	blank

	local iso_absolute mount_point filesystem_type filesystem_uuid grub_fs_module
	local iso_for_grub grub_relative_path menu_title entry_block fallback_block
	local custom_backup include_fallback use_loopback_primary allow_initrd_fallback
	local iso_flavor initrd_grub_path default_menu_title fallback_label
	local layout_fields listing_file
	local proposed_custom script_check_cmd

	iso_absolute=$(prompt_for_iso_absolute_path)
	say "Using: $iso_absolute"
	blank

	verify_iso_checksum "$iso_absolute"

	# findmnt --target: mount that owns the file. --raw: unescaped TARGET.
	mount_point=$(findmnt --raw -n -o TARGET --target "$iso_absolute") || exit_with_error "Could not find mount point for that file."
	filesystem_type=$(findmnt --raw -n -o FSTYPE --target "$iso_absolute") || true
	filesystem_uuid=$(findmnt --raw -n -o UUID --target "$iso_absolute") || exit_with_error "Could not read filesystem UUID (GRUB needs this)."
	require_filesystem_uuid "$filesystem_uuid"

	say "Filesystem mount: $mount_point"
	say "Filesystem:       ${filesystem_type:-unknown}"
	say "UUID:             $filesystem_uuid"
	blank

	grub_fs_module=$(require_supported_filesystem "${filesystem_type:-}")
	require_loopback_iso_modules
	warn_if_fat32_iso_too_large "$iso_absolute" "${filesystem_type:-}"
	say "GRUB filesystem module: $grub_fs_module"
	blank

	say "Detecting ISO layout (Ubuntu-based Mint casper/ vs LMDE live/)…"
	listing_file=$(mktemp /tmp/mint-iso-listing.XXXXXX)
	register_cleanup_path "$listing_file"
	iso_archive_listing_to_file "$iso_absolute" "$listing_file"
	layout_fields=$(detect_mint_iso_layout_from_listing_file "$listing_file")
	iso_flavor=${layout_fields%% *}
	initrd_grub_path=${layout_fields#* }
	require_initrd_grub_path "$initrd_grub_path"
	if [[ "$iso_flavor" == ubuntu ]]; then
		say "Detected: Ubuntu-based Linux Mint (casper/; initrd $initrd_grub_path)."
		default_menu_title="Linux Mint Live ISO"
		fallback_label="direct casper"
	else
		say "Detected: LMDE (live/ + findiso=; initrd $initrd_grub_path)."
		default_menu_title="LMDE Live ISO"
		fallback_label="direct live"
	fi

	allow_initrd_fallback=1
	if [[ "$ISO_LISTING_TOOL" == isoinfo ]]; then
		say "Detected initrd path via isoinfo (best-effort): $initrd_grub_path"
		if ask_yes_no "Confirm this initrd path for fallback entries?" n; then
			allow_initrd_fallback=1
		else
			allow_initrd_fallback=0
			say "Fallback entries that need this initrd path will not be offered."
		fi
	fi
	blank

	use_loopback_primary=1
	if listing_file_has_loopback_cfg "$listing_file"; then
		say "Found boot/grub/loopback.cfg in the ISO (primary entry will use it)."
	else
		say "Warning: this ISO does not appear to contain boot/grub/loopback.cfg."
		if [[ "$allow_initrd_fallback" -eq 0 ]]; then
			exit_with_error "No loopback.cfg and initrd path was not confirmed; install p7zip-full (7z) or confirm the initrd path."
		fi
		if ask_yes_no "Use the direct $fallback_label entry as the primary (and only) entry?" y; then
			use_loopback_primary=0
		else
			exit_with_error "Stopped."
		fi
	fi
	blank

	iso_for_grub=$(ensure_no_space_path "$iso_absolute" "$mount_point" "$filesystem_type")
	grub_relative_path=$(grub_path_on_partition "$iso_for_grub" "$mount_point")
	if ! path_safe_for_grub "$grub_relative_path"; then
		exit_with_error "GRUB path still unsafe: $grub_relative_path"
	fi

	# GRUB menu title (Enter keeps the default).
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
	menu_title=$(sanitize_menu_title "$menu_title")
	blank

	include_fallback=0
	if [[ "$use_loopback_primary" -eq 1 ]]; then
		say "Proposed primary entry (ISO loopback.cfg):"
		say "----------------------------------------"
		entry_block=$(build_loopback_cfg_block "$menu_title" "$filesystem_uuid" "$grub_relative_path" "$grub_fs_module")
		printf '%s\n' "$entry_block" >&2
		say "----------------------------------------"
		blank
		if [[ "$allow_initrd_fallback" -eq 1 ]] \
			&& ask_yes_no "Also add a fallback '$fallback_label' entry?" n; then
			include_fallback=1
		fi
	else
		include_fallback=1
		say "Proposed primary entry ($fallback_label only):"
		say "----------------------------------------"
	fi

	if [[ "$include_fallback" -eq 1 ]]; then
		if [[ "$iso_flavor" == ubuntu ]]; then
			fallback_block=$(build_ubuntu_casper_fallback_block \
				"$menu_title ($fallback_label)" "$filesystem_uuid" "$grub_relative_path" \
				"$grub_fs_module" "$initrd_grub_path")
		else
			fallback_block=$(build_lmde_live_fallback_block \
				"$menu_title ($fallback_label)" "$filesystem_uuid" "$grub_relative_path" \
				"$grub_fs_module" "$initrd_grub_path")
		fi
		if [[ "$use_loopback_primary" -eq 0 ]]; then
			if [[ "$iso_flavor" == ubuntu ]]; then
				entry_block=$(build_ubuntu_casper_fallback_block \
					"$menu_title" "$filesystem_uuid" "$grub_relative_path" \
					"$grub_fs_module" "$initrd_grub_path")
			else
				entry_block=$(build_lmde_live_fallback_block \
					"$menu_title" "$filesystem_uuid" "$grub_relative_path" \
					"$grub_fs_module" "$initrd_grub_path")
			fi
			include_fallback=0
			printf '%s\n' "$entry_block" >&2
			say "----------------------------------------"
		else
			say "Fallback entry will be added too."
		fi
		blank
	fi

	if [[ "$DRY_RUN" -eq 1 ]]; then
		say "Dry-run complete: no system or GRUB changes. Proposed blocks above."
		exit 0
	fi

	need_cmd update-grub
	need_cmd sudo

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

	say "Refreshing sudo credentials…"
	sudo -v

	custom_backup="${BACKUP_DIR}/40_custom.bak.${BACKUP_SUFFIX}"
	sudo mkdir -p "$BACKUP_DIR"
	sudo cp -a "$CUSTOM_GRUB" "$custom_backup"
	say "Backup: $custom_backup"

	if command -v grub-script-check >/dev/null 2>&1; then
		script_check_cmd=grub-script-check
	elif command -v grub2-script-check >/dev/null 2>&1; then
		script_check_cmd=grub2-script-check
	else
		script_check_cmd=
	fi
	if [[ -n "$script_check_cmd" ]]; then
		proposed_custom=$(mktemp /tmp/mint-iso-grub-combined.XXXXXX)
		register_cleanup_path "$proposed_custom"
		# Mint/Ubuntu 40_custom: shell wrapper, then GRUB text after line 2.
		if head -n 2 "$CUSTOM_GRUB" | grep -qF 'exec tail -n +3'; then
			{
				tail -n +3 "$CUSTOM_GRUB"
				printf '%s\n' "$entry_block"
				if [[ "$include_fallback" -eq 1 ]]; then
					printf '%s\n' "$fallback_block"
				fi
			} >"$proposed_custom"
			if ! "$script_check_cmd" "$proposed_custom"; then
				exit_with_error "$script_check_cmd rejected the combined 40_custom GRUB content (existing + proposed)."
			fi
		else
			say "Warning: $CUSTOM_GRUB does not use the standard two-line 40_custom wrapper."
			say "Skipping validation of existing custom content; validating only the new entries."
			{
				printf '%s\n' "$entry_block"
				if [[ "$include_fallback" -eq 1 ]]; then
					printf '%s\n' "$fallback_block"
				fi
			} >"$proposed_custom"
			if ! "$script_check_cmd" "$proposed_custom"; then
				exit_with_error "$script_check_cmd rejected the proposed menuentry block(s)."
			fi
		fi
	fi

	# Append only; keeps any other custom entries already in 40_custom.
	if ! {
		printf '%s\n' "$entry_block"
		if [[ "$include_fallback" -eq 1 ]]; then
			printf '%s\n' "$fallback_block"
		fi
	} | sudo tee -a "$CUSTOM_GRUB" >/dev/null; then
		say "Appending to $CUSTOM_GRUB failed; restoring the backup."
		restore_custom_grub_from_backup "$custom_backup" || true
		exit_with_error "Could not append to $CUSTOM_GRUB; backup is $custom_backup"
	fi

	say "Running update-grub…"
	if ! sudo update-grub; then
		say "update-grub failed; restoring the previous 40_custom."
		restore_custom_grub_from_backup "$custom_backup" || true
		exit_with_error "update-grub failed; backup is $custom_backup"
	fi
	blank
	say "Done."
	say "1. Reboot."
	say "2. At the GRUB menu, choose: $menu_title"
	say "   (If the menu is hidden, hold Shift or press Esc during boot.)"
	say "3. If boot fails, check filesystem modules, ISO path/layout, and Secure Boot settings."
	say "To undo: restore $custom_backup over $CUSTOM_GRUB, then sudo update-grub"
}

main "$@"
