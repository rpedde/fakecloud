#!/bin/bash

[ -e /etc/fakecloud/api.conf ] && source /etc/fakecloud/api.conf

MAX_BUFFER=1024
DEBUG=1
BASE_DIR=${BASE_DIR-$(dirname $0)/rackspace-1.0}
TOKEN_DIR=${TOKEN_DIR-/var/cache/tokens}
MAP_DIR=${MAP_DIR-/tmp/fakecloud-api}
SHARE_DIR=${SHARE_DIR-$(dirname $0)/..}
LIB_DIR=${LIB_DIR:-${SHARE_DIR}/lib}
META_DIR=${META_DIR:-${SHARE_DIR}/meta}

declare -a request
declare -A request_headers
declare -A request_args
declare -A response_headers
declare -a post_info
declare body
declare request_method
declare request_path
declare request_query

declare -A SM_CURRENT_BY_KEY
declare -A SM_CURRENT_BY_VALUE

LOGFILE=$(mktemp)
exec 3>&1
exec >${LOGFILE}
exec 2>&1

set -u
set -x
shopt -q -s extglob

response_headers=(
    [connection]=close
    [content-type]="text/plain"
)

function max() {
    if [ ${1} -gt ${2} ]; then
	return ${1}
    fi
    return ${2}
}

function start_response() {
    # $1 - error & message ("200 OK")
    echo "HTTP/1.0 ${1}" >&3

    # jet out the headers
    for header in ${!response_headers[@]}; do
	echo "${header}: ${response_headers[${header}]}" >&3
    done
    echo >&3
}

function continue_response() {
    echo "${@}" >&3
}

function end_response() {
    exit 0
}

function response() {
    # $1 - error & message ("200 OK")
    # $2 - content-type ("text/plain")
    # $3 - body (string)
    start_response "${1}" "${2}"
    shift
    shift
    if [[ "$@" != "" ]]; then
	continue_response "$@"
    fi
    end_response
}

function error_handler() {
    set +x

    if [ ${DEBUG:-0} -eq 1 ]; then
	# make it easier to see errors in browsers that misguidedly
	# try to show "friendly" error pages
	echo "HTTP/1.0 200 OK" >&3
    else
	echo "HTTP/1.0 500 OK" >&3
    fi

    echo "Content-Type: text/plain" >&3
    echo -e "Connection: close\n\n" >&3

    if [ ${DEBUG:-0} -eq 1 ]; then
	echo -e "You are seeing this because DEBUG is turned on.\n\n" >&3
	cat ${LOGFILE} >&3
    else
    	echo "Internal Error.  Sorry!" >&3
    fi
    exit 0
}

function exit_handler() {
    if [ $? -ne 0 ]; then
	error_handler
    fi

    set +x
    rm -f ${LOGFILE}
    trap - EXIT ERR SIGTERM SIGINT
    exec 1>&-
    exec 2>&-
    exec 3>&-
    exit 0
}

# static map functions.  Terribly inefficient
function sm_lookup_by_key() {
    # $1 - descriptor
    # $2 - int to return string for

    local descriptor=${1}
    local key=${2}

    sm_load ${descriptor}

    # if we don't have a key match, return nothing
    _RETVAL=${SM_CURRENT_BY_KEY[${key}]-UNKNOWN}
}

function sm_lookup_by_value() {
    # $1 - descriptor
    # $2 - string to return int for

    local descriptor=${1}
    local value=${2}
    local key


    sm_load ${descriptor}

    # if we don't have a value match, assign it and save
    if [ "${SM_CURRENT_BY_VALUE[${value}]-}" == "" ]; then
	key=${SM_CURRENT_MAX}
	SM_CURRENT_MAX=$(( SM_CURRENT_MAX + 1 ))
	SM_CURRENT_BY_KEY[${key}]=${value}
	SM_CURRENT_BY_VALUE[${value}]=${key}
	sm_save
    fi

    _RETVAL=${SM_CURRENT_BY_VALUE[${value}]}
}

