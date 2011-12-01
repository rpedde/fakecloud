#!/bin/bash


# $1 - distrelease (ubuntu-natty, debian-squeeze, etc)
# $2 - disk size (in gb)

function init() {
    # set up globals, read from config file, potentially
    if [ "${USER-}" != "root" ]; then
	echo "Must be running as root (try sudo)."
	exit 1
    fi

    REAL_USER=${USER:-}
    [ ! -z "${SUDO_USER}" ] && REAL_USER=${SUDO_USER}

    REAL_HOMEDIR=${REAL_HOMEDIR:-/home/${REAL_USER}}
    [ -e ${REAL_HOMEDIR}/.fakecloudrc ] && . ${REAL_HOMEDIR}/.fakecloudrc

    BASE_DIR=${BASE_DIR:-/var/lib/spin}
    SHARE_DIR=${SHARE_DIR-$(dirname $0)}

    NBD_DEVICE=${NBD_DEVICE:-/dev/nbd2} # qemu-nbd is hacky as crap...
    PLUGIN_DIR=${PLUGIN_DIR:-${SHARE_DIR}/plugins}
    META_DIR=${META_DIR:-${SHARE_DIR}/meta}
    LIB_DIR=${LIB_DIR:-${SHARE_DIR}/lib}
    EXAMPLE_DIR=${EXAMPLE_DIR:-${SHARE_DIR}/examples}
    POSTINSTALL_DIR=${POSTINSTALL_DIR:-${SHARE_DIR}/post-install}

    # honor null
    EXTRA_PACKAGES=${EXTRA_PACKAGES-emacs23-nox,sudo}

    LOGFILE=$(mktemp /tmp/logfile-XXXXXXXXX.log)
    VIRT_TEMPLATE=${VIRT_TEMPLATE:-kvm}

    if [ -z "${SSH_KEY:-}" ]; then
	if [ ! -z "${SUDO_USER:-}" ]; then
	    SSH_KEY=/home/${SUDO_USER}/.ssh/id_*pub
	else
	    SSH_KEY=${HOME}/.ssh/id_[rd]sa.pub
	fi
    fi

    # fix up logging
    exec 3>&1
    exec >${LOGFILE}
    exec 2>&1

    set -x
    set -u

    log_debug "Initialized with logs to ${LOGFILE}"
    trap handle_error SIGINT SIGTERM ERR
    trap handle_exit EXIT
}

# handle terminating under error
function handle_error() {
    set +x
    trap - EXIT ERR SIGTERM SIGINT

    exec 1>&-
    exec 2>&-

    log "Exiting on error.  Logs are in ${LOGFILE}. Excerpt follows:\n\n"
    tail -n20 ${LOGFILE} >&3

    exit 1
}

# any global deinits that must happen
function handle_exit() {
    error=${?-$1}
    trap - EXIT ERR SIGTERM SIGINT
    rm ${LOGFILE}
    exit error
}

function log() {
    echo -e "$@" >&3
}

function log_debug {
    if [ "${DEBUG-}" != "" ]; then
	log "$@"
    else
	echo "$@"
    fi
}

function destroy_instance_by_name() {
    # $1 name

    local name=${1}

    [ -e "${BASE_DIR}/instances/${name}" ] || return 0

    set +e
    virsh destroy "${name}"
    virsh undefine "${name}"
    set -e

    # destroy the disk
    if [ -e "${BASE_DIR}/instances/${name}/${name}.vars" ]; then
	source "${BASE_DIR}/instances/${name}/${name}.vars"
	source "${LIB_DIR}/disk/default"
	source "${LIB_DIR}/disk/${DISK_FLAVOR}"
	destroy_instance_disk "${name}"
    fi

    rm -rf "${BASE_DIR}/instances/${name}"
}


