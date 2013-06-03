#!/bin/bash

TRAPPER_FUNCNAME=()
TRAPPER_DEBUG=${TRAPPER_DEBUG:-0}
TRAPPER_USE_PREPOST=${TRAPPER_PRE_POST:-1}
TRAPPER_OVERRIDES=${TRAPPER_OVERRIDES:-1}
TRAPPER_INTERESTED_OVERRIDES=${TRAPPER_INTERESTED_OVERRIDES:-0}

declare -A TRAPPER_INTERESTED

set -o functrace
shopt -s extdebug

# Register an interest in being notified of a function being called.
# This is more of a pain than using _pre and _post functions, but
#
function interested() {
    # $1 - type (pre|post)
    # $2 - function interested in
    # $3 - function to call
    if [[ "${TRAPPER_INTERESTED[${1}_${2}]-}" = "" ]]; then
        TRAPPER_INTERESTED[${1}_${2}]=${3}
    else
        TRAPPER_INTERESTED[${1}_${2}]="${TRAPPER_INTERESTED[${1}_${2}]} ${3}"
    fi
    return 0
}

function trapper_log() {
    if [ ${TRAPPER_DEBUG} -eq 0 ]; then
        return 0
    fi

    echo "$@"
}


# This trap handler always gets used to be able to do decorators
#
# FIXME: fix up $? handling.
# FIXME: should we be able to override arguments from a _pre/_interest?
# FIXME: should $? on pre/post abort execution of the function?
#
function trapper_debug() {
    TRAPPER_ERROR=$?

    local funcno
    local argv_index
    local -a my_argv
    local interested_function
    local retval=0
    local ephemeral

    if [ ${#FUNCNAME[@]} -ne ${#TRAPPER_FUNCNAME[@]} ]; then
        # our function depth changed...
        if [ ${#FUNCNAME[@]} -gt ${#TRAPPER_FUNCNAME[@]} ]; then
            # entered a function - we can really only
            # enter one function at a time...
            TRAPPER_FUNCTION=${FUNCNAME[1]}

            # args are fairly easy.  trap function takes none,
            # so we gobble up the first BASH_ARGC[1] elements (in reverse order)...
            for ((argv_index=${BASH_ARGC[1]-1} - 1; argv_index >= 0; argv_index--)); do
                my_argv[${#my_argv[@]}]=${BASH_ARGV[${argv_index}]:-}
            done
            trapper_log " > Entering ${TRAPPER_FUNCTION} with \"${my_argv[@]:-}\""

            if [ ${TRAPPER_USE_PREPOST} -ne 0 ]; then
                # see if there is a _pre function defined...
                if $(type ${TRAPPER_FUNCTION}_pre 2>/dev/null | head -n1 | grep -q function); then
                    trapper_log " > _pre function defined"
                    eval ${TRAPPER_FUNCTION}_pre "${my_argv[@]:-}"
                    if [ ${TRAPPER_OVERRIDES} -ne 0 ]; then
                        retval=$?
                    fi
                    trapper_log " : going to return ${retval}"
                else
                    trapper_log " > _pre function not defined"
                fi
            fi

            for interested_function in ${TRAPPER_INTERESTED[pre_${TRAPPER_FUNCTION}]:-}; do
                trapper_log " > calling interested function: ${interested_function}"
                eval ${interested_function} "${my_argv[@]:-}"
                ephemeral=$?
                if [ ${TRAPPER_INTERESTED_OVERRIDES} -ne 0 ]; then
                    retval=$((ephemeral | $?))
                fi
            done
        else
            # exited a function
            for ((funcno=1; funcno <= ${#TRAPPER_FUNCNAME[@]} - ${#FUNCNAME[@]};funcno++)); do
                TRAPPER_FUNCTION=${TRAPPER_FUNCNAME[$funcno]}
                trapper_log " < Exiting ${TRAPPER_FUNCTION}"

                if [ ${TRAPPER_USE_PREPOST} -ne 0 ]; then
                    if $(type ${TRAPPER_FUNCTION}_post 2>/dev/null | head -n1 | grep -q function); then
                        trapper_log " < _post function defined"
                        eval ${TRAPPER_FUNCTION}_post
                    else
                        trapper_log " < _post function not defined"
                    fi
                fi

                for interested_function in ${TRAPPER_INTERESTED[post_${TRAPPER_FUNCTION}]:-}; do
                    trapper_log " < calling interested function: ${interested_function}"
                    eval ${interested_function} "${my_argv[@]:-}"
                done

            done
        fi
        TRAPPER_FUNCNAME=("${FUNCNAME[@]}")
    fi

    return $retval
}

trap trapper_debug DEBUG
