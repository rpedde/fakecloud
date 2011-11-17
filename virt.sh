#!/bin/bash


# $1 - distrelease (ubuntu-natty, debian-squeeze, etc)
# $2 - disk size (in gb)

function init() {
    # set up globals, read from config file, potentially
    if [ "${USER-}" != "root" ]; then
	echo "Must be running as root (try sudo)."
	exit 1
    fi

    REAL_USER=${USER-}
    if [ "${SUDO_USER-}" != "" ]; then
	REAL_USER=${SUDO_USER}
    fi

    REAL_HOMEDIR=${REAL_HOMEDIR-/home/${REAL_USER}}
    [ -e ${REAL_HOMEDIR}/.fakecloudrc ] && . ${REAL_HOMEDIR}/.fakecloudrc

    BASE_DIR=${BASE_DIR-/var/lib/spin}
    NBD_DEVICE=${NBD_DEVICE-/dev/nbd2} # qemu-nbd is hacky as crap...
    PLUGIN_DIR=${PLUGIN_DIR-$(dirname $0)/plugins}
    LIB_DIR=${LIB_DIR-$(dirname $0)/lib}
    EXAMPLE_DIR=${EXAMPLE_DIR-$(dirname $0)/examples}
    POSTINSTALL_DIR=${POSTINSTALL_DIR-$(dirname $0)/post-install}

    EXTRA_PACKAGES=${EXTRA_PACKAGES-emacs23-nox,sudo}

    LOGFILE=$(mktemp /tmp/logfile-XXXXXXXXX.log)
    VIRT_TEMPLATE=${VIRT_TEMPLATE-kvm}

    if [ "${SSH_KEY-}" == "" ]; then
	if [ "${SUDO_USER-}" != "" ]; then
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
    set -e
    set -u

#    log "Initialized with logs to ${LOGFILE}"
    trap error_exit SIGINT SIGTERM ERR EXIT
}


function deinit() {
    trap - SIGINT SIGTERM ERR EXIT
    rm ${LOGFILE}
}

# any global deinits that must happen
function error_exit() {
    set +x
    log "Exiting on error.  Logs are in ${LOGFILE}. Excerpt follows:\n\n"
    trap - EXIT
    tail -n20 ${LOGFILE} >&3
    exec 1>&-
    exec 2>&-
    exit 1
}

function log() {
    echo -e "$@" >&3
}

function log_debug {
    if [ "${DEBUG-}" != "" ]; then
	log "$@"
    fi
}

function destroy_instance_by_name() {
    # $1 name

    [ -e "${BASE_DIR}/instances/${1}" ] || return 0

    set +e
    virsh destroy "${1}"
    virsh undefine "${1}"
    set -e

    rm -rf "${BASE_DIR}/instances/${1}"
}


function spin_instance() {
    # $1 name
    # $2 flavor
    # $3 dist-release

    name=${1}
    flavor=${2}
    distrelease=${3}

    maybe_make_default_flavors

    if [ ! -e ${BASE_DIR}/flavors/size/${flavor} ]; then
	log "No instance definition for flavor \"${flavor}\""
	trap - ERR EXIT
	exit 1
    fi

    log "Spinning instance of flavor \"${flavor}\""
    . ${BASE_DIR}/flavors/size/${flavor}

    if [ "${NETWORK_FLAVOR-}" == "" ]; then
	NETWORK_FLAVOR=$(brctl show | grep -v "bridge name" | cut -f1 | head -n1)
    fi

    if [ ! -e ${BASE_DIR}/flavors/network/${NETWORK_FLAVOR} ]; then
	BRIDGE=${BRIDGE-br0}
    else
	. ${BASE_DIR}/flavors/network/${NETWORK_FLAVOR}
    fi

    FLAVOR+=([bridge]=${BRIDGE})

    make_instance_drive $distrelease ${FLAVOR[disk]} ${name}
    base_disk=${BASE_DIR}/base/${distrelease}-${FLAVOR[disk]}.qcow2
    overlay=${BASE_DIR}/instances/${name}/${name}.qcow2

    FLAVOR+=([overlay]=${overlay})
    FLAVOR+=([base_disk]=${base_disk})
    FLAVOR+=([name]=$name)

    log "name:      ${FLAVOR[name]}"
    log "disk size: ${FLAVOR[disk]}G"
    log "memory:    ${FLAVOR[memory]}"
    log "vcpus:     ${FLAVOR[vcpu]}"
    log "disk:      ${FLAVOR[overlay]}"
    log "bridge:    ${FLAVOR[bridge]}"

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
		error_exit
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

    tmpdir=$(mktemp -d)
    mkdir -p ${tmpdir}/mnt

    modprobe nbd
    qemu-nbd -c $NBD_DEVICE ${BASE_DIR}/instances/${name}/${name}.qcow2
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
}