function spin_instance() {
    # $1 name
    # $2 flavor
    # $3 dist-release

    local name=${1}
    local flavor=${2}
    local distrelease=${3}

    function spin_instance_cleanup() {
	log_debug "Cleaning up spin_instance()"

	if [ "${NOCLEAN-0}" -eq 1 ]; then
	    log_debug "Not cleaning up spun instances"
	else
	    virsh destroy ${name}
	    virsh undefine ${name}
	    [ -e "${BASE_DIR}/instances/${name}" ] && rm -rf "${BASE_DIR}/instances/${name}"
	fi
	return 1
    }

    maybe_make_default_flavors

    if [ -e "${BASE_DIR}/instances/${name}" ]; then
	log "Instance already exists."
	trap - ERR EXIT
	exit 1
    fi

    if [ ! -e ${BASE_DIR}/flavors/size/${flavor} ]; then
	log "No instance definition for flavor \"${flavor}\""
	trap - ERR EXIT
	exit 1
    fi

    trap "spin_instance_cleanup; return 1" ERR SIGINT SIGTERM

    log "Spinning instance of flavor \"${flavor}\""
    source ${BASE_DIR}/flavors/size/${flavor}

    [ -z "${NETWORK_FLAVOR:-}" ] && NETWORK_FLAVOR=$(brctl show | grep -v "bridge name" | cut -f1 | head -n1)

    if [ ! -e ${BASE_DIR}/flavors/network/${NETWORK_FLAVOR} ]; then
	BRIDGE=${BRIDGE:-br0}
    else
	source ${BASE_DIR}/flavors/network/${NETWORK_FLAVOR}
    fi

    FLAVOR+=([bridge]=${BRIDGE})

    make_instance_drive $distrelease ${FLAVOR[disk]} ${name}
    local disk_image=${BASE_DIR}/instances/${name}/${name}.disk

    FLAVOR+=([disk_image]=${disk_image})
    FLAVOR+=([name]=$name)

    # get the qemu disk type
    get_qemu_type
    FLAVOR+=([disk_type]=$_RETVAL)

    log "name:      ${FLAVOR[name]}"
    log "disk size: ${FLAVOR[disk]}G"
    log "disk type: ${FLAVOR[disk_type]}"
    log "memory:    ${FLAVOR[memory]}"
    log "vcpus:     ${FLAVOR[vcpu]}"
    log "disk:      ${FLAVOR[disk_image]}"
    log "bridge:    ${FLAVOR[bridge]}"

    # let's drop a descriptor file so we know what disk types, etc
    rm -f "${BASE_DIR}/instances/${name}/${name}.vars"
    for var in DISK_FLAVOR NETWORK_FLAVOR BRIDGE distrelease name flavor; do
	typeset -p ${var} >> "${BASE_DIR}/instances/${name}/${name}.vars"
    done

    # now, we have to generate the template xml...
    eval "echo \"$(< ${BASE_DIR}/flavors/template/${VIRT_TEMPLATE})\"" > ${BASE_DIR}/instances/${name}/${name}.xml

    log_debug "running plugins"

    virsh define ${BASE_DIR}/instances/${name}/${name}.xml

    run_plugins ${name} ${distrelease}

    log "Starting instance..."
    virsh start ${name}

    if [ "${POST_INSTALL-}" != "" ]; then
	log_debug "Waiting for instance spin-up..."
	# wait for instance to spin up, then run post_install
	count=0
	while [ ${count} -lt 10 ]; do
	    # wait for port 22
	    count=$((count + 1))
	    sleep 5
	    if (nc ${name}.local 22 -w 1 -q 0 < /dev/null ); then
		break;
	    fi
	done
	sleep 5

	log_debug "Instance spun... starting postinstall script (${POST_INSTALL})"

	# 22 is open (or we died)
	if [ -e ${POSTINSTALL_DIR}/${POST_INSTALL} ]; then
	    log "Running post-install script ${POST_INSTALL}..."
	    if ! ( ${POSTINSTALL_DIR}/${POST_INSTALL} ${name}.local ${distrelease} xx ); then
		log "Error..."
		handle_exit
	    else
		log "Success!"
	    fi
	fi
    fi
}

#
# run ordered plugins from the plugin directory
#
function run_plugins() {
    # $1 - name
    # $2 - distrelease

    function run_plugins_cleanup() {
	trap - ERR EXIT
	log_debug "Cleaning up run_plugins()"

	[ -e ${tmpdir}/mnt ] && umount ${tmpdir}/mnt
	qemu-nbd -d ${NBD_DEVICE}
	rm -rf ${tmpdir}
	return 1
    }
    trap 'run_plugins_cleanup; return 1' ERR SIGINT SIGTERM

    tmpdir=$(mktemp -d)
    mkdir -p ${tmpdir}/mnt

    modprobe nbd
    qemu-nbd -c $NBD_DEVICE ${BASE_DIR}/instances/${name}/${name}.disk
    sleep 2
    mount ${NBD_DEVICE}p1 ${tmpdir}/mnt

    for plugin in $(ls ${PLUGIN_DIR} | sort); do
	log_debug "Running plugin \"${plugin}\"..."
	if ! ( ${PLUGIN_DIR}/${plugin} "${1}" "${2}" "${tmpdir}/mnt" ); then
	    log_debug "Plugin \"${plugin}\": failure"
	else
	    log_debug "Plugin \"${plugin}\": success"
	fi
    done

    umount ${tmpdir}/mnt
    qemu-nbd -d $NBD_DEVICE

    # wait for qemu-nbd to settle
    sleep 2
}

# if there is a disk image already of this size, then
# qcow it, otherwise resize and qcow *that*
function make_instance_drive() {
    local distrelease=${1}
    local size=${2}
    local name=${3}

    DISK_FLAVOR=${DISK_FLAVOR-qcow}
    source ${LIB_DIR}/disk/default
    source ${LIB_DIR}/disk/${DISK_FLAVOR}

    make_bootable_drive ${distrelease} ${size} ${name}
}

function maybe_make_dist_image() {
    # $1 - distrelease (ubuntu-natty, etc)

    dist=${1%%-*}
    release=${1##*-}
    arch=amd64
    tmpdir=$(mktemp -d)

    trap "set +e; rm -rf ${tmpdir}; return 1" SIGINT SIGTERM ERR

    for l in ${LIB_DIR}/os/{default,$dist/default,$dist/$release}; do
	if [ -f $l ]; then
	    log_debug "Sourcing $l"
	    source $l
	fi
    done

    if [ ! -e ${BASE_DIR}/minibase ]; then
	mkdir -p ${BASE_DIR}/minibase
    fi

    log_debug "checking for dist image for ${1}"
    log_debug "Using: $(declare -f valid_image)"
    if ! validate_image ${1}; then
	log "No valid dist image yet.  Creating."
	log_debug "Using: $(declare -f make_dist_image)"
	make_dist_image ${1}
    fi
}

function maybe_make_default_flavors() {
    # check to see if there is a flavors dir, and populate
    # it if not

    if [ ! -e ${BASE_DIR}/flavors ]; then
	mkdir -p ${BASE_DIR}/flavors
	rsync -av ${EXAMPLE_DIR}/flavors/ ${BASE_DIR}/flavors/

        [ -e ${BASE_DIR}/flavors/network ] || mkdir ${BASE_DIR}/flavors/network
	#default network flavor will handle this case in future
	for bridge in $(brctl show | grep -v "bridge name" | cut -f1); do
	    cat > ${BASE_DIR}/flavors/network/${bridge} <<EOF
BRIDGE=${bridge}
EOF
	done

    fi
}