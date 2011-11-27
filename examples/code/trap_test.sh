#!/bin/bash

function global_cleanup() {
    local status=$?
    echo "in global_cleanup: status=${status}"
    trap - ERR EXIT
    echo "Assuming error exit, doing error cleanup"
}

function global_exit() {
    trap - ERR EXIT

    echo "Assuming successful exit, doing successful error cleanup"
}

function init() {
    set -u
    set -x
    trap global_cleanup ERR EXIT
}

function f1() {
    local status
    function f1_cleanup() {
	status=$?
	echo "in f1_cleanup: status=${status}"
	return ${status}
    }
    trap "f1_cleanup; return ${status}" ERR

    echo In f1, calling f2
    f2
    echo In f1, after calling f2
}

function f2() {
    local status
    function f2_cleanup() {
	status=$?
	echo "in f2_cleanup: status=${status}"
	return ${status}
    }
    trap "f2_cleanup; return ${status}" ERR

    echo "in f2, before error"

    some_command_that_doesnt_exist

    echo "in f2, after error"
}

trap global_cleanup ERR SIGTERM SIGINT
trap global_exit EXIT

f1

