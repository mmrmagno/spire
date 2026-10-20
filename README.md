# Spire

Spire is my homelab Kubernetes cluster, and this repo is everything needed to rebuild it
from scratch. Talos Linux on bare metal, three nodes for now, more on the way.

The shape is simple: patches and encrypted secrets go in, one script renders the machine
configs, `talosctl` applies them. Nothing on the nodes is configured by hand, because Talos
does not let you. There is no SSH and no shell, only an API.

## Why

I wanted to actually learn Kubernetes, not click through a managed cluster. Running it on
my own hardware means I own every layer: the OS, the network, storage, backups, and every
way they can break.

It is also where my self-hosted services are going to live. They currently run on a cloud
server with Docker Compose, and the plan is to move all of them here.

## Hardware

| Node | Hardware | CPU | RAM | Disks | Role |
|---|---|---|---|---|---|
| `architect` | ZOTAC ZBOX CI337 nano | Intel N100, 4 cores | 16 GB DDR5 | 1 TB NVMe, 800 GB SATA SSD | control plane |
| `ironclad` | Minisforum MS-01 | i9-13900H, 14 cores / 20 threads | 32 GB DDR5 | 1 TB NVMe | worker, iGPU transcoding |
| `regent` | Minisforum MS-01 | i9-13900H, 14 cores / 20 threads | 32 GB DDR5 | 1 TB NVMe | worker |

| Device | Hardware | Role |
|---|---|---|
| `merchant` | MikroTik RB5009 | lab router, BGP peer for LoadBalancer IPs |
| `osty` | MikroTik CRS309-1G-8S+IN | 10G SFP+ switch |

Two more MS-01s are planned.

## What runs on it

- **Talos Linux v1.14.4** with upstream Kubernetes v1.37.
- **Cilium** as the CNI, replacing kube-proxy entirely, with Hubble for seeing what talks
  to what.
- **Intel GPU device plugin**, so pods on the MS-01 workers can claim a share of the iGPU for
  hardware transcoding.
- **SOPS and age** for secrets. Every secret in the repo is a `*.enc.yaml`, encrypted; Flux holds
  its own age key and decrypts in the cluster.
- **Flux** (through the Flux Operator) applies everything under `kubernetes/` from this repo.
- **Cilium BGP and LB IPAM**: Services of type LoadBalancer get an address from a dedicated range,
  and the gateway router learns the route over BGP.
- **Traefik** on the Gateway API, with **cert-manager** issuing a wildcard Let's Encrypt
  certificate over Cloudflare DNS-01 for the LAN-only names.
- **Cloudflare Tunnel** for the public sites, so nothing listens on the home WAN.
- **Homepage** as the start page for everything on the LAN, built from HTTPRoute annotations.
- **kube-prometheus-stack** for metrics and alerts. Alerts land in Discord.
- **Tailscale** on the workers, so I can reach the LAN side from anywhere without opening a port.

## Layout

```
talos/
  schematics/    Image Factory schematics, one per hardware class
  patches/       one common patch, one per node, one for the MS-01 network, plus the Cilium prerequisites
  secrets/       secrets.enc.yaml, SOPS/age encrypted
  generated/     rendered machine configs, gitignored
kubernetes/
  flux/          Flux entry point: operator, FluxInstance, and the stages below in order
  infrastructure/  controllers: GPU plugin, cloudflared, Traefik, cert-manager, monitoring, BGP
  infrastructure-config/  objects that need those controllers' CRDs: issuers, certificates
  apps/          workloads: the blog, browcord, valart, my notes site, Homepage, the Flux UI route
  cni/           Cilium, installed by hand once at bootstrap, then managed by Flux
  backup/        in-cluster etcd backup job, not applied yet
network/
  merchant.rsc     RouterOS config for the RB5009 gateway
  osty.rsc         RouterOS config for the CRS309 10G switch
  secrets.enc.yaml node MACs and the management address, SOPS/age encrypted
  generated/       rendered configs, gitignored
scripts/
  gen-configs.sh     renders and validates machine configs
  gen-network.sh     renders the gateway and switch configs
  bootstrap-flux.sh  installs the Flux Operator and hands the cluster to git
  etcd-snapshot.sh   manual encrypted etcd snapshot
  network-backup.sh  encrypted router config export, copied to Proton Drive
```

Rendered machine configs are never committed. They contain the cluster CA and join tokens,
and they are a pure function of the secrets bundle plus the patches, so there is no reason
to store them.

## Rebuilding

```sh
scripts/gen-configs.sh all
talosctl apply-config --insecure -n <node-ip> -f talos/generated/<node>.yaml
talosctl bootstrap -n <control-plane-ip>
talosctl kubeconfig ./kubeconfig
helm install cilium cilium/cilium --version 1.20.2 -n kube-system -f kubernetes/cni/cilium-values.yaml
scripts/bootstrap-flux.sh
```

Everything after Cilium comes from git. The bootstrap script only installs the Flux
Operator and the age key Flux decrypts secrets with, then the FluxInstance pulls the rest
from this repo. Cilium is installed by hand only because nothing runs before the cluster has
a network, Flux included. Once Flux is up it adopts the release, and from then on Cilium
changes through git like everything else.

The router is rebuilt the same way, from a reset rather than a backup:

```sh
scripts/gen-network.sh merchant
scp network/generated/merchant.rsc mmr@merchant:/
ssh mmr@merchant '/import file=merchant.rsc verbose=yes dry-run'
# then, only if the dry run is clean
/system reset-configuration no-defaults=yes keep-users=yes run-after-reset=merchant.rsc
```

`gen-configs.sh` needs the age key to decrypt the secrets bundle. It runs `talosctl
validate` on every config it renders and deletes the output if validation fails, so a
broken config never reaches a node.

Nodes install to a disk picked by `/dev/disk/by-id`, not `/dev/sda`. `architect` has two
disks, and device names can swap between boots.

## What is next

- **The rest of the cloud server.** The blog, browcord and valart already run here.
- **An MS-01 in place of architect.** The workers moved to 10G DACs in October, the N100
  is the last node on 1G copper.
- **Rook/Ceph** for replicated storage, once every MS-01 has a second NVMe for it.
- **Real backups** before anything stateful moves in.

I write about my projects at [marc-os.com](https://marc-os.com).
