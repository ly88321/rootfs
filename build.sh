#!/bin/bash

if [ "$(whoami)" != 'root' ]; then
    echo 'please run as root'
    exit 1
fi

work_dir="$(pwd)/work"
unpack_dir="$(pwd)/rootfs-unpack"

bin_files="$(pwd)/bin-boot-files"
iso_files="$(pwd)/iso-boot-files"

. tools/utils.sh

cd tools
. build_tools.sh
cd ..

function unpack_iso () {
    local file=$1

    log INFO "Mount iso ..."
    mkdir $work_dir/iso
    mount $file $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Mount iso fail!"
        exit 1
    fi

    local GRUB_CFG="$work_dir/iso/boot/grub/grub.cfg"

    local ikversion=$(grep -E "^set ikversion=" "$GRUB_CFG" | head -n1 | sed 's/set ikversion=//')
    local initrd_length=$(grep -E "^set initrd_length=" "$GRUB_CFG" | head -n1 | sed 's/set initrd_length=//')

    if [[ $ikversion = "" || $initrd_length = "" ]]; then
        log ERROR "Get iKuai version and initrd lenght fail!"
        exit 1
    fi

    log INFO "iKuai version: $ikversion"
    log INFO "iKuai initrf lenght: $initrd_length"

    log INFO "Copy rootfs and vmlinuz ..."
    cp $work_dir/iso/boot/rootfs $work_dir/rootfs
    cp $work_dir/iso/boot/vmlinuz $unpack_dir/vmlinuz

    if [ ! -f "$work_dir/rootfs" ]; then
        log ERROR "Copy rootfs fail!"
        exit 1
    fi
    if [ ! -f "$unpack_dir/vmlinuz" ]; then
        log ERROR "Copy vmlinuz fail!"
        exit 1
    fi

    log INFO "Umount iso ..."
    umount_retry $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Umount iso fail!"
        exit 1
    fi

    unpack_rootfs "$work_dir/rootfs" "$initrd_length"
}

function unpack_bin () {
    # ┌─────────────────┬──────────────────────┬─────────────────────┐
    # │  Header Length  │    Header Data       │   Compressed Data   │
    # │    (4 bytes)    │   (headlen bytes)    │   (remaining data)  │
    # │   Big Endian    │                      │                     │
    # └─────────────────┴──────────────────────┴─────────────────────┘
    #      0-3 bytes        4 to (4+headlen)      (4+headlen) to EOF

    local file="$1"

    log INFO "Export bin header ..."
    headlen=$(printf "%u" 0x$(hexdump -v -n 4 $file -e '4/1 "%02x"'))
    printf "\x1f\x8b\x08\x00\x6f\x9b\x4b\x59\x02\x03" > $work_dir/header.bin
    dd if=$file bs=1 skip=4 count=$headlen >> $work_dir/header.bin
    gunzip < $work_dir/header.bin > $unpack_dir/header_info.json

    log INFO "Export firmware iso ..."
    dd if=$file bs=$((headlen+4)) skip=1 >> $work_dir/firmware.iso.gz
    gzip -d < $work_dir/firmware.iso.gz > $work_dir/firmware.iso
    if [ $? -ne 0 ]; then
        log Error "Decompress firmware iso fail!"
        exit 1
    fi

    log INFO "Mount iso ..."
    mkdir $work_dir/iso
    mount $work_dir/firmware.iso $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Mount iso fail!"
        exit 1
    fi

    log INFO "Copy rootfs and vmlinuz ..."
    cp $work_dir/iso/boot/rootfs $work_dir/rootfs
    cp $work_dir/iso/boot/vmlinuz $unpack_dir/vmlinuz

    if [ ! -f "$work_dir/rootfs" ]; then
        log ERROR "Copy rootfs fail!"
        exit 1
    fi
    if [ ! -f "$unpack_dir/vmlinuz" ]; then
        log ERROR "Copy vmlinuz fail!"
        exit 1
    fi

    log INFO "Umount iso ..."
    umount_retry $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Umount iso fail!"
        exit 1
    fi

    unpack_rootfs "$work_dir/rootfs"
}

