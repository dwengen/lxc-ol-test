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
# The script can also be used to test that the containers created can
# be started under libvirt's lxc driver as well.
#
# Assumes containers are in /container
#

TOP=`dirname $0`
MIRRORURL="http://public-yum.oracle.com"

TEST_LXC="y"
TEST_LIBVIRT="y"
TEST_CLONE="n"
TEST_USERNS="n"

# Set which arch you want to install
ARCHS="i386 x86_64"

# Set which i386 releases you have mirrored
OL4_i386_RELEASES="4.6 4.7 4.8 4.9 4.latest"
OL5_i386_RELEASES="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.latest"
OL6_i386_RELEASES="6.0 6.1 6.2 6.3 6.4 6.5 6.latest"
ALL_i386_RELEASES="$OL4_i386_RELEASES $OL5_i386_RELEASES $OL6_i386_RELEASES"

# Set which x86_64 releases you have mirrored
OL4_x86_64_RELEASES="4.6 4.7 4.8 4.9 4.latest"
OL5_x86_64_RELEASES="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.latest"
OL6_x86_64_RELEASES="6.0 6.1 6.2 6.3 6.4 6.5 6.6 6.latest"
OL7_x86_64_RELEASES="7.0"
ALL_x86_64_RELEASES="$OL4_x86_64_RELEASES $OL5_x86_64_RELEASES $OL6_x86_64_RELEASES $OL7_x86_64_RELEASES"

# Set to any rootfs templates you want installed
#TEMPLATE_ROOTFSES="/root/template-rootfs/ol49-ovm /root/template-rootfs/ol58-min /root/template-rootfs/ol62-ovm"

# End of user settable variables

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

# Generic funtions no matter if we're lxc or libvirt
gen_container_uid_shift()
{
    becho "Shifting uids $1 ..."
    /home/dengen/src/nsexec/uidmapshift -b /container/$1/rootfs 0 100000 1000
    echo "lxc.id_map = u 0 100000 1000" >> /container/$1/config
    echo "lxc.id_map = g 0 100000 1000" >> /container/$1/config
    /home/dengen/src/nsexec/uidmapshift -r /container/$1/rootfs
}

gen_container_login()
{
    becho "Logging in and test container $1 ..."
    expect $TOP/lxc-ol-install.exp $1 $2 |tee /container/$1-$2-exp.log
    strip_escapes /container/$1-$2-exp.log
}

gen_container_ssh()
{
    becho "SSH into container $1 @ IP:$CONTAINER_IP ..."
    sed -i "/^$CONTAINER_IP/d" ~/.ssh/known_hosts
    expect $TOP/lxc-ol-ssh.exp $CONTAINER_IP |tee /container/$1-$2-ssh.log
    strip_escapes /container/$1-$2-ssh.log
    sed -i "/^$CONTAINER_IP/d" ~/.ssh/known_hosts
}

gen_container_info()
{
    # wait for container to obtain an IP address
    #for try in `seq 1 20`; do
    #    CONTAINER_IP=`lxc-info -i -n $1 | awk '{ print $2 }'`
    #    if [ x"$CONTAINER_IP" != x ]; then
    #        break
    #    fi
    #    sleep 1
    #done
    CONTAINER_IP=`grep 'inet addr' $1-$2-exp.log |awk -F: '{print $2}' |awk '{print $1}'`
    # OL7 only has ip cmd, not ifconfig so the expect cmd does both
    if [ x$CONTAINER_IP = "x" ]; then
        CONTAINER_IP=`grep 'inet ' $1-$2-exp.log |awk '{print $2}' |awk -F/ '{print $1}'`
    fi
}



lvt_container_define()
{
    sed -e "s/olXX/$1/" $TOP/libvirt-olXX.xml >/tmp/lxc-olXX.xml
    sed -i "s/ARCH/$2/" /tmp/lxc-olXX.xml
    virsh -c lxc:/// define /tmp/lxc-olXX.xml
    rm /tmp/lxc-olXX.xml
}

lvt_container_undefine()
{
    virsh -c lxc:/// undefine $1
}

lvt_container_start()
{
    virsh -c lxc:/// start $1
}

lvt_container_stop()
{
    # virsh -c lxc:/// destroy $1
    # the above command doesn't work on OL6.x so we have to kill
    # the container ourself
    lvt_lxc_pid=`virsh -c lxc:/// dominfo $1 2>/dev/null |grep 'Id:' |awk '{print $2}'`
    init_pid=`pgrep -P $lvt_lxc_pid`
    kill -9 $init_pid
    # wait for container to actually stop
    for try in `seq 1 80`; do
	ps aux |grep -q "[l]ibvirt_lxc.*$1"
        if [ $? -eq 1 ]; then
            break
        fi
        usleep 250000
    done
}

lxc_container_start()
{
    becho "Starting container $1 ..."
    lxc-start -d -n $1 -L /container/$1-con.log
    lxc-wait -n $1 -s RUNNING
}

