#!/bin/bash /etc/ikcommon
PLUGIN_NAME="01.ctpanel"
. /etc/release
. /etc/mnt/plugins/configs/config.sh

show()
{
    Show __json_result__
}

__check_param()
{
    check_varl \
        'id  UUID match "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"'
}

__show_data()
{
    local sources=$(cat "$RMT_PLUGIN_REPOS_DIR/repos.json")
	
    json_append __json_result__ sources:json
    return 0
}

add()
{
    check_varl \
        'name  Name != ""' \
        'url  Url != ""' || exit 1

    id=$(cat /proc/sys/kernel/random/uuid)

    repos=$(cat "$RMT_PLUGIN_REPOS_DIR/repos.json")
    repos="${repos%]}"
    [ "$repos" != "[" ] && repos="$repos,"

    repo_info=''
    enabled='yes'
    json_append repo_info id:str
    json_append repo_info name:str
    json_append repo_info url:str
    json_append repo_info enabled:str

    echo "${repos}${repo_info}]" > "$RMT_PLUGIN_REPOS_DIR/repos.json"
}

edit()
{
    __check_param || exit 1
    check_varl \
        'name  Name != ""' \
        'url  Url != ""' || exit 1

    local edit_id="$id"
    local edit_name="$name"
    local edit_url="$url"

    json_decode_file repo_info $RMT_PLUGIN_REPOS_DIR/repos.json

    repos=''
    i=1
    while true; do
        eval id=\$repo_info_${i}_id
        eval name=\$repo_info_${i}_name
        eval url=\$repo_info_${i}_url
        eval enabled=\$repo_info_${i}_enabled
        [ -z "$id" ] && break

        repo_info=''

        if [ "$id" = "$edit_id" ]; then
            name="$edit_name"
            url="$edit_url"
        fi

        json_append repo_info id:str
        json_append repo_info name:str
        json_append repo_info url:str
        json_append repo_info enabled:str

        repos+="${repos:+,}$repo_info"
        i=$((i+1))
    done
    repos="[$repos]"

    echo "$repos" > $RMT_PLUGIN_REPOS_DIR/repos.json
}

del()
{
    __check_param || exit 1

    local del_id="$id"

    json_decode_file repo_info $RMT_PLUGIN_REPOS_DIR/repos.json

    repos=''
    i=1
    while true; do
        eval id=\$repo_info_${i}_id
        eval name=\$repo_info_${i}_name
        eval url=\$repo_info_${i}_url
        eval enabled=\$repo_info_${i}_enabled
        [ -z "$id" ] && break

        repo_info=''

        if [ "$id" = "$del_id" ]; then
            rm -rf /etc/mnt/plugins/configs/img/$id
            rm -f $RMT_PLUGIN_REPOS_DIR/$id/release
            rm -f $RMT_PLUGIN_REPOS_DIR/$id/plugins.json

            i=$((i+1))
            continue
        fi

        json_append repo_info id:str
        json_append repo_info name:str
        json_append repo_info url:str
        json_append repo_info enabled:str

        repos+="${repos:+,}$repo_info"
        i=$((i+1))
    done
    repos="[$repos]"

    echo "$repos" > $RMT_PLUGIN_REPOS_DIR/repos.json
}

enable()
{
    __check_param || exit 1

    local enable_id="$id"

    json_decode_file repo_info $RMT_PLUGIN_REPOS_DIR/repos.json

    repos=''
    i=1
    while true; do
        eval id=\$repo_info_${i}_id
        eval name=\$repo_info_${i}_name
        eval url=\$repo_info_${i}_url
        eval enabled=\$repo_info_${i}_enabled
        [ -z "$id" ] && break

        repo_info=''

        if [ "$id" = "$enable_id" ]; then
            enabled='yes'
        fi

        json_append repo_info id:str
        json_append repo_info name:str
        json_append repo_info url:str
        json_append repo_info enabled:str

        repos+="${repos:+,}$repo_info"
        i=$((i+1))
    done
    repos="[$repos]"

    echo "$repos" > $RMT_PLUGIN_REPOS_DIR/repos.json
}

disable()
{
    __check_param || exit 1

    local disable_id="$id"

    json_decode_file repo_info $RMT_PLUGIN_REPOS_DIR/repos.json

    repos=''
    i=1
    while true; do
        eval id=\$repo_info_${i}_id
        eval name=\$repo_info_${i}_name
        eval url=\$repo_info_${i}_url
        eval enabled=\$repo_info_${i}_enabled
        [ -z "$id" ] && break

        repo_info=''

        if [ "$id" = "$disable_id" ]; then
            enabled='no'
        fi

        json_append repo_info id:str
        json_append repo_info name:str
        json_append repo_info url:str
        json_append repo_info enabled:str

        repos+="${repos:+,}$repo_info"
        i=$((i+1))
    done
    repos="[$repos]"

    echo "$repos" > $RMT_PLUGIN_REPOS_DIR/repos.json
}
