#!/bin/bash 

install()
{
	log INFO "Install store"

    local PLUGIN_NAME="$(jq -r '.name' $plugin_path/html/metadata.json)"
    mkdir "usr/ikuai/www/plugins/$PLUGIN_NAME"
    cp -rfp "$plugin_path"/html/* "usr/ikuai/www/plugins/$PLUGIN_NAME"
	
    cp "$plugin_path"/script/service.sh usr/ikuai/script/plugin_pgstore.sh
	chmod +x usr/ikuai/script/plugin_pgstore.sh

	cd usr/ikuai/function
    ln -sf ../script/plugin_pgstore.sh plugin_pgstore
}
