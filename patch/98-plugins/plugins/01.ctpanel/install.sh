#!/bin/bash 

install()
{
	log INFO "Install controll panel"
    local PLUGIN_NAME="$(jq -r '.name' $plugin_path/html/metadata.json)"
    mkdir "usr/ikuai/www/plugins/$PLUGIN_NAME"
    cp -rfp "$plugin_path"/html/* "usr/ikuai/www/plugins/$PLUGIN_NAME"
	
    cp "$plugin_path"/script/service.sh usr/ikuai/script/plugin_ctpanel.sh
    cp "$plugin_path"/script/chrootmgt.sh usr/bin/chrootmgt

    chmod +x usr/ikuai/script/plugin_ctpanel.sh
    chmod +x usr/bin/chrootmgt

    cp "$plugin_path"/script/init_plugins.sh usr/ikuai/script/init_plugins.sh
    chmod +x usr/ikuai/script/init_plugins.sh

    local cpwd=$(pwd)

	cd usr/ikuai/function
    ln -sf ../script/plugin_ctpanel.sh plugin_ctpanel
    cd "$cpwd"

    log INFO "Install chroot service"
    sed -i '/^boot()$/,/^}/ { /^[[:space:]]*return$/ i\
    chrootmgt build_chroot
}' usr/ikuai/script/plugins.sh

    log INFO "Install plugin init service"
    sed -i '/^boot()$/,/^}/ { /^[[:space:]]*return$/ i\
    $IK_DIR_SCRIPT/init_plugins.sh init
}' usr/ikuai/script/plugins.sh

    log INFO "Install plugin boot service"
    sed -i '/factory.sh/a\
	boot_load_async  init_plugins.sh' usr/ikuai/script/rc
}