# see if there is a disk image already of this size, if so
# qcow it, otherwise make a new one and qcow *that*
#
function make_instance_drive() {
    # $1 - dist-release
    # $2 - size in Gb
    # $3 - name

    if [ ! -e ${BASE_DIR}/instances ]; then
	mkdir -p ${BASE_DIR}/instances
    fi

    mkdir -p "${BASE_DIR}/instances/${3}"

    if [ -e "${BASE_DIR}/instances/${3}/${3}.qcow2" ]; then
	log "Instance already exists... choose another name"
	trap deinit ERR EXIT
	exit 1
    fi

    expand_dist_to_sized_base $1 $2

    qemu-img create -f qcow2 -o backing_file=${BASE_DIR}/base/${1}-${2}.qcow2 "${BASE_DIR}/instances/${3}/${3}.qcow2"
}

function expand_dist_to_sized_base() {
    # $1 - dist-release
    # $2 - size in Gb
    if [ ! -e ${BASE_DIR}/base ]; then
	mkdir -p ${BASE_DIR}/base
    fi

    dist=${1%%-*}
    release=${1##*-}
    arch=amd64

    basename=${1}-${2}
    basepath=${BASE_DIR}/base/${basename}.qcow2

    maybe_make_dist_image $1

    if [ -e ${basepath} ]; then
	return 0
    fi

    log "Creating qcow2 image of ${1} (size: ${2}G)"
    # otherwise, make the sized base...
    # mountdir=$(mktemp -d)

    # trap "deinit; set +e; umount ${mountdir}; qemu-nbd -d $NBD_DEVICE; rm ${basepath}; rm -rf ${mountdir}; error_exit" SIGINT SIGTERM ERR

    # log_debug "Creating ${2}G copy of ${1}"
    # qemu-img create -f qcow2 -o preallocation=metadata ${basepath} ${2}G

    # log_debug "Copying base image"
    # modprobe nbd
    # qemu-nbd -c $NBD_DEVICE ${basepath}
    # sleep 5
    # mke2fs -j $NBD_DEVICE
    # mount $NBD_DEVICE ${mountdir}
    # tar -xvzf ${BASE_DIR}/minibase/${1}.tar.gz -C ${mountdir}
    # umount ${mountdir}
    # qemu-nbd -d $NBD_DEVICE

    # this is kinda hokey, but we'll make a full-disk image
    # strictly with loopback so we can avoid having to use
    # qemu-nbd

    working=$(mktemp -d)

    function local_cleanup() {
	trap - SIGINT SIGTERM ERR EXIT
	set +e

	umount ${working}/mnt/dev
	umount ${working}/mnt
	[ "${part_loop-}" != "" ] && losetup -d ${part_loop}
	[ "${base_loop-}" != "" ] && kpartx -d ${base_loop}
	[ "${base_loop-}" != "" ] && losetup -d ${base_loop}

	rm -rf ${working}
	echo ${working}
	error_exit
    }

    trap local_cleanup SIGINT SIGTERM ERR EXIT

    log_debug "Creating raw image..."
    dd if=/dev/zero of=${working}/raw.img bs=1 count=0 seek=${2}G
    base_loop=$(losetup -vf ${working}/raw.img | awk '{ print $NF }')
    loop_basename=$(basename ${base_loop})
    log_debug "Partitioning..."
    parted ${base_loop} mklabel msdos mkpart primary 1m 100%
    kpartx -a ${base_loop}
    log_debug "Formatting..."
    mke2fs -j /dev/mapper/${loop_basename}p1

    # reloop to make grub2 work
    part_loop=$(losetup -vf /dev/mapper/${loop_basename}p1 | awk '{ print $NF }')
    mkdir ${working}/mnt
    mount ${part_loop} ${working}/mnt

    # extract the debootstrap
    log_debug "Extracting..."
    tar -xvzf ${BASE_DIR}/minibase/${1}.tar.gz -C ${working}/mnt
    mkdir -p ${working}/mnt/boot

    # FIXME: debian specific
    log_debug "Installing kernel..."
    package=linux-image-virtual
    grub_package=grub-pc

    if [ "${dist}" == "debian" ]; then
	package=linux-image-${arch}
	grub_package="grub2 grub-common"
    fi

    if [ "${EXTRA_PACKAGES-}" != "" ]; then
	packages=${EXTRA_PACKAGES//,/ }
	log_debug "Installing extra packages..."
	chroot ${working}/mnt /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install ${packages} -y --force-yes"
    fi

    chroot ${working}/mnt /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install ${grub_package} ${package} -y --force-yes"

    log_debug "Grubbing..."
    mkdir -p ${working}/mnt/boot/grub
    cat > ${working}/mnt/boot/grub/device.map <<EOF
(hd0) ${base_loop}
(hd0,1) ${part_loop}
EOF
    mount --bind /dev ${working}/mnt/dev
    chroot ${working}/mnt /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg

    chroot ${working}/mnt /usr/sbin/grub-install --no-floppy --grub-mkdevicemap=/boot/grub/device.map --root-directory=/ ${base_loop}

    # turn off ubuntu ridiculousness
    if [ -e ${working}/mnt/boot/grub/grub.cfg ]; then
	log_debug "Unfscking ubuntu-style boot options..."
	chmod 600 ${working}/mnt/boot/grub/grub.cfg
	sed -i ${working}/mnt/boot/grub/grub.cfg -e 's/quiet/nomodeset vga=0/'
    fi

    umount ${working}/mnt/dev
    umount ${working}/mnt
    losetup -d ${part_loop}
    sleep 1
    kpartx -d ${base_loop}
    losetup -d ${base_loop}

    log "Converting image to qcow2 compressed image"
    qemu-img convert -f raw -O qcow2 -o preallocation=metadata ${working}/raw.img ${BASE_DIR}/base/${basename}.qcow2

    rm -rf ${working}

    trap error_exit SIGINT SIGTERM ERR EXIT
}


function maybe_make_dist_image() {
    # $1 - distrelease (ubuntu-natty, etc)

    log_debug "checking for dist image for ${1}"

    dist=${1%%-*}
    release=${1##*-}
    arch=amd64

    if [ ! -e ${BASE_DIR}/minibase ]; then
	mkdir -p ${BASE_DIR}/minibase
    fi

    image_name=${BASE_DIR}/minibase/${1}.tar.gz

    if [ -e ${image_name} ]; then
	log_debug "Image exists..."
	return 0
    fi

    tmpdir=$(mktemp -d)

    trap "deinit; set +e; rm -rf ${tmpdir}; error_exit" SIGINT SIGTERM ERR

    for l in ${LIB_DIR}/os/{default,$dist,$release}; do
	log_debug $l
	if [ -f $l ]; then
	    log_debug "Sourcing $l"
	    source $l
	fi
    done
    log_debug "Calling make_dist_image: $(declare -f make_dist_image)"
    make_dist_image $*

#     log_debug "Creating base image"
#     mkdir ${tmpdir}/mountpoint

#     mirror="http://mirror.rackspace.com"
#     if [ "${dist}" == "debian" ]; then
# 	mirror="http://ftp.us.debian.org"
#     fi

#     log "debootstrapping ${1}"

#     case ${dist} in
# 	debian|ubuntu)
# 	    debootstrap --include=openssh-server,avahi-daemon,libnss-mdns,sudo ${release} \
# 		${tmpdir}/mountpoint ${mirror}/${dist}
# 	    ;;
# 	*)
# 	    log "Don't know how to build ${1}"
# 	    exit 1
#     esac

#     # throw in ssh keys
#     if [ "${SSH_KEY-}" != "" ]; then
# 	log_debug "Installing ssh keys from ${SSH_KEY}"
# 	mkdir -p ${tmpdir}/mountpoint/root/.ssh
# 	chmod 700 ${tmpdir}/mountpoint/root/.ssh
# 	cat ${SSH_KEY} >> ${tmpdir}/mountpoint/root/.ssh/authorized_keys
# 	chmod 600 ${tmpdir}/mountpoint/root/.ssh/authorized_keys
#     fi

#     # set root password
#     if [ -x ${tmpdir}/mountpoint/usr/sbin/chpasswd ]; then
# 	if [ "${ROOT_PASSWORD}" != "" ]; then
# 	    chroot ${tmpdir}/mountpoint /bin/bash -c "echo root:${ROOT_PASSWORD} | /usr/sbin/chpasswd root"
# 	fi
#     fi

#     log "building tarball"

#     pushd ${tmpdir}/mountpoint
#     tar -czvf ${image_name} *
#     popd

#     rm -rf ${tmpdir}

#     trap error_exit SIGINT SIGTERM ERR EXIT
}

function maybe_make_default_flavors() {
    # check to see if there is a flavors dir, and populate
    # it if not
    
    if [ ! -e ${BASE_DIR}/flavors ]; then
	mkdir -p ${BASE_DIR}/flavors
	rsync -av $EXAMPLE_DIR/flavors/ ${BASE_DIR}/flavors/

	#default network flavor will handle this case in future
	for bridge in $(brctl show | grep -v "bridge name" | cut -f1); do
	    cat > ${BASE_DIR}/flavors/network/${bridge} <<EOF
BRIDGE=${bridge}
EOF
	done

    fi
}