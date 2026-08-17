#!/usr/bin/env bash
#
# ffile - forensic file analysis. Pulls every available piece of metadata
# and content hinting from a file to help identify what it is, who/what
# made it, and when: stat, checksums, attributes, ACLs, hex header/tail,
# strings, exiftool metadata, binwalk signatures, and entropy.
#
# Setup:
# create file at /usr/local/bin/ffile.sh (or ~/.local/bin/ffile.sh for a
# single user)
# chmod +x /usr/local/bin/ffile.sh
#
# Add:
# source /usr/local/bin/ffile.sh
# to your bashrc or zshrc
#
# Usage: ffile <filepath>
#
# Optional but recommended tools for full output: exiftool, binwalk, xxd or
# hexdump, strings, getfattr, getfacl, lsof, ent (or python3 as a fallback
# for the entropy estimate).

ffile() {
    if [ -z "$1" ]; then
        echo "Usage: ffile <filepath>"
        return 1
    fi

    local target="$1"
    local sep="================================================================================"

    if [ ! -e "$target" ]; then
        echo "Error: '$target' does not exist."
        return 1
    fi

    # Helper: print a section header
    _ff_header() { echo; echo "$sep"; echo "  $1"; echo "$sep"; }

    # Resolve symlinks and get the real path
    local realpath_val
    realpath_val=$(realpath "$target" 2>/dev/null || readlink -f "$target" 2>/dev/null || echo "$target")

    _ff_header "IDENTITY"
    echo "  Provided path : $target"
    echo "  Resolved path : $realpath_val"
    if [ -L "$target" ]; then
        echo "  Symlink target: $(readlink "$target")"
    fi

    # --- stat: all timestamps, permissions, inode, device ---
    _ff_header "STAT (timestamps, permissions, inode)"
    stat "$target"

    # --- file type detection ---
    _ff_header "FILE TYPE DETECTION"
    echo "[file command]"
    file "$target"
    echo
    echo "[file --mime]"
    file --mime "$target"

    # --- checksums ---
    _ff_header "CHECKSUMS"
    md5sum    "$target" 2>/dev/null
    sha1sum   "$target" 2>/dev/null
    sha256sum "$target" 2>/dev/null
    sha512sum "$target" 2>/dev/null
    if command -v b2sum &>/dev/null; then
        b2sum "$target" 2>/dev/null
    fi

    # --- size / line / word counts ---
    _ff_header "SIZE / COUNTS"
    wc "$target" 2>/dev/null
    du -sh "$target" 2>/dev/null

    # --- file system attributes ---
    _ff_header "FILESYSTEM ATTRIBUTES (lsattr)"
    lsattr "$target" 2>/dev/null || echo "  lsattr unavailable or not applicable."

    # --- extended attributes ---
    _ff_header "EXTENDED ATTRIBUTES (getfattr)"
    if command -v getfattr &>/dev/null; then
        getfattr -d "$target" 2>/dev/null || echo "  No extended attributes found."
    else
        echo "  getfattr not installed."
    fi

    # --- ACLs ---
    _ff_header "ACCESS CONTROL LIST (getfacl)"
    if command -v getfacl &>/dev/null; then
        getfacl "$target" 2>/dev/null
    else
        echo "  getfacl not installed."
    fi

    # --- open file handles ---
    _ff_header "OPEN FILE HANDLES (lsof)"
    if command -v lsof &>/dev/null; then
        lsof "$realpath_val" 2>/dev/null || echo "  File is not currently open by any process."
    else
        echo "  lsof not installed."
    fi

    # --- package ownership ---
    _ff_header "PACKAGE OWNERSHIP"
    if command -v rpm &>/dev/null; then
        rpm -qf "$realpath_val" 2>/dev/null || echo "  Not owned by any RPM package."
    fi
    if command -v dpkg &>/dev/null; then
        dpkg -S "$realpath_val" 2>/dev/null || echo "  Not owned by any dpkg package."
    fi
    if command -v pacman &>/dev/null; then
        pacman -Qo "$realpath_val" 2>/dev/null || echo "  Not owned by any pacman package."
    fi

    # --- hex header (first 256 bytes) ---
    _ff_header "HEX HEADER (first 256 bytes)"
    if command -v xxd &>/dev/null; then
        xxd "$target" 2>/dev/null | head -n 16
    elif command -v hexdump &>/dev/null; then
        hexdump -C "$target" 2>/dev/null | head -n 16
    else
        od -A x -t x1z "$target" 2>/dev/null | head -n 16
    fi

    # --- hex tail (last 256 bytes) ---
    # Seeks directly to near EOF instead of hex-dumping the whole file and
    # piping to tail - on a multi-GB file the naive version can take minutes.
    _ff_header "HEX TAIL (last 256 bytes)"
    if command -v xxd &>/dev/null; then
        xxd -s -256 "$target" 2>/dev/null
    elif command -v hexdump &>/dev/null; then
        tail -c 256 "$target" 2>/dev/null | hexdump -C 2>/dev/null
    else
        tail -c 256 "$target" 2>/dev/null | od -A x -t x1z 2>/dev/null
    fi

    # --- printable strings ---
    _ff_header "PRINTABLE STRINGS (min length 6, first 80 results)"
    if command -v strings &>/dev/null; then
        strings -n 6 "$target" 2>/dev/null | head -n 80
    else
        echo "  strings not installed."
    fi

    # --- head / tail of raw text ---
    _ff_header "HEAD (first 20 lines of raw content)"
    head -n 20 "$target" 2>/dev/null || echo "  Could not read as text."

    _ff_header "TAIL (last 20 lines of raw content)"
    tail -n 20 "$target" 2>/dev/null || echo "  Could not read as text."

    # --- exiftool metadata (gold for images, PDFs, office docs) ---
    _ff_header "EXIFTOOL METADATA"
    if command -v exiftool &>/dev/null; then
        exiftool "$target" 2>/dev/null
    else
        echo "  exiftool not installed. Install it for deep metadata on images, PDFs, etc."
        echo "  (sudo zypper install perl-Image-ExifTool  OR  sudo apt install libimage-exiftool-perl)"
    fi

    # --- binwalk: embedded files / firmware signatures ---
    _ff_header "BINWALK (embedded file signatures)"
    if command -v binwalk &>/dev/null; then
        binwalk "$target" 2>/dev/null
    else
        echo "  binwalk not installed."
    fi

    # --- entropy hint via ent or python fallback ---
    _ff_header "ENTROPY ESTIMATE"
    if command -v ent &>/dev/null; then
        ent "$target" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 - "$target" << 'PYEOF'
import sys, math, collections
try:
    data = open(sys.argv[1], 'rb').read()
    if not data:
        print("  File is empty.")
        sys.exit(0)
    counts = collections.Counter(data)
    total  = len(data)
    entropy = -sum((c/total) * math.log2(c/total) for c in counts.values())
    print(f"  Byte entropy : {entropy:.4f} bits/byte  (max 8.0)")
    print(f"  Total bytes  : {total}")
    print(f"  Unique bytes : {len(counts)}")
    if entropy > 7.5:
        print("  Interpretation: very high entropy -- likely compressed, encrypted, or packed.")
    elif entropy > 6.0:
        print("  Interpretation: moderate-high entropy -- possibly compressed or binary data.")
    elif entropy < 1.0:
        print("  Interpretation: very low entropy -- highly repetitive or near-empty file.")
    else:
        print("  Interpretation: entropy consistent with normal text or structured binary.")
except Exception as e:
    print(f"  Entropy calculation failed: {e}")
PYEOF
    else
        echo "  Neither 'ent' nor python3 available for entropy calculation."
    fi

    _ff_header "DONE"
    echo "  Target: $target"
    echo

    unset -f _ff_header
}

_ffile_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _ffile_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _ffile_sourced=1
    fi
fi

if [ "$_ffile_sourced" -eq 0 ]; then
    ffile "$@"
fi
unset _ffile_sourced