function unpack_rootfs () {
    local file="$1"
    local initrd_length="$2"

    if [ "$initrd_length" != "" ]; then
        initrd_length="-l $initrd_length"
    fi

    mkdir $work_dir/rootfs_decrypt

    log INFO "Decrypt rootfs ..."
    tools/rootfs-utils decode $file $work_dir/rootfs_decrypt -v2 $initrd_length
    if [ $? -ne 0 ]; then
        log Error "Decrypt rootfs fail!"
        exit 1
    fi

    if [ -f "$work_dir/rootfs_decrypt/end.gz" ]; then
        log INFO "Copy grub.gz ..."
        cp $work_dir/rootfs_decrypt/end.gz $unpack_dir/grub.gz
    fi

    log INFO "Decompress rootfs ..."
    xz -dkc $work_dir/rootfs_decrypt/rootfs.ext2 > $work_dir/rootfs.ext2
    if [ $? -ne 0 ]; then
        log Error "Decompress rootfs fail!"
        exit 1
    fi
    
    log INFO "Mount rootfs ..."
    mkdir $work_dir/rootfs-mount
    mount $work_dir/rootfs.ext2 $work_dir/rootfs-mount
    if [ $? -ne 0 ]; then
        log Error "Mount rootfs fail!"
        exit 1
    fi

    log INFO "Copy rootfs to $unpack_dir/rootfs ..."
    mkdir $unpack_dir/rootfs
    cp -rfp $work_dir/rootfs-mount/* $unpack_dir/rootfs
    if [ $? -ne 0 ]; then
        log Error "Copy rootfs to $unpack_dir/rootfs fail!"
        exit 1
    fi

    log INFO "Umount iso ..."
    umount_retry $work_dir/rootfs-mount
    if [ $? -ne 0 ]; then
        log Error "Umount rootfs fail!"
        exit 1
    fi
}

function unpack () {
    local file="$1"
    if [ ! -f "$file" ]; then
        log ERROR "File not exist."
        exit 1
    fi
    
    clean_all
    mkdir $work_dir
    mkdir $unpack_dir

    echo "Process $file file...."
    ext="${file##*.}"
    if [ "$ext" = "iso" ]; then
        unpack_iso $file
    elif [ "$ext" = "bin" ]; then
        unpack_bin $file
    else
        log ERROR "Unknown file."
        exit 1
    fi

    clean_work

    log INFO "Unpack $file success!"
}

function update_release_conf () {
    log INFO "Start update release file ..."
    local release_file="$unpack_dir/rootfs/etc/release"

    if [ ! -f "$release_file" ]; then
        log ERROR "rootfs release file not found!"
        exit 1
    fi

    firmware_id="$1"
    version="$2"
    build_time="$3"
    
    if [ "$firmware_id" = "" ]; then
        firmware_id=$(get_conf FIRMWAREID "$release_file")
    fi
    if [ "$version" = "" ]; then
        version=$(get_conf VERSION "$release_file")
    fi
    if [ "$build_time" = "0" ]; then
        build_time=$(date +"%Y%m%d%H%M")
    elif [ "$build_time" = "" ]; then
        build_time=$(get_conf BUILD_DATE "$release_file")
    fi

    sysbit=$(get_conf SYSBIT "$release_file")
    is_enterprise=$(get_conf ENTERPRISE "$release_file")

    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)
    local patch=$(echo $version | cut -d. -f3)
    local version_num=$(printf "%d%04d%04d" "$major" "$minor" "$patch")

    if [ "$is_enterprise" != "" ]; then
        is_enterprise=" $is_enterprise"
    fi

    version_str="$version $sysbit$is_enterprise Build$build_time"

    set_conf FIRMWAREID  "$firmware_id" "$release_file" none
    set_conf VERSION     "$version"     "$release_file" none
    set_conf VERSION_NUM "$version_num" "$release_file" none
    set_conf BUILD_DATE  "$build_time"  "$release_file" none
    set_conf VERSTRING   "$version_str" "$release_file" always
}

function pack_rootfs () {
    if [ ! -d "$unpack_dir" ]; then
        log ERROR "Not found unpack rootfs!"
        exit 1
    fi

    clean_work

    update_release_conf "$1" "$2" "$3"
    if [ $? -ne 0 ]; then
        log Error "Update release file fail!"
        exit 1
    fi

    local grub="$4"
    if [ "$grub" != "" ]; then
        if [ -f "$grub" ]; then
            log INFO "Append file $grub"
            grub="-a $grub"
        else
            log ERROR "Not found grub.gz"
        fi
    fi

    mkdir $work_dir

    log INFO "Create rootfs.img size 512M"
    dd if=/dev/zero of=$work_dir/rootfs.img bs=512M count=1
    if [ $? -ne 0 ]; then
        log Error "Create rootfs.img fail!"
        exit 1
    fi

    log INFO "Create ext4 filesystem"
    mkfs.ext4 -F -L linuxroot $work_dir/rootfs.img
    if [ $? -ne 0 ]; then
        log Error "Create ext4 filesystem fail!"
        exit 1
    fi

    log INFO "Mount rootfs"
    mkdir $work_dir/rootfs-mount
    mount $work_dir/rootfs.img $work_dir/rootfs-mount
    if [ $? -ne 0 ]; then
        log Error "Mount rootfs fail!"
        exit 1
    fi

    log INFO "Copy system file"
    cp -rfp $unpack_dir/rootfs/* $work_dir/rootfs-mount
    if [ $? -ne 0 ]; then
        log Error "Copy system file fail!"
        exit 1
    fi

    log INFO "Umount rootfs"
    umount_retry $work_dir/rootfs-mount
    if [ $? -ne 0 ]; then
        log Error "Umount rootfs fail!"
        exit 1
    fi

    log INFO "Check and resize rootfs"
    e2fsck -p -f $work_dir/rootfs.img
    if [ $? -ne 0 ]; then
        log Error "Check rootfs fail!"
        exit 1
    fi

    resize2fs -M $work_dir/rootfs.img
    if [ $? -ne 0 ]; then
        log Error "Resize rootfs fail!"
        exit 1
    fi

    log INFO "Compression rootfs"
    xz -zkc -T0 --check=crc32 $work_dir/rootfs.img > $work_dir/rootfs.img.xz
    if [ $? -ne 0 ]; then
        log Error "Compression rootfs fail!"
        exit 1
    fi

    log INFO "Encrypt rootfs"
    local output=$(tools/rootfs-utils encode $work_dir/rootfs.img.xz $work_dir/rootfs.img.xz.bin -v2 $grub)
    if [ $? -ne 0 ]; then
        log Error "Encrypt rootfs fail!"
        exit 1
    fi
    firmware_size=$(echo $output | grep "Encrypt data size" | awk '{print $4}')

    log INFO "Pack rootfs success."
    log INFO "File path: $work_dir/rootfs.img.xz.bin"
}

function pack_bin () {
    if [ ! -d "$unpack_dir" ]; then
        log ERROR "Not found unpack rootfs!"
        exit 1
    fi

    pack_rootfs "$1" "$2" "$3"
    if [ $? -ne 0 ]; then
        log Error "Update release file fail!"
        exit 1
    fi

    log INFO "Create iso"
    dd if=/dev/zero of=$work_dir/firmware.iso bs=1024 count=51200
    mkfs.ext2 -L -F $work_dir/firmware.iso
    if [ $? -ne 0 ]; then
        log Error "Create iso fail!"
        exit 1
    fi

    log INFO "Mount iso"
    mkdir $work_dir/iso
    mount $work_dir/firmware.iso $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Mount iso fail!"
        exit 1
    fi

    log INFO "Copy iso file"
    cp -rfp $bin_files/* $work_dir/iso
    cp $unpack_dir/vmlinuz $work_dir/iso/boot/vmlinuz
    cp $work_dir/rootfs.img.xz.bin $work_dir/iso/boot/rootfs
    if [ $? -ne 0 ]; then
        log Error "Copy iso file fail!"
        exit 1
    fi

    log INFO "Update grub cfg"
    sed -i "s|%version%|$version|g" $work_dir/iso/boot/grub/grub.cfg
    if [ $? -ne 0 ]; then
        log Error "Update grub cfg fail!"
        exit 1
    fi

    log INFO "Umount iso"
    umount_retry $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Umount iso fail!"
        exit 1
    fi

    log INFO "Compressed iso"
    gzip -n -c $work_dir/firmware.iso > $work_dir/firmware.iso.gz
    if [ $? -ne 0 ]; then
        log Error "Compressed iso fail!"
        exit 1
    fi

    # ┌─────────────────┬──────────────────────┬─────────────────────┐
    # │  Header Length  │    Header Data       │   Compressed Data   │
    # │    (4 bytes)    │   (headlen bytes)    │   (remaining data)  │
    # │   Big Endian    │                      │                     │
    # └─────────────────┴──────────────────────┴─────────────────────┘
    #      0-3 bytes            headlen                 to EOF

    log INFO "Build version json"
    local size=$(wc -c $work_dir/firmware.iso.gz | cut -d' ' -f1)
    local md5=$(md5sum $work_dir/firmware.iso.gz)
    local sha256=$(sha256sum $work_dir/firmware.iso.gz)

    is_enterprise=$(echo "$is_enterprise" | tr ' ' '_')
    local name="iKuai8_${sysbit}_${version}${is_enterprise}_Build${build_time}.bin"
    
    local formatted=$(echo "$build_time" | sed 's/\(....\)\(..\)\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:00/')
    local timestamp=$(date -d "$formatted" +%s)

    local json='{filename:$filename,firmwareid:$firmwareid,version:$version,sysbit:$sysbit,timestamp:$timestamp,length:$length,md5:$md5,sha256:$sha256}'
    local result=$(
        jq -c -n \
            --arg filename "$name" \
            --arg firmwareid "$firmware_id" \
            --arg version "$version" \
            --arg sysbit "$sysbit" \
            --arg timestamp "$timestamp" \
            --arg length "$size" \
            --arg md5 "${md5:0:32}" \
            --arg sha256 "${sha256:0:32}" \
            "$json"
    )
    if [ "$result" = "" ]; then
        log ERROR "Generate version json fail!"
        exit 1
    fi

    log INFO "Compressed version json"
    echo "$result" > $work_dir/header_info.json
    gzip -n -c $work_dir/header_info.json > $work_dir/header_info.json.gz
    if [ $? -ne 0 ]; then
        log ERROR "Compressed version json fail!"
        exit 1
    fi

    log INFO "Encrypt version json"
    dd if=$work_dir/header_info.json.gz bs=1 skip=10 of=$work_dir/header_info.json.gz.bin
    if [ $? -ne 0 ]; then
        log ERROR "Encrypt version json fail!"
        exit 1
    fi

    log INFO "Pack firmware"
    local HEADER_LEN=$(wc -c $work_dir/header_info.json.gz.bin | cut -d' ' -f1)
    printf "\\$(printf "%o" $((($HEADER_LEN >> 24) & 0xFF)))" > $work_dir/$name
    printf "\\$(printf "%o" $((($HEADER_LEN >> 16) & 0xFF)))" >> $work_dir/$name
    printf "\\$(printf "%o" $((($HEADER_LEN >> 8) & 0xFF)))" >> $work_dir/$name
    printf "\\$(printf "%o" $(($HEADER_LEN & 0xFF)))" >> $work_dir/$name

    cat $work_dir/header_info.json.gz.bin >> $work_dir/$name
    cat $work_dir/firmware.iso.gz >> $work_dir/$name

    log INFO "Pack firmware success!"
    log INFO "File path: $work_dir/$name"
}

function pack_iso () {
    if [ ! -d "$unpack_dir" ]; then
        log ERROR "Not found unpack rootfs!"
        exit 1
    fi
    
    pack_rootfs "$1" "$2" "$3" "$iso_files/grub.gz"
    if [ $? -ne 0 ]; then
        log Error "Update release file fail!"
        exit 1
    fi
    log INFO "Firmware size: $firmware_size"

    log INFO "Create iso"
    mkdir $work_dir/iso
    cp -rfp $iso_files/iso/* $work_dir/iso
    cp $unpack_dir/vmlinuz $work_dir/iso/boot/vmlinuz
    cp $work_dir/rootfs.img.xz.bin $work_dir/iso/boot/rootfs

    log INFO "Update grub cfg"
    sed -i "s|%version%|$version|g" $work_dir/iso/boot/grub/grub.cfg
    sed -i "s|%initrd_length%|$firmware_size|g" $work_dir/iso/boot/grub/grub.cfg
    if [ $? -ne 0 ]; then
        log Error "Update grub cfg fail!"
        exit 1
    fi
    
    is_enterprise=$(echo "$is_enterprise" | tr ' ' '_')
    local name="iKuai8_${sysbit}_${version}${is_enterprise}_Build${build_time}.iso"

    log INFO "Build iso"
    xorriso -as mkisofs \
        -V 'CDROM' \
        -o $work_dir/$name \
        -c /boot.catalog \
        -b /boot/grub/grub-iso.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
        -eltorito-alt-boot \
        -e /boot/grub/grub-efi.img \
            -no-emul-boot \
            -boot-load-size 3072 \
        -isohybrid-gpt-basdat \
        $work_dir/iso
    if [ $? -ne 0 ]; then
        log Error "Build iso fail!"
        exit 1
    fi

    log INFO "Build iso success!"
    log INFO "File path: $work_dir/$name"
}

function patch () {
    local file="$1"
    local patch_dir="$(realpath "$3")"

    log INFO "Unpack file $file"
    unpack "$file"
    if [ $? -ne 0 ]; then
        log Error "Unpack file fail!"
        exit 1
    fi

    current_pwd=$(pwd)

    mkdir $work_dir

    log INFO "Run patch script .."
    mapfile -t files < <(find "$patch_dir" -maxdepth 2 -type f -name '*.sh' | sort -V)
    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            unset -f install 2>/dev/null
            unset -f script_dir 2>/dev/null

            log INFO "Switch to $unpack_dir/rootfs"
            cd $unpack_dir/rootfs

            script_dir=$(dirname "$f")
            . "$f"
            if declare -f install >/dev/null 2>&1; then
                log INFO "Running $f install"
                install
            else
                log ERROR "Not found install function in $f"
            fi
        else
            log ERROR "Not found $f file"
        fi
    done

    clean_work

    log INFO "Switch to $current_pwd"
    cd $current_pwd

    if [ "$2" = "iso" ]; then
        pack_iso "$4" "$5" "$6"
    elif [ "$2" = "bin" ]; then
        pack_bin "$4" "$5" "$6"
    fi
}

function clean_work () {
    log INFO "Clean work dir"
    for d in "$work_dir"/*/; do
        [ -d "$d" ] || continue
        if mountpoint -q "$d"; then
            log WARN "$d is mount, umount ing..."
            umount_retry "$d"
        fi
    done
    if [ -d "$work_dir" ]; then
        rm -rf $work_dir
    fi
}

