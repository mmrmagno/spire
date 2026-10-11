# Spire

Spire is my homelab Kubernetes cluster, and this repo is everything needed to rebuild it
from scratch. Talos Linux on bare metal, two nodes for now, more on the way.

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

| Node | Hardware | RAM | Disks | Role |
|---|---|---|---|---|
| `architect` | Intel N100 mini PC | 16 GB | 1 TB NVMe, 800 GB SATA SSD | control plane |
| `ironclad` | Minisforum MS-01, i9-13900H | 32 GB | 1 TB NVMe | worker, iGPU transcoding |

A second MS-01 is on order, plus a MikroTik router and a 10 GbE switch.

## What runs on it

- **Talos Linux v1.14.1** with upstream Kubernetes v1.37.
- **Cilium** as the CNI, replacing kube-proxy entirely, with Hubble for seeing what talks
  to what.
- **Intel GPU device plugin**, so pods on `ironclad` can claim a share of the iGPU for
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

## Deploying an app

1. Make `kubernetes/apps/<app>/` with a namespace (Pod Security `restricted`), a Deployment
   with the image pinned by digest, a Service, a NetworkPolicy and a kustomization. Copy `blog/`
   for a public site or `homepage/` for a LAN app.
2. LAN app: add an HTTPRoute on the `home` Gateway with a `*.home` hostname. TLS and the
   Homepage tile come for free. Public app: add the hostname to the tunnel config instead.
3. Secrets go in a `*.enc.yaml`, encrypted with `sops --encrypt --in-place`.
4. List the folder in `kubernetes/apps/kustomization.yaml`, commit, push. Flux applies it within
   a minute, and a failed reconcile pings Discord.

Removing the folder removes the app; Flux prunes it.

## Layout

```
talos/
  schematics/    Image Factory schematics, one per hardware class
  patches/       one common patch, one per node, plus the Cilium prerequisites
  secrets/       secrets.enc.yaml, SOPS/age encrypted
  generated/     rendered machine configs, gitignored
kubernetes/
  flux/          Flux entry point: operator, FluxInstance, and the stages below in order
  infrastructure/  controllers: GPU plugin, cloudflared, Traefik, cert-manager, LB IPs and BGP
  infrastructure-config/  objects that need those controllers' CRDs: issuers, certificates
  apps/          workloads: the blog, Homepage, the Flux UI route
  cni/           Cilium Helm values, still installed by hand
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
  network-backup.sh  encrypted off-device config export
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
from this repo.

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

## Network

The lab has its own routed subnet behind a MikroTik RB5009 called `merchant`. The house
router does the internet, merchant does the lab, and the two route to each other rather than
NAT, so a device in the house reaches a lab service by its real address instead of a port
forward. That last part is not finished: until the house router learns a route back, merchant
masquerades the lab, and the config says so in a comment I would like to delete.

```
10.10.10.0/24   nodes, gateway 10.10.10.1
10.10.20.0/24   reserved for Cilium LoadBalancer IPs, advertised by BGP
10.10.30.0/24   reserved for Ceph
10.10.40.0/24   reserved for out-of-band management
```

The VLAN id matches the third octet, so I never have to look it up. One static route on the
house router covers all of it, now and for whatever I add later.

The network gear is declarative in the same way the nodes are: `network/*.rsc` is a template,
the values that should not be public live in a SOPS-encrypted file, and `scripts/gen-network.sh`
renders the two together. Rebuilding a device is a reset plus a one line import.

One port is deliberately held back. `ether8` sits outside the bridge with its own subnet and
its own DHCP server, so no VLAN, bridge or firewall mistake can cut me off from the router.
It cost a port I was not using and it has already earned its keep.

The API endpoint is `spire.home.arpa`, pinned on every node with a `StaticHostConfig`, so the
cluster keeps working even if DNS does not. That pin points at `architect` directly today.
When a second control plane joins it has to point at a virtual IP instead, or losing
`architect` takes the endpoint with it.

## Things I learned the hard way

**`HostnameConfig` needs `auto: "off"`** next to the hostname, quoted, because an unquoted
`off` is a YAML boolean. Without it the config fails validation.

**Moving from Flannel to Cilium on a live cluster is less scary than it sounds.** Talos
never deletes manifests it already deployed, so removing Flannel from the config breaks
nothing by itself. Install Cilium next to it, let `talosctl upgrade-k8s` prune Flannel
and kube-proxy (it has a `--dry-run`), then reboot the nodes. The only outage is the reboot.

**Do not disable the Talos discovery service when you install Cilium.** My first draft of
the patch removed it along with Flannel. KubePrism needs it, and Cilium talks to the API
server through KubePrism.

**Pods that start before Cilium is ready keep their old Flannel addresses** and cannot
resolve DNS. Delete them and they come back fine.

**Moving the cluster to a new subnet did not need a rebuild.** My notes said re-addressing a
single control plane means wiping it, because the etcd peer URL would be stale. That is
wrong. Talos rewrote the peer URL, reissued the API server certificate with the new address,
and both kubelets re-registered on their own. Cilium did not follow, though: it caches node
addresses when the agent starts, so it kept routing node to node traffic to addresses that
no longer existed while every node still reported `Ready`. Restart the `cilium` and
`cilium-envoy` daemonsets after any re-IP.

**The MS-01's Intel X710 is picky about SFP+ modules.** It checks them in firmware, so buy
passive MikroTik DACs and skip the third-party optics.

## What is next

- **browcord** moved over and made Kubernetes native: one pod per room instead of containers
  started through a Docker socket proxy.
- **Rook/Ceph** for replicated storage, once every MS-01 has a second NVMe for it.
- **Real backups** before anything stateful moves in.

I write about my projects at [marc-os.com](https://marc-os.com).
