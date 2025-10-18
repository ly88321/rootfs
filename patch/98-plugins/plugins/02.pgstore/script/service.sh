#!/bin/bash /etc/ikcommon
PLUGIN_NAME="02.pgstore"
. /etc/release
. /etc/mnt/plugins/configs/config.sh

[ $ARCH = "mips" ] && platform="mipsle"
[ $ARCH = "arm" ] && platform="arm64"
[[ $ARCH = "x86" && $SYSBIT = "x32" ]] && platform="x86"
[[ $ARCH = "x86" && $SYSBIT = "x64" ]] && platform="x86_64"

debug() {
    debuglog=$( [ -s /tmp/debug_on ] && cat /tmp/debug_on || echo -n /tmp/debug.log )
    if [ "$1" = "clear" ]; then
        rm -f $debuglog && return
    fi

    if [ -f /tmp/debug_on ]; then
        TIME_STAMP=$(date +"%Y%m%d %H:%M:%S")
        echo "[$TIME_STAMP]: PL> $1" >>$debuglog
    fi
}

compare_version() {

    version1=$1
    version2=$2
    v1_1=`echo $version1 | cut -d '.' -f 1`
    v1_2=`echo $version1 | cut -d '.' -f 2`
    v1_3=`echo $version1 | cut -d '.' -f 3`
    v2_1=`echo $version2 | cut -d '.' -f 1`
    v2_2=`echo $version2 | cut -d '.' -f 2`
    v2_3=`echo $version2 | cut -d '.' -f 3`

    v1sum=$((v1_1 * 10000 + v1_2 * 100 + v1_3))
    v2sum=$((v2_1 * 10000 + v2_2 * 100 + v2_3))
    if [ $v1sum -gt $v2sum ]; then
        return 0 # version1 > version2
    else
        return 1 # version1 <= version2
    fi
}


show()
{
    Show __json_result__
}

__show_data()
{
    # 获取已安装插件信息
    local installed
	local _json
    onlinePlugins=$(cat /etc/mnt/plugins/configs/plugins.json 2>/dev/null)
	for f in $(ls /usr/ikuai/www/plugins) ;do
		if _json=$(cat /usr/ikuai/www/plugins/$f/metadata.json) ;then
            name=$(echo $_json | jq -r '.name')
            oldversion=$(echo $_json | jq -r '.version')
            newversion=$(echo "$onlinePlugins" | jq -r ".[] | select(.name == \"$name\") | .version")
            releasenotes=$(echo "$onlinePlugins" | jq -r ".[] | select(.name == \"$name\") | .releasenotes")
            upgradetype=$(echo "$onlinePlugins" | jq -r ".[] | select(.name == \"$name\") | .upgradetype")
            if compare_version "$newversion" "$oldversion"; then
                _json=$(echo $_json | jq ".newversion = \"$newversion\" | .releasenotes = \"$releasenotes\" | .upgradetype = \"$upgradetype\"")
            fi

			installed+="${installed:+,}$_json"
		fi
	done
	installed="[$installed]"
	json_append __json_result__ installed:json

    # 获取内置存储空间信息
    precentage=""
    totalSize="-"
    avaiableSize="-"

    internel_storage_dir="/etc/mnt"
    [ "$EXT_PLUGIN_RUN_INMEM" = "yes" ] && internel_storage_dir="/etc/mnt"
    echo "$EXT_PLUGIN_INSTALL_DIR" | grep -q "^/etc/log/" && internel_storage_dir="/etc/log"
    [ $ARCH = "x86" ] && internel_storage_dir="/etc/log"
    
    precentage=$(df -h $internel_storage_dir | sed -n '2p' | awk -F " " '{print($5)}' | tr -d '%')
    totalSize=$(df -h $internel_storage_dir | sed -n '2p' | awk -F " " '{print($2)}')
    avaiableSize=$(df -h $internel_storage_dir | sed -n '2p' | awk -F " " '{print($4)}')

    local plusage=$(json_output precentage:str totalSize:str avaiableSize:str)
    json_append __json_result__ plusage:json

    # 获取外置存储空间信息
    precentage=""
    totalSize="-"
    avaiableSize="-"

    if echo "$EXT_PLUGIN_IPK_DIR" | grep -q "^/etc/disk"; then
        if [ -d "$EXT_PLUGIN_IPK_DIR" ] || checkExtStorage; then
            precentage=$(df -h $EXT_PLUGIN_IPK_DIR | sed -n '2p' | awk -F " " '{print($5)}' | tr -d '%')
            totalSize=$(df -h $EXT_PLUGIN_IPK_DIR | sed -n '2p' | awk -F " " '{print($2)}')
            avaiableSize=$(df -h $EXT_PLUGIN_IPK_DIR | sed -n '2p' | awk -F " " '{print($4)}')
        fi
    fi
    local explusage=$(json_output precentage:str totalSize:str avaiableSize:str)
    json_append __json_result__ explusage:json

    local arch=$ARCH
    json_append __json_result__ arch:str

    return 0
}