function clean_all () {
    clean_work
    log INFO "Clean unpack dir"
    if [ -d "$unpack_dir" ]; then
        rm -rf $unpack_dir
    fi
}


case "$1" in
    unpack|pack_rootfs|pack_bin|pack_iso|patch)
        func="$1"
        shift
        "$func" "$@"
    ;;
    clean)
        clean_all
        log INFO "Clean build tools"
        if [ -f "tools/rootfs-utils" ]; then
            rm -f tools/rootfs-utils
        fi
    ;;
    *)
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  unpack <xxx.iso|xxx.bin>
      unpack iso or bin file

  pack_rootfs [firmware_id] [version] [build_time]
      pack rootfs

  pack_bin [firmware_id] [version] [build_time]
      pack bin file

  pack_iso [firmware_id] [version] [build_time]
      pack iso file

  patch <xxx.bin|xxx.iso> <out_type:bin|iso> <patch_dir> [firmware_id] [version] [build_time]
      patch iso or bin file

  clean
      clean work dir

Args:
  Build time:
      Empty : Not change
      0     : Current time
      Number: Use input time

  Firmware id:
      Empty: Not change
      10001: Free Edition
      10002: Enterprise
      Other: Use input id

  Version:
      Empty: Not change
      Other: Use input version

Examples:
  $0 unpack xxx.iso
  $0 unpack xxx.bin
  $0 pack_rootfs
  $0 pack_bin Id Version 0
  $0 pack_iso
  $0 patch xxx.iso patch_dir
  $0 patch xxx.bin patch_dir 202509221910
EOF
    exit 1
    ;;
esac

