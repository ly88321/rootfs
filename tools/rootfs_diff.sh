#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$REPO_DIR/tools"

. "$TOOLS_DIR/utils.sh"
. "$TOOLS_DIR/build_tools.sh"

TEMP_DIRS=()
MOUNT_POINTS=()
LAST_DETECTED_FORMAT=""
LAST_INITRD_LENGTH=""
LAST_CREATED_TEMP_DIR=""

usage() {
    cat <<'EOF'
Usage:
  tools/rootfs_diff.sh [-o OUTPUT_DIR] [-v1|-v2|-v3] [--a-v1|--a-v2|--a-v3] [--b-v1|--b-v2|--b-v3] [-u PUBLIC_KEY] <firmware_a.bin|iso> <firmware_b.bin|iso>

Options:
  -o OUTPUT_DIR   Output directory. Default: ./rootfs-diff-YYYYmmddHHMMSS
  -v1|-v2|-v3    Force both firmware to use one rootfs format
  --a-v1|--a-v2|--a-v3
                  Force firmware A to use one rootfs format
  --b-v1|--b-v2|--b-v3
                  Force firmware B to use one rootfs format
  -u PUBLIC_KEY   Override v3 RSA public key for verification
  -h, --help      Show this help

Output:
  OUTPUT_DIR/
    a/                      changed files from firmware A
    b/                      changed files from firmware B
    report.md               summary report
    text-diff-report.patch  unified diff for readable text files
EOF
}

cleanup() {
    local idx mount_point temp_dir

    for ((idx=${#MOUNT_POINTS[@]} - 1; idx>=0; idx--)); do
        mount_point="${MOUNT_POINTS[$idx]}"
        if [ -d "$mount_point" ] && mountpoint -q "$mount_point"; then
            umount_retry "$mount_point" >/dev/null 2>&1 || true
        fi
    done

    for temp_dir in "${TEMP_DIRS[@]}"; do
        if [ -d "$temp_dir" ]; then
            rm -rf "$temp_dir"
        fi
    done
}

trap cleanup EXIT

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "please run as root" >&2
        exit 1
    fi
}

require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log ERROR "File not found: $path"
        exit 1
    fi
}

create_temp_dir() {
    local prefix="$1"
    LAST_CREATED_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rootfs-diff.${prefix}.XXXXXX")"
    TEMP_DIRS+=("$LAST_CREATED_TEMP_DIR")
}

safe_mount() {
    local source_path="$1"
    local mount_point="$2"

    mkdir -p "$mount_point"
    mount "$source_path" "$mount_point"
    MOUNT_POINTS+=("$mount_point")
}

safe_umount() {
    local mount_point="$1"
    umount_retry "$mount_point"
}

extract_rootfs_from_iso() {
    local firmware="$1"
    local workspace="$2"
    local iso_mount="$workspace/iso-mount"
    local grub_cfg
    local initrd_length

    log INFO "Mount iso: $firmware"
    safe_mount "$firmware" "$iso_mount"

    grub_cfg="$iso_mount/boot/grub/grub.cfg"
    initrd_length="$(grep -E "^set initrd_length=" "$grub_cfg" | head -n1 | sed 's/set initrd_length=//')"
    if [ -z "$initrd_length" ]; then
        log ERROR "Get initrd_length from grub.cfg fail: $firmware"
        exit 1
    fi

    cp "$iso_mount/boot/rootfs" "$workspace/rootfs"
    safe_umount "$iso_mount"

    LAST_INITRD_LENGTH="$initrd_length"
}

extract_rootfs_from_bin() {
    local firmware="$1"
    local workspace="$2"
    local iso_mount="$workspace/iso-mount"
    local header_len

    header_len="$(printf "%u" "0x$(hexdump -v -n 4 "$firmware" -e '4/1 "%02x"')")"

    printf '\x1f\x8b\x08\x00\x6f\x9b\x4b\x59\x02\x03' > "$workspace/header.bin"
    dd if="$firmware" bs=1 skip=4 count="$header_len" >> "$workspace/header.bin" 2>/dev/null
    gunzip < "$workspace/header.bin" > "$workspace/header_info.json"

    dd if="$firmware" bs="$((header_len + 4))" skip=1 > "$workspace/firmware.iso.gz" 2>/dev/null
    gzip -d < "$workspace/firmware.iso.gz" > "$workspace/firmware.iso"

    log INFO "Mount inner iso: $firmware"
    safe_mount "$workspace/firmware.iso" "$iso_mount"
    cp "$iso_mount/boot/rootfs" "$workspace/rootfs"
    safe_umount "$iso_mount"
}

is_valid_decrypted_rootfs() {
    local decrypted_dir="$1"
    [ -f "$decrypted_dir/rootfs.ext2" ] || return 1
    xz -t "$decrypted_dir/rootfs.ext2" >/dev/null 2>&1
}

unpack_rootfs_image() {
    local encrypted_rootfs="$1"
    local initrd_length="$2"
    local output_root="$3"
    local forced_format="$4"
    local public_key_file="$5"
    local workspace="$6"
    local decrypt_dir
    local mount_dir="$workspace/rootfs-mount"
    local attempt_log
    local fmt
    local -a formats
    local -a cmd

    if [ -n "$forced_format" ]; then
        formats=("$forced_format")
    else
        formats=("-v1" "-v2" "-v3")
    fi

    for fmt in "${formats[@]}"; do
        decrypt_dir="$workspace/decrypt.${fmt#-}"
        attempt_log="$workspace/decrypt.${fmt#-}.log"

        rm -rf "$decrypt_dir" "$mount_dir"
        mkdir -p "$decrypt_dir"

        cmd=("$TOOLS_DIR/rootfs" decrypt "$encrypted_rootfs" "$decrypt_dir" "$fmt")
        if [ -n "$initrd_length" ]; then
            cmd+=("-l" "$initrd_length")
        fi
        if [ "$fmt" = "-v3" ] && [ -n "$public_key_file" ]; then
            cmd+=("-u" "$public_key_file")
        fi

        if ! "${cmd[@]}" >"$attempt_log" 2>&1; then
            continue
        fi

        if ! is_valid_decrypted_rootfs "$decrypt_dir"; then
            continue
        fi

        xz -dkc "$decrypt_dir/rootfs.ext2" > "$workspace/rootfs.ext2"
        mkdir -p "$mount_dir"

        if ! mount "$workspace/rootfs.ext2" "$mount_dir" >/dev/null 2>&1; then
            continue
        fi
        MOUNT_POINTS+=("$mount_dir")

        mkdir -p "$output_root"
        cp -a "$mount_dir/." "$output_root/"
        safe_umount "$mount_dir"

        LAST_DETECTED_FORMAT="$fmt"
        log INFO "Use rootfs format: $fmt"
        return 0
    done

    log ERROR "Decrypt rootfs fail: $encrypted_rootfs"
    return 1
}

unpack_firmware() {
    local firmware="$1"
    local output_root="$2"
    local forced_format="$3"
    local public_key_file="$4"
    local workspace
    local ext
    create_temp_dir "unpack"
    workspace="$LAST_CREATED_TEMP_DIR"
    ext="${firmware##*.}"
    ext="${ext,,}"

    case "$ext" in
        iso)
            LAST_INITRD_LENGTH=""
            extract_rootfs_from_iso "$firmware" "$workspace"
            ;;
        bin)
            LAST_INITRD_LENGTH=""
            extract_rootfs_from_bin "$firmware" "$workspace"
            ;;
        *)
            log ERROR "Unsupported firmware file: $firmware"
            exit 1
            ;;
    esac

    unpack_rootfs_image "$workspace/rootfs" "$LAST_INITRD_LENGTH" "$output_root" "$forced_format" "$public_key_file" "$workspace"
}

