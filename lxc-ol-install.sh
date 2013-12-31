#!/bin/sh
#
# Copyright (C) 2013 Oracle. GPL v2.
# Author: Dwight Engen <dwight.engen@oracle.com>
#
# Test script to install/boot/destroy all Oracle Linux releases.
# Each release is installed in an LXC container and booted. An expect
# script is then used to login to the container, verify the rpm database,
# test the network by pinging www.oracle.com, and ssh into the container.
# After this the container is stopped and destroyed.
#
# Assumes the expect script is in /root, and containers are in /container
#
MIRRORURL="ftp://phocis/Oracle-Public-Yum"

TEST_CLONE="n"
TEST_USERNS="y"

# Set which arch you want to install
ARCHS="i386 x86_64"

# Set which i386 releases you have mirrored
OL4_i386_RELEASES="4.6 4.7 4.8 4.9 4.latest"
OL5_i386_RELEASES="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9"
OL6_i386_RELEASES="6.0 6.1 6.2 6.3 6.4"
ALL_i386_RELEASES="$OL4_i386_RELEASES $OL5_i386_RELEASES $OL6_i386_RELEASES"

# Set which x86_64 releases you have mirrored
OL4_x86_64_RELEASES="4.6 4.7 4.8 4.9 4.latest"
OL5_x86_64_RELEASES="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.latest"
OL6_x86_64_RELEASES="6.0 6.1 6.2 6.3 6.4 6.5"
ALL_x86_64_RELEASES="$OL4_x86_64_RELEASES $OL5_x86_64_RELEASES $OL6_x86_64_RELEASES"

# Set to any rootfs templates you want installed
#TEMPLATE_ROOTFSES="/root/template-rootfs/ol49-ovm /root/template-rootfs/ol58-min /root/template-rootfs/ol62-ovm"

becho()
{
    echo
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo
}

strip_escapes()
{
    sed -r -i -e 's/\x0D//g' $1
    sed -r -i -e 's/\x1Bc//g' $1
    sed -r -i -e 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K|G]//g' $1
}

container_start()
{
    becho "Starting container $1 ..."
    lxc-start -d -n $1 -L /container/$1-con.log
    lxc-wait -n $1 -s RUNNING
}

container_stop()
{
    becho "Shutdown container $1 ..."
    lxc-stop -t 120 -n $1
    #lxc-stop -n $1
    lxc-wait -n $1 -s STOPPED
}

container_login()
{
    becho "Logging in and test container $1 ..."
    expect /root/lxc-ol-install.exp $1 |tee /container/$1-exp.log
    strip_escapes /container/$1-exp.log
}

container_info()
{
    # wait for container to obtain an IP address
    #for try in `seq 1 20`; do
    #    CONTAINER_IP=`lxc-info -i -n $1 | awk '{ print $2 }'`
    #    if [ x"$CONTAINER_IP" != x ]; then
    #        break
    #    fi
    #    sleep 1
    #done
    CONTAINER_IP=`grep 'inet addr' $1-exp.log |awk -F: '{print $2}' |awk '{print $1}'`
}

container_ssh()
{
    becho "SSH into container $1 @ IP:$CONTAINER_IP ..."
    sed -i "/^$CONTAINER_IP/d" ~/.ssh/known_hosts
    expect /root/lxc-ol-ssh.exp $CONTAINER_IP |tee /container/$1-ssh.log
    strip_escapes /container/$1-ssh.log
    sed -i "/^$CONTAINER_IP/d" ~/.ssh/known_hosts
}

container_destroy()
{
    becho "Destroying container $1 ..."
    lxc-destroy -n $1

    # strip escape sequences from console log
    strip_escapes /container/$1-con.log
}

container_uid_shift()
{
    becho "Shifting uids $1 ..."
    /home/dengen/src/nsexec/uidmapshift -b /container/$1/rootfs 0 100000 1000
    echo "lxc.id_map = u 0 100000 1000" >> /container/$1/config
    echo "lxc.id_map = g 0 100000 1000" >> /container/$1/config
    /home/dengen/src/nsexec/uidmapshift -r /container/$1/rootfs
}

container_console()
{
    becho "Interactive testing with lxc-console. Ctrl-a-q to quit. Press ENTER"
    read
    lxc-console -n $1
}

container_clone()
{
    becho "Cloning $1 $2 ..."
    lxc-clone -o $1 -n $2
}

for arch in $ARCHS
do
    for release in $(eval echo "\$ALL_"$arch"_RELEASES")
    do
        ctname="OL-$arch-$release"
        becho "Creating container $ctname ..."
        lxc-create -n $ctname -t oracle -- -a $arch -R $release -u $MIRRORURL \
                   |tee /container/$ctname.install
        strip_escapes /container/$ctname.install

	if [ $TEST_USERNS = y ]; then
	    container_uid_shift $ctname
	fi

        container_start $ctname
        container_login $ctname
        container_info  $ctname
        container_ssh   $ctname
        container_stop  $ctname
	if [ $TEST_CLONE = y ]; then
	    container_clone   $ctname $ctname-01
	    container_start   $ctname-01
	    container_login   $ctname-01
            container_info    $ctname-01
            container_ssh     $ctname-01
	    container_stop    $ctname-01
	    container_destroy $ctname-01
	fi

        container_destroy $ctname
    done
done

for trootfs in $TEMPLATE_ROOTFSES
do
    ctname=`basename $trootfs`
    becho "Creating container $ctname from template rootfs $trootfs ..."
    lxc-create -n $ctname -t oracle -- -t $trootfs \
               |tee /container/$ctname.install
    strip_escapes /container/$ctname.install
    container_start    $ctname
    container_login    $ctname
    container_stop     $ctname
    container_destroy  $ctname
done

# Generate report
RPMCOUNT_TOTAL=0
for arch in $ARCHS
do
    for release in $(eval echo "\$ALL_"$arch"_RELEASES")
    do
        ctname="OL-$arch-$release"
        RPMCOUNT=`grep 'RPM-COUNT' $ctname-exp.log | tail -1 |awk '{print $2}'`
        RPMCOUNT_TOTAL=`expr $RPMCOUNT_TOTAL + $RPMCOUNT`
    done
done

echo "Installed    : `ls *.install |wc |awk '{print $1}'`"
echo "Ping success : `grep '3 packets transmitted, 3 received' *exp.log | wc |awk '{print $1}'`"
echo "SSH success  : `grep '^SSH-TEST-SUCCESS' *ssh.log | wc |awk '{print $1}'`"
echo "SCP success  : `grep '^SCP-TEST-SUCCESS' *ssh.log | wc |awk '{print $1}'`"
echo "Total RPMs   : $RPMCOUNT_TOTAL"
