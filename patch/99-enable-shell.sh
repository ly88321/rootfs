#!/bin/bash

function install () {
    log INFO "Add e join shell"
    sed -i '/\t\tv|V) \/etc\/setup\/setup.one_stick_router ;;/c\\t\tv|V) /etc/setup/setup.one_stick_router ;;\n\t\te|E)\n\t\t\tstty $STTY_DEFAULT\n\t\t\tclear\n\t\t\tconsole_banner\n\t\t\tash --login\n\t\t;;' etc/setup/rc.console
}
