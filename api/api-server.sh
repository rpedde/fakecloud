#!/bin/bash

MAX_BUFFER=1024
DEBUG=1

declare -a request
declare -A headers
declare -A request_args
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
    echo "Content-type: ${2}" >&3
    echo -e "Connection: close\n" >&3
}

function continue_response() {
    echo ${1} >&3
}

function end_response() {
    exit 0
}

function response() {
    # $1 - error & message ("200 OK")
    # $2 - content-type ("text/plain")
    # $3 - body (string)
    start_response ${1} ${2}
    continue_reponse ${3}
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
    exit 1
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

	header_value=${line##*:}
	header_name=${line%%:*}

	headers[${header_name,,}]=${header_value}
    fi
done

body=""

# see if there is a content-length
if [ ! -z ${headers[content-length]:-} ]; then
    max_read=max ${headers[content-length]} MAX_BUFFER
    read -n ${max_read} body
fi

# at this point, we have the request, and perhaps the body
start_response "200 OK" "text/plain"
continue_response "${request_path} => ${request_query}"
continue_response "Got ${#request_args[@]} args"
for arg in ${!request_args[@]}; do
    continue_response "${arg} => ${request_args[${arg}]}"
done
end_response


