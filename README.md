FAKECLOUD
=========

Stupid automation layer for libvirt for my own personal use.  This probably
won't be suitable for you, or you may well be too disgusted with it to use
it.  So be it.

Installation
------------

copy virt.sh and fakecloud into the same directory somewhere on your path (~/bin?).

make sure you have kpartx, debootstrap, kvm, qemu-nbd and all that stuff installed.

maybe make a ~/.fakecloudrc with bash environment variables:


      # where to throw base images and libvirt xml templates &c
      BASE_DIR=/var/lib/fakecloud

      # where to look for lexically sorted first-boot actions on
      # not-yet-live machine (see examples in plugins)
      PLUGIN_DIR=/home/rpedde/bin/fakecloud/plugins

      # where to look for scripts to run after machine is running
      # (see examples in post-install), as directed with -p option
      # on create.
      POSTINSTALL_DIR=/home/rpedde/bin/fakecloud/post-install

      # extra packages you want installed on all vms that get spun
      EXTRA_PACKAGES=emacs23-nox,sudo

      # root password on default kicks.  Don't set for key-only
      ROOT_PASSWORD=secret
      
      # Which libvirt template to use
      # Use "nestedkvm" and make sure you load your kvm_intel or kvm_amd
      # model with nested=1 for nested virt.
      VIRT_TEMPLATE="kvm"

Use
---

    # Kick an instance named "test-instance" with ubuntu 11.04
    sudo fakecloud create test-instance ubuntu-natty

    # List all fakecloud instances and kvm states
    sudo fakecloud list

    # destroy the instance "test-instance" and clean up all qcow images
    sudo fakecloud destroy test-instance


Advanced Use
------------

    # kick a 11.04 instance and run the post-install script "kong" when complete
    # also, show debugging logs
    sudo fakecloud -d -pkong create test-instance ubuntu-natty

    # kick a 10.10 instance using the default "small" flavor (12G disk,
    # 1G ram, 1vcpu)
    sudo fakecloud -fsmall create test-instance ubuntu-maverick

This should probably work with ubuntu-maverick, ubuntu-natty, ubuntu-oneiric (if
your debootstrap script understands it... otherwise just symlink oneiric to gutsy
in /usr/share/debootstrap/scripts... that's what I did), and debian-squeeze.

YMMV.  No warranty.  Etc.


Tips
----

* make sure your /tmp is not mounted nodev

* make sure you have a bridge device up, as that's where your vnet device
will get connected.

* make sure the loop module is loaded with max_part=16

Stuff to Do
-----------

make your own flavors in $BASE_DIR/flavors

Bugs
----

All kinds, not least of which is the fact that you are doing
evals and stuff in bash running as root.  Be appropriately scared.