build_file_list() {
    local root="$1"
    local output_file="$2"
    (
        cd "$root"
        find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort
    ) > "$output_file"
}

copy_entry() {
    local src_root="$1"
    local rel_path="$2"
    local dst_root="$3"
    local parent_dir

    parent_dir="$(dirname "$rel_path")"
    mkdir -p "$dst_root/$parent_dir"
    cp -a "$src_root/$rel_path" "$dst_root/$rel_path"
}

file_mode() {
    stat -c '%a' -- "$1"
}

file_owner() {
    stat -c '%u:%g' -- "$1"
}

file_type() {
    if [ -L "$1" ]; then
        printf 'symlink\n'
    elif [ -f "$1" ]; then
        printf 'file\n'
    else
        stat -c '%F' -- "$1"
    fi
}

entry_signature() {
    local path="$1"

    if [ -L "$path" ]; then
        printf 'symlink|%s|%s|%s\n' "$(file_mode "$path")" "$(file_owner "$path")" "$(readlink -- "$path")"
    elif [ -f "$path" ]; then
        printf 'file|%s|%s|%s\n' "$(file_mode "$path")" "$(file_owner "$path")" "$(stat -c '%s' -- "$path")"
    else
        printf '%s|%s|%s|%s|%s\n' "$(file_type "$path")" "$(file_mode "$path")" "$(file_owner "$path")" "$(stat -c '%t' -- "$path")" "$(stat -c '%T' -- "$path")"
    fi
}

