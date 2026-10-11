# merchant, MikroTik RB5009UG+S+IN. The lab gateway.
# Applied to a factory-default router with:
#   /system reset-configuration no-defaults=yes keep-users=yes skip-backup=yes run-after-reset=merchant.rsc
# Users and SSH keys are never in this file. They survive the reset via keep-users=yes.
#
# PREFLIGHT, do this BEFORE the reset. keep-users=yes also keeps a factory `admin`, and this
# config opens ssh and winbox to the whole lab subnet. So first create a keyed user:
#   /user add name=<you> group=full password=<from the vault>
#   /user ssh-keys import public-key-file=<you>.pub user=<you>
# prove key login in a second session, then once the config is applied: /user disable admin

/system identity set name=merchant

/interface bridge
add name=bridge-lab vlan-filtering=no

/interface list
add name=WAN
add name=LAN
add name=MGMT

/interface bridge port
add bridge=bridge-lab interface=ether2 pvid=10
add bridge=bridge-lab interface=ether3 pvid=10
add bridge=bridge-lab interface=ether4 pvid=10
add bridge=bridge-lab interface=ether5 pvid=10
add bridge=bridge-lab interface=ether6 pvid=10
add bridge=bridge-lab interface=ether7 pvid=10
add bridge=bridge-lab interface=sfp-sfpplus1

/interface bridge vlan
add bridge=bridge-lab vlan-ids=10 tagged=bridge-lab,sfp-sfpplus1 \
    untagged=ether2,ether3,ether4,ether5,ether6,ether7

/interface vlan
add name=vlan10-lab interface=bridge-lab vlan-id=10

/interface list member
add interface=ether1 list=WAN
add interface=vlan10-lab list=LAN
add interface=ether8 list=MGMT

/ip address
add address=192.168.0.2/24 interface=ether1
add address=10.10.10.1/24 interface=vlan10-lab
add address=192.168.88.1/24 interface=ether8

/ip route
add dst-address=0.0.0.0/0 gateway=192.168.0.1

# Cilium on the workers advertises LoadBalancer /32s from 10.10.20.0/24. Accept only those.
/routing filter rule
add chain=k8s-in rule="if (dst in 10.10.20.0/24 && dst-len==32) { accept }" comment="spire LB IPs only"
add chain=k8s-in rule="reject"
/routing bgp instance
add name=lab as=64512 router-id=10.10.10.1
/routing bgp template
add name=k8s input.filter=k8s-in
/routing bgp connection
add name=ironclad instance=lab templates=k8s remote.address=10.10.10.21 remote.as=64513 \
    local.role=ebgp local.address=10.10.10.1

/ip pool
add name=lab-pool ranges=10.10.10.100-10.10.10.199
add name=bg-pool ranges=192.168.88.100-192.168.88.199

/ip dhcp-server
add name=lab interface=vlan10-lab address-pool=lab-pool lease-time=1d disabled=no
add name=breakglass interface=ether8 address-pool=bg-pool lease-time=1h disabled=no

/ip dhcp-server network
add address=10.10.10.0/24 gateway=10.10.10.1 dns-server=10.10.10.1 domain=home.arpa
add address=192.168.88.0/24 gateway=192.168.88.1 dns-server=192.168.88.1

# Keyed on the nodes' copper NICs. Only ether1 is 2.5G on this box, so ether2-8 link at 1G.
# Moving a node to SFP+ presents a different MAC and needs its own lease.
/ip dhcp-server lease
add mac-address=REPLACE_ARCHITECT_MAC address=10.10.10.11 server=lab comment=architect
add mac-address=REPLACE_IRONCLAD_MAC address=10.10.10.21 server=lab comment=ironclad

/ip dns set servers=192.168.0.1 allow-remote-requests=yes

/ip dns static
add name=merchant.home.arpa address=10.10.10.1
add name=spire.home.arpa address=10.10.10.11

/ip firewall address-list
add list=mgmt address=REPLACE_MGMT_HOST comment="workstation eno1"

/ip firewall filter
add chain=input action=accept connection-state=established,related,untracked
add chain=input action=drop connection-state=invalid
add chain=input action=accept protocol=icmp limit=50,5:packet
add chain=input action=accept in-interface-list=MGMT comment="break-glass ether8"
add chain=input action=accept in-interface-list=LAN protocol=udp dst-port=53
add chain=input action=accept in-interface-list=LAN protocol=tcp dst-port=53
add chain=input action=accept in-interface-list=LAN protocol=udp dst-port=67
add chain=input action=accept in-interface-list=LAN protocol=tcp dst-port=179 \
    src-address=10.10.10.0/24
add chain=input action=accept src-address-list=mgmt protocol=tcp dst-port=22,8291
# Without this the lab subnet can ping and resolve but cannot manage the router:
# /ip service address= is checked only after the firewall has already accepted the packet.
add chain=input action=accept in-interface-list=LAN protocol=tcp dst-port=22,8291 \
    comment="management from the lab subnet"
add chain=input action=log log-prefix="in-drop" limit=10,5:packet
add chain=input action=drop

/ip firewall filter
add chain=forward action=fasttrack-connection connection-state=established,related
add chain=forward action=accept connection-state=established,related,untracked
add chain=forward action=drop connection-state=invalid
add chain=forward action=accept in-interface-list=LAN comment="lab to anywhere"
add chain=forward action=accept src-address=192.168.0.0/24 dst-address=10.10.20.0/24 \
    comment="house to LoadBalancer services"
add chain=forward action=accept src-address-list=mgmt dst-address=10.10.10.0/24
add chain=forward action=accept src-address=192.168.88.0/24 dst-address=10.10.10.0/24 \
    comment="break-glass can reach the nodes, not just the router"
add chain=forward action=log log-prefix="fwd-drop" limit=10,5:packet
add chain=forward action=drop

/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set www-ssl disabled=yes
set api disabled=yes
set api-ssl disabled=yes
set reverse-proxy disabled=yes
set ssh address=REPLACE_MGMT_HOST/32,192.168.88.0/24,10.10.10.0/24
set winbox address=REPLACE_MGMT_HOST/32,192.168.88.0/24,10.10.10.0/24

/ip ssh set strong-crypto=yes host-key-type=ed25519

/tool mac-server set allowed-interface-list=MGMT
/tool mac-server mac-winbox set allowed-interface-list=MGMT
/tool mac-server ping set enabled=no
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set discover-interface-list=MGMT
# ddns-enabled only accepts yes or auto on 7.23.8, so auto (the default) is as off as it gets.
/ip cloud set update-time=no
/ip proxy set enabled=no
/ip socks set enabled=no
/ip upnp set enabled=no

# TEMPORARY, REMOVE WHEN THE UDM HAS THE ROUTE.
# The design is routed with a single NAT at the UDM. Until the UDM carries
#   10.10.0.0/16 via 192.168.0.2
# the lab has no return path, so nothing here can reach the internet. This rule
# double-NATs the lab to get it online. Delete it and this comment once the UDM
# route exists, then re-verify that the house can still reach LoadBalancer IPs.
/ip firewall nat
add chain=srcnat action=masquerade out-interface-list=WAN comment="TEMPORARY until the UDM route exists"

# Everything below is cosmetic. It sits last on purpose: /import stops at the first failing
# line, so anything non-essential must run only after the network is up and reachable.
/system clock set time-zone-name=Europe/Zurich
/system ntp client set enabled=yes servers=ch.pool.ntp.org

/interface bridge set [find name=bridge-lab] vlan-filtering=yes