lxc_container_stop()
{
    becho "Shutdown container $1 ..."
    #lxc-stop -t 120 -n $1
    lxc-stop -n $1
    lxc-wait -n $1 -s STOPPED
    # strip escape sequences from console log
    strip_escapes /container/$1-con.log
}

lxc_container_login()
{
    becho "Logging in and test container $1 ..."
    expect $TOP/lxc-ol-install.exp lxc $1 |tee /container/$1-lxc-exp.log
    strip_escapes /container/$1-lxc-exp.log
}

lxc_container_attach()
{
    becho "Attaching to $1 ..."
    lxc-attach -n $1 -- /bin/cat /etc/redhat-release
    if [ $? -eq 0 ]; then
        LXC_ATTACH_SUCCESS=`expr $LXC_ATTACH_SUCCESS + 1`
    fi
}

lxc_container_destroy()
{
    becho "Destroying container $1 ..."
    lxc-destroy -n $1
}

lxc_container_console()
{
    becho "Interactive testing with lxc-console. Ctrl-a-q to quit. Press ENTER"
    read
    lxc-console -n $1
}

lxc_container_clone()
{
    becho "Cloning $1 $2 ..."
    lxc-clone -o $1 -n $2
}

LXC_ATTACH_SUCCESS=0
for arch in $ARCHS
do
    for release in $(eval echo "\$ALL_"$arch"_RELEASES")
    do
        ctname="OL-$arch-$release"
        becho "Creating container $ctname ..."
        lxc-create -n $ctname -t oracle -- -a $arch -R $release -u $MIRRORURL \
                   |tee /container/$ctname.install
        strip_escapes /container/$ctname.install

	if [ $TEST_LXC = y ]; then
	    if [ $TEST_USERNS = y ]; then
		container_uid_shift $ctname
	    fi

	    lxc_container_start  $ctname
	    gen_container_login  $ctname lxc
	    gen_container_info   $ctname lxc
	    gen_container_ssh    $ctname lxc
	    lxc_container_attach $ctname
	    lxc_container_stop   $ctname
	    if [ $TEST_CLONE = y ]; then
		lxc_container_clone   $ctname $ctname-01
		lxc_container_start   $ctname-01
		gen_container_login   $ctname-01 lxc
		gen_container_info    $ctname-01 lxc
		gen_container_ssh     $ctname-01 lxc
		lxc_container_stop    $ctname-01
		lxc_container_destroy $ctname-01
	    fi
	fi

	if [ $TEST_LIBVIRT = y ]; then
	    lvt_arch=$arch
	    if [ $arch = "i386" ]; then
		lvt_arch="i686"
	    fi
	    lvt_container_define   $ctname $lvt_arch
	    lvt_container_start    $ctname
	    gen_container_login    $ctname lvt
	    gen_container_info     $ctname lvt
	    gen_container_ssh      $ctname lvt
	    lvt_container_stop     $ctname
	    lvt_container_undefine $ctname
	fi

        lxc_container_destroy $ctname
    done
done

for trootfs in $TEMPLATE_ROOTFSES
do
    ctname=`basename $trootfs`
    becho "Creating container $ctname from template rootfs $trootfs ..."
    lxc-create -n $ctname -t oracle -- -t $trootfs \
               |tee /container/$ctname.install
    strip_escapes /container/$ctname.install
    lxc_container_start    $ctname
    gen_container_login    $ctname lxc
    lxc_container_stop     $ctname
    lxc_container_destroy  $ctname
done

# Generate report

echo "Installed          : `ls *.install |wc |awk '{print $1}'`"

if [ $TEST_LXC = y ]; then
    RPMCOUNT_TOTAL=0
    for arch in $ARCHS
    do
	for release in $(eval echo "\$ALL_"$arch"_RELEASES")
	do
	    ctname="OL-$arch-$release"
	    RPMCOUNT=`grep 'RPM-COUNT' $ctname-lxc-exp.log | tail -1 |awk '{print $2}'`
	    RPMCOUNT_TOTAL=`expr $RPMCOUNT_TOTAL + $RPMCOUNT`
	done
    done
    echo "Total RPMs         : $RPMCOUNT_TOTAL"
    echo "LXC Attach success : $LXC_ATTACH_SUCCESS"
    echo "LXC Ping success   : `grep '3 packets transmitted, 3 received' *lxc-exp.log | wc |awk '{print $1}'`"
    echo "LXC SSH success    : `grep '^SSH-TEST-SUCCESS' *lxc-ssh.log | wc |awk '{print $1}'`"
    echo "LXC SCP success    : `grep '^SCP-TEST-SUCCESS' *lxc-ssh.log | wc |awk '{print $1}'`"
fi
if [ $TEST_LIBVIRT = y ]; then
    echo "LVT Ping success   : `grep '3 packets transmitted, 3 received' *lvt-exp.log | wc |awk '{print $1}'`"
    echo "LVT SSH success    : `grep '^SSH-TEST-SUCCESS' *lvt-ssh.log | wc |awk '{print $1}'`"
    echo "LVT SCP success    : `grep '^SCP-TEST-SUCCESS' *lvt-ssh.log | wc |awk '{print $1}'`"
fi