__show_onlinePlugins()
{
    json_decode_file repo $RMT_PLUGIN_REPOS_DIR/repos.json

    i=1
    ignoreimg=0
    havenew=0
    onlinePlugins=""

    while true; do
        eval id=\$repo_${i}_id
        eval name=\$repo_${i}_name
        eval url=\$repo_${i}_url
        eval enabled=\$repo_${i}_enabled

        [ -z "$name" ] && break
        
        if [ "$enabled" != "yes" ]; then
            i=$((i+1))
            continue
        fi
        if [ ! -f "$RMT_PLUGIN_REPOS_DIR/$id/plugins.json" ]; then
            i=$((i+1))
            continue
        fi

        plugins=$(cat $RMT_PLUGIN_REPOS_DIR/$id/plugins.json 2>/dev/null)

        pluginInfo=''
        json_append pluginInfo id:str
        json_append pluginInfo name:str
        json_append pluginInfo url:str
        json_append pluginInfo plugins:json

        onlinePlugins+="${onlinePlugins:+,}$pluginInfo"

        i=$((i+1))
    done
    onlinePlugins="[$onlinePlugins]"

    # 过滤已安装的插件
    local installed=""
    for f in $(ls /usr/ikuai/www/plugins) ;do
        if [ ! -f "/usr/ikuai/www/plugins/$f/metadata.json" ]; then
            continue
        fi
        if _json=$(cat /usr/ikuai/www/plugins/$f/metadata.json) ;then
            pluginName=$(echo $_json | jq -r '.name')
            installed+="${installed:+,}\"$pluginName\""
        fi
    done
    installed="[$installed]"
    onlinePlugins=$(echo "$onlinePlugins" | jq "map(.plugins |= map(select(.name as \$n | $installed | index(\$n) | not)))")

    json_append __json_result__ onlinePlugins:json
    json_append __json_result__ havenew:int
}

updateSoftwareSouce()
{
    json_decode_file repo $RMT_PLUGIN_REPOS_DIR/repos.json

    i=1
    ignoreimg=0
    havenew=0

    msg=''

    while true; do
        eval id=\$repo_${i}_id
        eval name=\$repo_${i}_name
        eval url=\$repo_${i}_url
        eval enabled=\$repo_${i}_enabled

        [ -z "$name" ] && break
        
        if [ "$enabled" != "yes" ]; then
            i=$((i+1))
            continue
        fi

        if [ ! -d "$RMT_PLUGIN_REPOS_DIR/$id" ]; then
            mkdir "$RMT_PLUGIN_REPOS_DIR/$id"
        fi

        plugins=$(wget -qO- "$url/plugins.json")
        if [ "$plugins" = "" ] || ! echo "$plugins" | jq empty >/dev/null 2>&1; then
            msg="${msg:+,}$name 插件数据获取失败"
        fi
        plugins=$(echo "$plugins" | jq "map(select(.compatibility | index(\"$platform\") or index(\"all\")))")
        echo "$plugins" > $RMT_PLUGIN_REPOS_DIR/$id/plugins.json
        
        wget -qO /tmp/tempimg.tar.gz "$url/img.tar.gz"
        if [ $? -ne 0 ]; then
            msg="${msg:+,}$name 获取插件图片失败"
        fi
        if [ -d "/etc/mnt/plugins/configs/img/$id" ]; then
            rm -rf /etc/mnt/plugins/configs/img/$id
        fi
        mkdir /etc/mnt/plugins/configs/img/$id
        tar -xzf /tmp/tempimg.tar.gz -C /etc/mnt/plugins/configs/img/$id
        rm /tmp/tempimg.tar.gz

        i=$((i+1))
    done

    if [ "$msg" = "" ]; then
        return 0
    fi

    echo "$msg"
    return 1
}

__get_repo()
{
    repo_id=$1

    json_decode_file repo $RMT_PLUGIN_REPOS_DIR/repos.json

    repo_dir=''
    repo_url=''
    i=1
    while true; do
        eval json_repo_id=\$repo_${i}_id
        eval json_repo_name=\$repo_${i}_name
        eval json_repo_url=\$repo_${i}_url
        [ -z "$json_repo_id" ] && break
        if [ "$json_repo_id" = "$repo_id" ]; then
            repo_dir="$json_repo_name"
            repo_url="$json_repo_url"
            break
        fi
        i=$((i+1))
    done
    if [ "$repo_dir" = "" ]; then
        return 1
    fi

    repo_dir="$RMT_PLUGIN_REPOS_DIR/$repo_dir"
    return 0
}

upgrade_online()
{
    __get_repo "$repo_id"
    if [ $? -ne 0 ]; then
        echo "未找到仓库: $repo_id"
        return 1
    fi

    metadata=$(jq ".[] | select(.name == \"$name\")" $repo_dir/plugins.json)
    compatibility=$(echo "$metadata" | jq -r '.compatibility')
    version=$(echo "$metadata" | jq -r '.version')
    build=$(echo "$metadata" | jq -r '.build')
    upgradetype=$(echo "$metadata" | jq -r '.upgradetype')
    [ "upgradetype" ] || upgradetype="upgrade"

    if echo "$compatibility" | grep -q "all"; then
        url="$repo_url/ipk/plugin-$name-v$version-Build$build.ipk"
    else
        url="$repo_url/ipk/plugin-$name-$platform-v$version-Build$build.ipk"
    fi
    
    if wget -O /tmp/iktmp/import/file $url; then
        __install $upgradetype
    else
        echo "下载安装文件失败，请检查网络！"
        return 1
    fi
}

