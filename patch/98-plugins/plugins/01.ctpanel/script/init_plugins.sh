#!/bin/bash /etc/ikcommon

init()
{
    [ -d /tmp/iktmp/plugins/logs ] || mkdir -p /tmp/iktmp/plugins/logs
    [ -d /etc/mnt/plugins/configs/repos ] || mkdir -p /etc/mnt/plugins/configs/repos
    [ -d /etc/mnt/plugins/configs/img ] || mkdir -p /etc/mnt/plugins/configs/img
    [ -d /usr/ikuai/www/plugins/img ] || ln -sf /etc/mnt/plugins/configs/img /usr/ikuai/www/plugins/img

    if [ ! -f /etc/mnt/plugins/configs/config.sh ]; then
        # 初始化插件安装路径，用于存放插件ipk包及配置文件
        echo "INN_PLUGIN_INSTALL_DIR=/etc/mnt/iplugins" > /etc/mnt/plugins/configs/config.sh
        echo "EXT_PLUGIN_CONFIG_DIR=/etc/mnt/plugins/configs" >> /etc/mnt/plugins/configs/config.sh
        echo "EXT_PLUGIN_LOG_DIR=/tmp/iktmp/plugins/logs" >> /etc/mnt/plugins/configs/config.sh
        echo "RMT_PLUGIN_REPOS_DIR=/etc/mnt/plugins/configs/repos" >> /etc/mnt/plugins/configs/config.sh

        echo "EXT_PLUGIN_IPK_DIR=/etc/log/plugins" >> /etc/mnt/plugins/configs/config.sh

        # X86默认在内存中运行,否则空间太小，待优化 
        # echo "EXT_PLUGIN_INSTALL_DIR=/etc/log/plugins" >> /etc/mnt/plugins/configs/config.sh
        # echo "EXT_PLUGIN_RUN_INMEM=no" >> /etc/mnt/plugins/configs/config.sh
        echo "EXT_PLUGIN_INSTALL_DIR=/tmp/iktmp/plugins" >> /etc/mnt/plugins/configs/config.sh
        echo "EXT_PLUGIN_RUN_INMEM=yes" >> /etc/mnt/plugins/configs/config.sh
    fi

    if [ ! -f /etc/mnt/plugins/configs/repos/repos.json ] || ! jq empty /etc/mnt/plugins/configs/repos/repos.json >/dev/null 2>&1; then
        echo '[{"id": "5f74366d-090d-4540-a04f-d1d885f0b93f", "name": "官方插件源", "url": "https://ikuaipatch.github.io/plugins", "enabled": "yes"}]' > /etc/mnt/plugins/configs/repos/repos.json
    fi
}

boot()
{
    . /etc/mnt/plugins/configs/config.sh

    # 如果是内存运行模式，那么从IPK解压外部插件到内存
    if [ "$EXT_PLUGIN_RUN_INMEM" = "yes" ] && [ -d "$EXT_PLUGIN_IPK_DIR" ]; then
        for FILE in "$EXT_PLUGIN_IPK_DIR"/*.ipk; do
            if [ ! -f $FILE ]; then
                continue
            fi
            metadata=$(tar -xzOf $FILE ./html/metadata.json)
            plugin_name=$(echo "$metadata" | jq -r '.name')

            mkdir -p $EXT_PLUGIN_INSTALL_DIR/$plugin_name
            tar -xzf $FILE -C $EXT_PLUGIN_INSTALL_DIR/$plugin_name
        done
    fi
    for script in "$EXT_PLUGIN_INSTALL_DIR"/*/install.sh; do
        if [ ! -f $script ]; then
            continue
        fi
        chmod +x $script
        $script boot
    done
}
