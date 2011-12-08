#!/bin/bash

MAX_BUFFER=1024
DEBUG=1
BASE_DIR=${BASE_DIR:-$(dirname $0)/rackspace-1.0}
TOKEN_DIR=/var/cache/tokens

declare -a request
declare -A request_headers
declare -A request_args
declare -A response_headers
declare body
declare request_method
declare request_path
declare request_query

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
    # $2 - content-type ("text/plain")
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
BASE_DIR=$(realpath "${BASE_DIR}")
if [ ! $(realpath "${BASE_DIR}/${request_path}") ]; then
    response "404 Not Found" "text/plain" "Cannot find resource"
    exit 1
fi

target_path=$(realpath "${BASE_DIR}/${request_path}")

if (! echo "${target_path}" | grep -q "^${BASE_DIR}"); then
    response "400 Bad Request" "text/plain" "$(echo ${target_path} | hexdump -C)"
    exit 1
fi

if [ -e ${target_path} ]; then
    if [ -f ${target_path} ]; then
	source ${target_path}
    elif [ -d ${target_path} ]; then
	if [ -e ${target_path}/default ]; then
	    source ${target_path}/default
	else
	    response "404 Not Found" "text/plain" "Bad Path"
	fi
    fi

    if $(type "handle_request" 2>/dev/null | head -n1 | grep -q function); then
	handle_request
    fi

    if [ $? -ne 0 ]; then
	response "500 Internal Server Error" "text/plain" "dispatch failed"
    fi

    exit 0
fi

response "404 Not Found" "text/plain" "Resource not found"


