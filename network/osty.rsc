# osty, MikroTik CRS309-1G-8S+IN, 10G fabric for the lab.
# This is a switch, not a router. Apply only once a DAC links it to merchant, otherwise
# there is no path to it at all.
# Management lives on ether1, off the bridge, so bridge or VLAN mistakes cannot strand it.
#
# PREFLIGHT, do this BEFORE the reset. keep-users=yes also keeps a factory `admin`, and
# mac-winbox below answers on every port at layer 2. So first create a keyed user:
#   /user add name=<you> group=full password=<from the vault>
#   /user ssh-keys import public-key-file=<you>.pub user=<you>
# prove key login in a second session, then once the config is applied: /user disable admin
#
# There are deliberately no firewall rules here. This is an L2 switch on a trusted subnet
# reached only through merchant, so /ip service above is the access control. Add an input
# chain once the device is physically reachable and a mistake cannot strand it.

/system identity set name=osty

/interface bridge
add name=bridge-fabric vlan-filtering=no

/interface bridge port
add bridge=bridge-fabric interface=sfp-sfpplus1
add bridge=bridge-fabric interface=sfp-sfpplus2 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus3 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus4 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus5 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus6 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus7 pvid=10
add bridge=bridge-fabric interface=sfp-sfpplus8 pvid=10

/interface bridge vlan
add bridge=bridge-fabric vlan-ids=10 tagged=sfp-sfpplus1 \
    untagged=sfp-sfpplus2,sfp-sfpplus3,sfp-sfpplus4,sfp-sfpplus5,sfp-sfpplus6,sfp-sfpplus7,sfp-sfpplus8

/interface list
add name=MGMT
/interface list member
add interface=ether1 list=MGMT

/ip address
add address=10.10.10.2/24 interface=ether1

/ip route
add dst-address=0.0.0.0/0 gateway=10.10.10.1

/ip dns set servers=10.10.10.1

/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set www-ssl disabled=yes
set api disabled=yes
set api-ssl disabled=yes
set reverse-proxy disabled=yes
set ssh address=10.10.10.0/24,REPLACE_MGMT_HOST/32
set winbox address=10.10.10.0/24,REPLACE_MGMT_HOST/32

/ip ssh set strong-crypto=yes host-key-type=ed25519

/tool mac-server set allowed-interface-list=none
# mac-winbox stays on ether1 only: the way back in if an IP mistake strands management, never from the node ports.
/tool mac-server mac-winbox set allowed-interface-list=MGMT
/tool mac-server ping set enabled=no
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set discover-interface-list=none
# ddns-enabled only accepts yes or auto on 7.23.8, so auto (the default) is as off as it gets.
/ip cloud set update-time=no
/system package update set channel=long-term

# Cosmetic, and last on purpose: /import halts on the first failing line, so nothing
# non-essential may run before management addressing exists.
/system clock set time-zone-name=Europe/Zurich
/system ntp client set enabled=yes servers=ch.pool.ntp.org

/interface bridge set [find name=bridge-fabric] vlan-filtering=yes
