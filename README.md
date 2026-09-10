# Mint ISO GRUB Setup

Adds a GRUB menu entry to boot a Linux Mint or LMDE live ISO from a file on disk. Does not repartition disks.

| Flavor | Primary boot | Optional fallback |
|--------|--------------|-------------------|
| Ubuntu-based Mint (`casper/`) | ISO `loopback.cfg` + `iso_path` | direct casper + `iso-scan/filename=` |
| LMDE (`live/`) | ISO `loopback.cfg` + `iso_path` | direct live + `findiso=` |

## Requirements

- Installed system with GRUB (`update-grub`, `/etc/grub.d/40_custom`)
- ISO on a filesystem GRUB can read (typically **ext4**)
- Path without spaces (script can hardlink to `/boot-isos/` on the same filesystem)
- `sha256sum`; `curl` or `wget` if checksums must be downloaded; `gpg` if you verify signatures
- `7z` or `isoinfo` to detect casper vs live without mounting

## Run

```bash
bash setup-mint-iso-grub.sh
```

## One-liner

Do not pipe into bash. The script is interactive and needs a real TTY:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Obsidian-Jackal/Mint-ISO-GRUB-Setup/main/setup-mint-iso-grub.sh)
```

## What it does

1. Locate the ISO (search home, search Downloads, or enter a path)
2. Optional SHA-256 check (`sha256sum.txt` + `.gpg`, local or downloaded)
3. Detect Ubuntu-based Mint vs LMDE
4. Hardlink if the path has spaces
5. Append `/etc/grub.d/40_custom` and run `update-grub` (backup under `/var/backups/grub.d/`)

## License

BSD 3-Clause. See [LICENSE](LICENSE).