install_online()
{
    __get_repo "$repo_id"
    if [ $? -ne 0 ]; then
        echo "未找到仓库: $repo_id"
        return 1
    fi

    local pluginFeatureId=$(jq -r "map(select(.name == \"$name\"))[0].featureId" $repo_dir/plugins.json) 
    [[ -z "$pluginFeatureId" || "$pluginFeatureId" = "null" ]] && pluginFeatureId=0
    if echo "$compatibility" | grep -q "all"; then
        url="$repo_url/ipk/plugin-$name-v$version-Build$build.ipk"
    else
        url="$repo_url/ipk/plugin-$name-$platform-v$version-Build$build.ipk"
    fi
    
    if wget -O /tmp/iktmp/import/file $url; then
        __install new
        return $?
    else
        echo "下载安装文件失败，请检查网络！"
        return 1
    fi
}

install()
{
    __install new
    return $?
}

__install()
{
    installtype=$1
    rm -rf /tmp/iktmp/app_install && mkdir /tmp/iktmp/app_install
    FILE=/tmp/iktmp/import/file
    metadata=$(tar -xzOf $FILE ./html/metadata.json)
    plugin_name=$(echo "$metadata" | jq -r '.name')

    if [ "$plugin_name" = "" ]; then
        echo "插件解析失败"
        return 1
    fi

    if [ "$EXT_PLUGIN_RUN_INMEM" = "yes" ]; then
        mkdir -p $EXT_PLUGIN_IPK_DIR && cp -f $FILE $EXT_PLUGIN_IPK_DIR/$plugin_name.ipk
    fi

    rm -rf $EXT_PLUGIN_INSTALL_DIR/$plugin_name
    mkdir -p $EXT_PLUGIN_INSTALL_DIR/$plugin_name
    tar -xzf $FILE -C $EXT_PLUGIN_INSTALL_DIR/$plugin_name
    rm $FILE
    bash $EXT_PLUGIN_INSTALL_DIR/$plugin_name/install.sh $installtype
    return $?
}

uninstall()
{
    type=$(jq -r ".type" ${EXT_PLUGIN_INSTALL_DIR}/${app}/html/metadata.json)
    if [ "$type" = "internal" ]; then
        echo "内置插件不可删除！"
        return 1
    fi
    if [ -f "${EXT_PLUGIN_INSTALL_DIR}/${app}/uninstall.sh" ]; then
        bash "${EXT_PLUGIN_INSTALL_DIR}/${app}/uninstall.sh"
        return 0
    elif [ -f "${INN_PLUGIN_INSTALL_DIR}/${app}/uninstall.sh" ]; then
        bash "${INN_PLUGIN_INSTALL_DIR}/${app}/uninstall.sh"
    else
        echo "未找到删除脚本！"
        return 1
    fi
}

checkExtStorage()
{
    ipkdir=$(find /etc/disk -type d -name "ik-plugin-dir" -print | head -n 1)
    if [ "$ipkdir" ]; then
        if [ "$EXT_PLUGIN_IPK_DIR" = "/etc/mnt/plugins" ]; then
            mv /etc/mnt/plugins/*.ipk $ipkdir
        fi
        EXT_PLUGIN_IPK_DIR=$ipkdir
        sed -i "s|EXT_PLUGIN_IPK_DIR=.*|EXT_PLUGIN_IPK_DIR=$ipkdir|g"  /etc/mnt/plugins/configs/config.sh

        # if [ "$EXT_PLUGIN_CONFIG_DIR" = "/etc/mnt/plugins/configs" ]; then
        #     mv /etc/mnt/plugins/configs/* $ipkdir
        # fi
        # EXT_PLUGIN_CONFIG_DIR=$ipkdir
        # sed -i "s|EXT_PLUGIN_CONFIG_DIR=.*|EXT_PLUGIN_CONFIG_DIR=$ipkdir|g"  /etc/mnt/plugins/configs/config.sh
        return 0
    else
        EXT_PLUGIN_IPK_DIR=/etc/mnt/plugins
        sed -i "s|EXT_PLUGIN_IPK_DIR=.*|EXT_PLUGIN_IPK_DIR=/etc/mnt/plugins|g"  /etc/mnt/plugins/configs/config.sh
        # EXT_PLUGIN_CONFIG_DIR=/etc/mnt/plugins/configs
        # sed -i "s|EXT_PLUGIN_CONFIG_DIR=.*|EXT_PLUGIN_CONFIG_DIR=/etc/mnt/plugins/configs|g"  /etc/mnt/plugins/configs/config.sh
        return 1
    fi
}
