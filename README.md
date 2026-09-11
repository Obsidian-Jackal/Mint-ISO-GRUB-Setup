# Mint ISO GRUB Setup

Adds a GRUB menu entry to boot a Linux Mint or LMDE live ISO from a file on disk. Does not repartition disks.

| Flavor | Primary boot | Optional fallback |
|--------|--------------|-------------------|
| Ubuntu-based Mint (`casper/`) | ISO `loopback.cfg` + `iso_path` | direct casper + `iso-scan/filename=` |
| LMDE (`live/`) | ISO `loopback.cfg` + `iso_path` | direct live + `findiso=` |

## Requirements

- Run from the **installed system** with `/boot` and GRUB module dirs available (`/boot/grub`, `/usr/lib/grub`)
- Installed GRUB with `update-grub` and `/etc/grub.d/40_custom`
- ISO on a filesystem GRUB can read: **ext2/3/4**, **XFS**, **FAT32** (`vfat`), **exFAT**, or **Btrfs** (the matching GRUB module must exist on this host)
- Path that is safe for GRUB (no spaces / special characters; script can hardlink or copy to `/boot-isos/` when needed)
- `sha256sum`; `curl` or `wget` if checksums must be downloaded; `gpg` when verifying signatures
- `7z` (preferred) or `isoinfo` (best-effort) to detect casper vs live without mounting

FAT32 cannot store ISOs larger than 4 GiB − 1. On Btrfs, the ISO must be on the subvolume GRUB mounts for that UUID.

## Run

```bash
bash setup-mint-iso-grub.sh
bash setup-mint-iso-grub.sh --dry-run   # no system/GRUB changes; may use temp verification files
```

## One-liner

Do not pipe into bash. The script is interactive and needs a real TTY:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Obsidian-Jackal/Mint-ISO-GRUB-Setup/main/setup-mint-iso-grub.sh)
```

## What it does

1. Locate the ISO (search home, search Downloads, or enter a path)
2. Optional SHA-256 check (`sha256sum.txt` + `.gpg`, local or downloaded; GPG uses a temporary keyring)
3. Detect Ubuntu-based Mint vs LMDE and the real `initrd*` name
4. Hardlink or copy if the path has spaces / unsafe characters
5. Append `/etc/grub.d/40_custom` and run `update-grub` (backup under `/var/backups/grub.d/`; restores the backup if `update-grub` fails)

## License

BSD 3-Clause. See [LICENSE](LICENSE).
