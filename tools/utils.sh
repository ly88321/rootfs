#!/bin/bash

log() {
    level="$1"; shift
    case "$level" in
        INFO)  color="\033[0;32m" ;; # green
        WARN)  color="\033[0;33m" ;; # yellow
        ERROR) color="\033[0;31m" ;; # red
        *)     color="\033[0m"   ;; # reset
    esac
    reset="\033[0m"
    if [ "$level" = "ERROR" ]; then
        echo -e "[$(date '+%F %T')] ${color}[$level]${reset} $*" >&2
    else
        echo -e "[$(date '+%F %T')] ${color}[$level]${reset} $*"
    fi
}

get_conf() {
    local key="$1"
    local file="$2"
    awk -F= -v k="$key" '$1==k{print $2}' "$file"
}

set_conf() {
    local key="$1"
    local value="$2"
    local file="$3"
    local quote="${4:-auto}"

    case "$quote" in
        always) value="\"$value\"" ;;
        auto)
            [[ "$value" =~ [[:space:]] || "$value" =~ [\"\$] ]] && value="\"$value\""
            ;;
        none) ;;
        *) echo "Invalid quote option: $quote"; return 1 ;;
    esac

    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=$value|" "$file"
    else
        echo "$key=$value" >> "$file"
    fi
}

umount_retry() {
    local target="$1"
    local max_retry=5
    local i

    for i in $(seq 1 $max_retry); do
        umount "$target" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log INFO "Umount success on try $i"
            return 0
        fi
        log WARN "Umount failed on try $i, retrying..."
        sleep 1
    done

    LOG ERROR "Umount failed after $max_retry attempts"
    return 1
}
