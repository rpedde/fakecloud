#!/bin/bash

set -u
set -e
shopt -s nullglob

# notifier
#
# Wait for tasks to be dropped in a task directory and execute them.
# This is the fundamental mechanics of the IPC system
#

declare -a pidlist=()

[ -e /etc/fakecloud/fakecloud.conf ] && source /etc/fakecloud/fakecloud.conf
if [ ! -e ${SHARE_DIR}/virt.sh ]; then
    echo "Set SHARE_DIR in /etc/fakecloud/fakecloud.conf"
    exit 1
fi

source ${SHARE_DIR}/virt.sh
init_vars

function datelog {
    local datetime=$(date "+%Y-%m-%d %H:%M:%S%z")
    echo ${datetime} $@
}

# walk through and delete all the completed jobs.
function clean_up_jobs {
    local job
    local fname

    for job in $(ls ${EVENT_DIR}/*job); do
        fname=$(basename ${job} .job)
        if [ -e ${EVENT_DIR}/${fname}.status ] && [ -e ${EVENT_DIR}/${fname}.complete ]; then
            rm -f ${EVENT_DIR}/${fname}.{status,complete,job,log}
        fi
    done
}

function dispatch_event {
    local event
    local file

    event=${1}
    file=${2}

    if [ "${file}" == "" ]; then
        datelog "Event: ${event}"
    else
        datelog "Event: ${event} on file ${file}"
    fi

    case ${event} in
        CREATE)
            if [[ $file = *.job ]]; then
                datelog "New job... starting job worker"
                source ${EVENT_DIR}/${file}
                init ${EVENT_DIR}/${file}
                dispatch_job &
            fi
            ;;
    esac
}

clean_up_jobs

# Wait in a loop for events to happen
datelog "Starting notifier on ${EVENT_DIR}"

while ( /bin/true ); do
    datelog "Starting wait..."
    line=$(inotifywait -e CREATE --format '%e %f' ${EVENT_DIR} 2> /dev/null)
    [ $? -ne 0 ] && exit 1

    datelog $line

    event=${line%% *}
    file=${line#* }

    dispatch_event "${event}" "${file}"
done
