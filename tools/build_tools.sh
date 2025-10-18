#!/bin/bash

. utils.sh

if [ ! -f "./rootfs-utils" ]; then
    log INFO "Not found rootfs tools."
    log INFO "Start build rootfs tools."

    cd rootfs_tools
    make

    mv rootfs ../rootfs-utils
    cd ..
fi

if [ ! -f "./rootfs-utils" ]; then
    log ERROR 'Compile rootfs-utils fail!'
    exit 1
fi
