#!/bin/bash

function install () {
    log INFO "Set password"
    pw=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c16)
    salt=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c8)
    hash=$(openssl passwd -1 -salt "$salt" "$pw")

    log INFO "New password: $pw"
    sed -i "s/^root:.*/root:$hash:17857:0:99999:7:::/" etc/shadow
    sed -i "s/^sshd:.*/sshd:$hash:17857:0:99999:7:::/" etc/shadow

    log INFO "Set root login to ash"
    sed -i "s|root:x:0:0:root:/root:/etc/setup/rc|root:x:0:0:root:/root:/bin/ash|" etc/passwd

    log INFO "Disable service code"
    sed -i '/__request_scode >\/dev\/null/i\	return 0' usr/ikuai/script/register.sh

    log INFO "Remove cloud message"
    sed -i '/^__start() {$/a\	quit' usr/ikuai/script/ikmessages.sh

    log INFO "Force bind cloud"
    sed -i '/^__check_bind()$/,/^}$/{
    /^{$/a\
    local code='\''ForceBindCloud'\''\
    local comment='\''IK-Router'\''\
    local node='\''0'\''\
    sql_config_update \$IK_DB_CONFIG register "id=1" code:str comment:str node:int >/dev/null 2>&1\
    __bind_ok\
    return 0
}' usr/ikuai/script/register.sh

    log INFO "Remove get hosts"
    sed -i '/if \[ -z "\$OEMNAME" -o "\$OEMNAME" = "oem" \]; then/{N; /boot_load_async  utils\/get_hosts\.sh/{N; /fi/d;}}' usr/ikuai/script/rc
    rm -rf etc/get_hosts
    rm -f usr/ikuai/script/utils/get_hosts.sh

    log INFO "Remove update hosts"
    sed -i '/update_hosts\.sh/d' usr/ikuai/script/rc
    rm -f usr/ikuai/script/utils/update_hosts.sh

    # log INFO "Remove dingtalk"
    # sed -i '/dingtalk\.sh/d' usr/ikuai/script/rc
    # rm -rf usr/DTalkInside

    log INFO "Remove remote control"
    local start=$(grep -n "ik_rc_client" usr/ikuai/script/utils/collection.sh | cut -d: -f1 | head -n1)
    local end=$((start + 16))
    sed -i "${start},${end}d" usr/ikuai/script/utils/collection.sh
    sed -i '/^start_remote_services()/,/^}/d' usr/ikuai/script/rc
    sed -i '/^\s*start_remote_services\s*$/d' usr/ikuai/script/rc
    sed -i '/^\s*cre\s>\/dev\/null\s2>&1\s&\s*$/d' usr/ikuai/script/rc

    log INFO "Remove monitor rc"
    local start=$(grep -n "__get_process_status pmd" usr/ikuai/script/utils/monitor_process.sh | cut -d: -f1 | head -n1)
    local end=$((start + 28))
    sed -i "${start},${end}d" usr/ikuai/script/utils/monitor_process.sh
    sed -i '/^using_hosts_update_process()/,/^}/d' usr/ikuai/script/rc
    sed -i '/^\s*using_hosts_update_process\s*$/d' usr/ikuai/script/rc

    log INFO "Remove client report"
    sed -i '/^get_remote_host()/,/^}/d' usr/ikuai/script/client.sh
    sed -i '/^\s*get_remote_host\s*$/d' usr/ikuai/script/client.sh
    sed -i '/^get_config()/,/^}/d' usr/ikuai/script/client.sh
    sed -i '/^\s*get_config\s*$/d' usr/ikuai/script/client.sh

    log INFO "Remove all bin"
    rm -f usr/sbin/pmd
    rm -f usr/sbin/ik_rc_client
    rm -f usr/sbin/cre

    log INFO "Remove ik cret"
    rm -rf etc/ssl/32015
    rm -rf etc/ssl/32016
    rm -rf etc/ssl/32017

    log INFO "Add custom submit3"
    cp $script_dir/submit.lua usr/ikuai/script/utils/submit3.lua
    chmod +x usr/ikuai/script/utils/submit3.lua
    sed -i 's|^SUBMIT_CACHE=.*|SUBMIT_CACHE=/usr/ikuai/script/utils|' usr/ikuai/include/submit.sh
    sed -i 's|\$SUBMIT_CACHE/submit3|\$SUBMIT_CACHE/submit3.lua|g' usr/ikuai/include/submit.sh

    log INFO "Remove submit"
    rm -f usr/ikuai/script/utils/submit.lua
    # sed -i '/utils\/submit\.lua/d' usr/ikuai/script/rc
    sed -i 's|utils\/submit\.lua|utils\/submit3\.lua|' usr/ikuai/script/rc

    log INFO "Remove remoter config"
    rm -rf etc/remote2

    log INFO "Block log report"
    echo "0.0.0.0 alpha-cloud-log.cn-hangzhou.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-shanghai.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-nanjing.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-fuzhou.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-qingdao.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-beijing.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-zhangjiakou.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-huhehaote.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-wulanchabu.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-shenzhen.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-heyuan.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-guangzhou.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-chengdu.log.aliyuncs.com" >> etc/hosts.d/custom
    echo "0.0.0.0 alpha-cloud-log.cn-hongkong.log.aliyuncs.com" >> etc/hosts.d/custom
    cat etc/hosts.d/* > etc/hosts

    log INFO "Add iptable rule"
    sed -i '/^create_iptables_chain()/,/^}/ { /^}/i\
    ipt_drop_rc
}' usr/ikuai/script/rc
    echo "ipt_drop_rc()" >> usr/ikuai/script/rc
    echo "{" >> usr/ikuai/script/rc
    echo "	iptables -N cloud_DROP" >> usr/ikuai/script/rc
    # ik_rc_client
    echo "	iptables -I cloud_DROP -p tcp --dport 2500:2510 -j DROP" >> usr/ikuai/script/rc
    echo "	iptables -I cloud_DROP -p tcp --dport 2010:2020 -j DROP" >> usr/ikuai/script/rc
    # utils/update_hosts.sh
    echo "	iptables -I cloud_DROP -p tcp --dport 32015:32017 -j DROP" >> usr/ikuai/script/rc
    # script/client.sh
    echo "	iptables -I cloud_DROP -p tcp --dport 2016 -j DROP" >> usr/ikuai/script/rc
    echo "	iptables -I cloud_DROP -p tcp --dport 9443 -j DROP" >> usr/ikuai/script/rc
    # cre
    echo "	iptables -I cloud_DROP -p tcp --dport 1853 -j DROP" >> usr/ikuai/script/rc
    # pmd
    echo "	iptables -I cloud_DROP -p tcp --dport 1863 -j DROP" >> usr/ikuai/script/rc
    echo "	iptables -I cloud_DROP -p tcp --dport 15602 -j DROP" >> usr/ikuai/script/rc
    
    echo "	iptables -I OUTPUT -j cloud_DROP" >> usr/ikuai/script/rc
    echo "	iptables -I INPUT -j cloud_DROP" >> usr/ikuai/script/rc
    echo "}" >> usr/ikuai/script/rc
}