function sm_save() {
    local tmpfile=${MAP_DIR}/${SM_CURRENT_DESCRIPTOR}-new.conf
    local mapfile=${MAP_DIR}/${SM_CURRENT_DESCRIPTOR}.conf
    local key

    mkdir -p ${MAP_DIR}

    rm ${tmpfile}

    for key in ${!SM_CURRENT_BY_KEY[@]}; do
	echo "${key}:${SM_CURRENT_BY_KEY[${key}]}" >> ${tmpfile}
    done

    mv ${tmpfile} ${mapfile}
}

function sm_load() {
    # $1 - descriptor (images/instances, etc)
    local descriptor=$1
    local key
    local value
    local line

    # load a key/value table into well-known globals
    if [ "${SM_CURRENT_DESCRIPTOR-}" == "${descriptor}" ]; then
	return 0
    fi

    # otherwise, load the table
    SM_CURRENT_MAX=1
    SM_CURRENT_DESCRIPTOR=${descriptor}
    SM_CURRENT_BY_KEY=()
    SM_CURRENT_BY_VALUE=()

    if [ -e ${MAP_DIR}/${descriptor}.conf ]; then
	while read line; do
	    key=${line%:*}
	    value=${line##*:}

	    SM_CURRENT_BY_KEY[${key}]=${value}
	    SM_CURRENT_BY_VALUE[${value}]=${key}

	    if (( key > SM_CURRENT_MAX )); then
		SM_CURRENT_MAX=${key}
	    fi
	done < <(cat ${MAP_DIR}/${descriptor}.conf)
	SM_CURRENT_MAX=$(( SM_CURRENT_MAX + 1 ))
    fi
}


trap error_handler ERR SIGINT SIGTERM
trap exit_handler EXIT

# read headers
while read line; do
    if [ ${#request[@]} -eq 0 ]; then
	request=($line)

	if [ ${#request[@]} -ne 3 ]; then
	    echo ${request}
	    error_handler
	fi

	request_method=${request[0]}
	full_path=${request[1]}
	request_path=${full_path%%\?*}
	request_query=""

	# FIXME: totally unsanitary
	request_path=$(echo -e "$(echo "${request_path}" | sed 'y/+/ /; s/%/\\x/g')")
	if [[ ${full_path} =~ "?" ]]; then
	    request_query=${full_path##*\?}
	fi

	echo "$(date "+%Y-%m-%d %H:%M:%S") ${request_path}" >> /var/log/api-server.log
	declare -a kvpairs=()

	if [ ${#request_query} -gt 0 ]; then
	    kvpairs=(${request_query//&/ })
	    for pair in "${kvpairs[@]}"; do
		key=${pair%%=*}
		value=${pair##*=}
	        # needs urldecode
		request_args[${key}]=${value}
	    done
	fi
    else
	if [ "${line}" == "" ] || [ "${line}" == $'\r' ]; then
	    break;
	fi

	header_value=${line#*:}
	header_name=${line%%:*}

	header_value="${header_value#+([[:space:]])}"
	header_value="${header_value%+([$'\r'$'\n'])}"
	request_headers[${header_name,,}]="${header_value}"
    fi
done

body=""

# see if there is a content-length
if [ ! -z ${request_headers[content-length]:-} ]; then
    max_read=max ${request_headers[content-length]} MAX_BUFFER
    read -n ${max_read} body
fi

# at this point, we have the request, and perhaps the body
BASE_DIR=$(readlink -f "${BASE_DIR}")
if ( readlink -f "${BASE_DIR}/${request_path}"); then
    target_path=$(readlink -f "${BASE_DIR}/${request_path}")
else
    response "404 Not Found" "text/plain" "Bad Path"
    exit 1
fi

d=${target_path}
post_info=()

while ( /bin/true ); do
    if (! echo "${d}" | grep -q "^${BASE_DIR}"); then
	response "400 Bad Request" "text/plain" "Bad Path"
	exit 1
    fi

    if [ -f ${d} ]; then
	source ${d}
	break;
    elif [ -f ${d}/default ]; then
	source ${d}/default
	break;
    else
	post_info[${#post_info[@]}]=$(basename ${d})
	d=$(dirname ${d})
    fi
done

if $(type "handle_request" 2>/dev/null | head -n1 | grep -q function); then
    handle_request
    if [ $? -ne 0 ]; then
	response "500 Internal Server Error" "text/plain" "dispatch failed"
    fi

    exit 0
fi


response "404 Not Found" "text/plain" "Resource not found"

