#!/bin/bash

function install () {
    log INFO "Install plugins"
    local jstmp="$work_dir/jstmp"
    mkdir "$jstmp"
    for file in usr/ikuai/www/static/js/*.js.gz; do
        output_file="$(basename "$file" .gz)"
        gunzip -c "$file" > "$jstmp/$output_file"
        docker_js=$(grep 'location.host+"/plugins/docker/' $jstmp/$output_file | wc -l)
        if [ $docker_js -gt 0 ]; then
            log INFO "Found plugin manager js $jstmp/$output_file"

            log INFO "Enable show plugins"
            sed -i 's/t.yunbindstatus=""!=i.code?2:1/t.yunbindstatus=2/' $jstmp/$output_file
            sed -i 's/dockerShow()})}/dockerShow();}/' $jstmp/$output_file
            sed -i 's/this.\$http.post(s.a.apiUrl,{func_name:"register",action:"show",param:{TYPE:"data,gwid"}}).then(function(e){var i=e.data.Data.data\[0\];//g' $jstmp/$output_file

            log INFO "Set name to alias"
            sed -i 's/this.dockertitle="docker"/this.dockertitle=t.alias/' $jstmp/$output_file
            sed -i 's/("vpn.openVpnClient.log")))]):t._e()/("vpn.openVpnClient.log")))]):i("h3",[t._v(t.dockertitle)])/' $jstmp/$output_file
            sed -i 's/e.name/e.alias/' $jstmp/$output_file

            log INFO "Add plugin name and title record"
            sed -i 's/sessionStorage.getItem("pluginMgt")){var e=sessionStorage.getItem("pluginMgt")/sessionStorage.getItem("pluginName")){var e=sessionStorage.getItem("pluginName"),n = sessionStorage.getItem("pluginTitle")/' $jstmp/$output_file
            sed -i 's/sessionStorage.removeItem("pluginMgt")/sessionStorage.removeItem("pluginName"), sessionStorage.removeItem("pluginTitle")/' $jstmp/$output_file
            sed -i 's/t.jumpDocker(e)/t.jumpDocker(e);sessionStorage.setItem("pluginName", e.name);sessionStorage.setItem("pluginTitle", e.alias);/' $jstmp/$output_file
            sed -i 's/iframesrc:i/iframesrc:i,alias:n/' $jstmp/$output_file

            log INFO "Add plugin assets path"
            sed -i 's|"/plugins/docker/"+e+".html"|"/plugins/"+e+"/index.html"|' $jstmp/$output_file
            sed -i 's|"/plugins/docker/"+t.dockerList\[i\].name+".png"|"/plugins/"+t.dockerList[i].name+"/logo.png"|' $jstmp/$output_file
            sed -i 's|"/plugins/docker/"+t.dockerList\[i\].name+".html"|"/plugins/"+t.dockerList[i].name+"/index.html"|' $jstmp/$output_file

            gzip -c $jstmp/$output_file > usr/ikuai/www/static/js/$output_file.gz
        fi
    done

    log INFO "Modify file upload size"
    sed -i 's/50\*/1024\*/g' usr/openresty/lua/lib/webman.lua

    log INFO "Replace plugin metadata file name"
    sed -i 's/$f.json/metadata.json/' usr/ikuai/script/plugins.sh

    local cpwd=$(pwd)

    cd usr/ikuai/www/static/css/
    ln -sf app.*.css.gz plugin.css.gz
    cd "$cpwd"

    log INFO "Move plugins menu to top"
    menu_file=usr/ikuai/www/json/menu.json
    plugin_management='{"label":"system-setting.plugin-management","icon": "nav1_ico7","func_name":"plugins","linkTo":"system-setting-plugin-management"}'
    jq 'map(if .children then (.children |= map(select(.label != "system-setting.plugin-management"))) else . end)' $menu_file > $work_dir/tempmenu.json
    jq "map(if .label == \"advanced.advanced\" then . , $plugin_management else . end)" $work_dir/tempmenu.json > $menu_file

    log INFO "Copy plugin assets"
    mkdir "$work_dir/www"
    cp -rfp "$script_dir"/www/* "$work_dir/www"
    find "$work_dir/www" -type f \( -name "*.js" -o -name "*.css" \) -exec gzip -9 {} \;
    cp -rfp "$work_dir"/www/* "usr/ikuai/www"

    log INFO "Install plugins"
    mkdir usr/ikuai/www/plugins
    for file in "$script_dir"/plugins/*/install.sh; do
        if [ ! -f "$file" ]; then
            continue
        fi
        cd "$cpwd"
        unset -f install 2>/dev/null
        unset -f plugin_path 2>/dev/null
        plugin_path=$(dirname "$file")
        . "$file"
        if declare -f install >/dev/null 2>&1; then
            log INFO "Running $file install"
            install
        else
            log ERROR "Not found install function in $file"
        fi
    done
}