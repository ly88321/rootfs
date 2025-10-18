#!/bin/bash

function install () {
    log INFO "Multi ipv6 set 9999"
    sed -i 's/num=3/num=9999/' usr/ikuai/script/ipv6.sh
    sed -i '/^boot()$/{
    n
    a\
    echo "expires=0 num=9999 enterprise=1" > \${PKG_PATH}
}' usr/ikuai/script/ipv6.sh

}