entries_differ() {
    local left="$1"
    local right="$2"

    if [ "$(entry_signature "$left")" != "$(entry_signature "$right")" ]; then
        return 0
    fi

    if [ -f "$left" ] && [ -f "$right" ] && ! cmp -s -- "$left" "$right"; then
        return 0
    fi

    return 1
}

change_reason() {
    local left="$1"
    local right="$2"
    local reasons=()
    local left_type right_type

    left_type="$(file_type "$left")"
    right_type="$(file_type "$right")"

    if [ "$left_type" != "$right_type" ]; then
        reasons+=("type")
    fi

    if [ -f "$left" ] && [ -f "$right" ] && ! cmp -s -- "$left" "$right"; then
        reasons+=("content")
    fi

    if [ -L "$left" ] && [ -L "$right" ] && [ "$(readlink -- "$left")" != "$(readlink -- "$right")" ]; then
        reasons+=("link")
    fi

    if [ "$(file_mode "$left")" != "$(file_mode "$right")" ]; then
        reasons+=("mode")
    fi

    if [ "$(file_owner "$left")" != "$(file_owner "$right")" ]; then
        reasons+=("owner")
    fi

    if [ ${#reasons[@]} -eq 0 ]; then
        reasons+=("metadata")
    fi

    local joined=""
    local reason
    for reason in "${reasons[@]}"; do
        if [ -n "$joined" ]; then
            joined="$joined,$reason"
        else
            joined="$reason"
        fi
    done

    printf '%s\n' "$joined"
}

is_text_file() {
    local file="$1"

    [ -f "$file" ] || return 1
    [ ! -s "$file" ] && return 0
    LC_ALL=C grep -Iq . "$file"
}

append_text_diff_for_modified() {
    local rel_path="$1"
    local left_file="$2"
    local right_file="$3"
    local report_file="$4"
    local count_file="$5"

    if is_text_file "$left_file" && is_text_file "$right_file" && ! cmp -s -- "$left_file" "$right_file"; then
        diff -u --label "a/$rel_path" "$left_file" --label "b/$rel_path" "$right_file" >> "$report_file" || true
        printf '%s\n' "$rel_path" >> "$count_file"
    fi
}

append_text_diff_for_added() {
    local rel_path="$1"
    local file="$2"
    local report_file="$3"
    local count_file="$4"

    if is_text_file "$file"; then
        diff -u --label "/dev/null" /dev/null --label "b/$rel_path" "$file" >> "$report_file" || true
        printf '%s\n' "$rel_path" >> "$count_file"
    fi
}

append_text_diff_for_deleted() {
    local rel_path="$1"
    local file="$2"
    local report_file="$3"
    local count_file="$4"

    if is_text_file "$file"; then
        diff -u --label "a/$rel_path" "$file" --label "/dev/null" /dev/null >> "$report_file" || true
        printf '%s\n' "$rel_path" >> "$count_file"
    fi
}

count_lines() {
    local file="$1"
    if [ -s "$file" ]; then
        wc -l < "$file" | tr -d '[:space:]'
    else
        printf '0\n'
    fi
}

write_report_section() {
    local title="$1"
    local list_file="$2"
    local report_file="$3"

    printf '## %s\n\n' "$title" >> "$report_file"
    if [ -s "$list_file" ]; then
        while IFS= read -r line; do
            printf -- '- `%s`\n' "$line" >> "$report_file"
        done < "$list_file"
    else
        printf -- '- none\n' >> "$report_file"
    fi
    printf '\n' >> "$report_file"
}

main() {
    local forced_format=""
    local forced_format_a=""
    local forced_format_b=""
    local public_key_file=""
    local output_dir=""
    local firmware_a
    local firmware_b
    local a_root
    local b_root
    local compare_workspace
    local list_a
    local list_b
    local added_list
    local deleted_list
    local common_list
    local modified_list
    local modified_report_list
    local text_diff_paths
    local report_file
    local text_diff_report
    local rel_path
    local left_path
    local right_path
    local format_a
    local format_b
    local modified_count
    local added_count
    local deleted_count
    local text_diff_count

    while [ $# -gt 0 ]; do
        case "$1" in
            -o)
                output_dir="$2"
                shift 2
                ;;
            -u)
                public_key_file="$2"
                shift 2
                ;;
            -v1|-v2|-v3)
                forced_format="$1"
                shift
                ;;
            --a-v1|--a-v2|--a-v3)
                forced_format_a="-${1#--a-}"
                shift
                ;;
            --b-v1|--b-v2|--b-v3)
                forced_format_b="-${1#--b-}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                log ERROR "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# -ne 2 ]; then
        usage
        exit 1
    fi

    firmware_a="$1"
    firmware_b="$2"

    require_root

    require_file "$firmware_a"
    require_file "$firmware_b"
    if [ -n "$public_key_file" ]; then
        require_file "$public_key_file"
    fi

    if [ -z "$output_dir" ]; then
        output_dir="$REPO_DIR/rootfs-diff-$(date +%Y%m%d%H%M%S)"
    fi

    if [ -n "$forced_format" ]; then
        [ -n "$forced_format_a" ] || forced_format_a="$forced_format"
        [ -n "$forced_format_b" ] || forced_format_b="$forced_format"
    fi

    if [ -e "$output_dir" ]; then
        log ERROR "Output path already exists: $output_dir"
        exit 1
    fi

    mkdir -p "$output_dir"
    a_root="$output_dir/a"
    b_root="$output_dir/b"
    mkdir -p "$a_root" "$b_root"

    report_file="$output_dir/report.md"
    text_diff_report="$output_dir/text-diff-report.patch"
    : > "$text_diff_report"

    ensure_rootfs_tool

    log INFO "Unpack firmware A: $firmware_a"
    unpack_firmware "$firmware_a" "$a_root.full" "$forced_format_a" "$public_key_file"
    format_a="$LAST_DETECTED_FORMAT"

    log INFO "Unpack firmware B: $firmware_b"
    unpack_firmware "$firmware_b" "$b_root.full" "$forced_format_b" "$public_key_file"
    format_b="$LAST_DETECTED_FORMAT"

    create_temp_dir "compare"
    compare_workspace="$LAST_CREATED_TEMP_DIR"
    list_a="$compare_workspace/list_a.txt"
    list_b="$compare_workspace/list_b.txt"
    added_list="$compare_workspace/added.txt"
    deleted_list="$compare_workspace/deleted.txt"
    common_list="$compare_workspace/common.txt"
    modified_list="$compare_workspace/modified.txt"
    modified_report_list="$compare_workspace/modified_report.txt"
    text_diff_paths="$compare_workspace/text_diff_paths.txt"

    build_file_list "$a_root.full" "$list_a"
    build_file_list "$b_root.full" "$list_b"

    comm -23 "$list_a" "$list_b" > "$deleted_list"
    comm -13 "$list_a" "$list_b" > "$added_list"
    comm -12 "$list_a" "$list_b" > "$common_list"
    : > "$modified_list"
    : > "$modified_report_list"
    : > "$text_diff_paths"

    while IFS= read -r rel_path; do
        left_path="$a_root.full/$rel_path"
        right_path="$b_root.full/$rel_path"

        if entries_differ "$left_path" "$right_path"; then
            printf '%s\n' "$rel_path" >> "$modified_list"
            printf '%s | %s\n' "$rel_path" "$(change_reason "$left_path" "$right_path")" >> "$modified_report_list"
            copy_entry "$a_root.full" "$rel_path" "$a_root"
            copy_entry "$b_root.full" "$rel_path" "$b_root"
            append_text_diff_for_modified "$rel_path" "$left_path" "$right_path" "$text_diff_report" "$text_diff_paths"
        fi
    done < "$common_list"

    while IFS= read -r rel_path; do
        [ -n "$rel_path" ] || continue
        copy_entry "$a_root.full" "$rel_path" "$a_root"
        append_text_diff_for_deleted "$rel_path" "$a_root.full/$rel_path" "$text_diff_report" "$text_diff_paths"
    done < "$deleted_list"

    while IFS= read -r rel_path; do
        [ -n "$rel_path" ] || continue
        copy_entry "$b_root.full" "$rel_path" "$b_root"
        append_text_diff_for_added "$rel_path" "$b_root.full/$rel_path" "$text_diff_report" "$text_diff_paths"
    done < "$added_list"

    modified_count="$(count_lines "$modified_list")"
    added_count="$(count_lines "$added_list")"
    deleted_count="$(count_lines "$deleted_list")"
    text_diff_count="$(count_lines "$text_diff_paths")"

    cat > "$report_file" <<EOF
# Rootfs diff report

- firmware_a: \`$firmware_a\`
- firmware_b: \`$firmware_b\`
- output_dir: \`$output_dir\`
- forced_format_a: \`${forced_format_a:-auto}\`
- forced_format_b: \`${forced_format_b:-auto}\`
- format_a: \`$format_a\`
- format_b: \`$format_b\`

## Summary

- modified: $modified_count
- added: $added_count
- deleted: $deleted_count
- text_diff_entries: $text_diff_count

EOF

    write_report_section "Modified" "$modified_report_list" "$report_file"
    write_report_section "Added" "$added_list" "$report_file"
    write_report_section "Deleted" "$deleted_list" "$report_file"

    rm -rf "$a_root.full" "$b_root.full"

    log INFO "Done"
    log INFO "Report: $report_file"
    log INFO "Text diff: $text_diff_report"
}

main "$@"
