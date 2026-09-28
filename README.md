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
- **SOPS and age** for secrets. The only secret in the repo is `talos/secrets/secrets.enc.yaml`,
  and it is encrypted.

## Layout

```
talos/
  schematics/    Image Factory schematics, one per hardware class
  patches/       one common patch, one per node, plus the Cilium prerequisites
  secrets/       secrets.enc.yaml, SOPS/age encrypted
  generated/     rendered machine configs, gitignored
kubernetes/
  cni/           Cilium Helm values
  device-plugins/  Intel GPU plugin
  backup/        in-cluster etcd backup job, not applied yet
scripts/
  gen-configs.sh     renders and validates machine configs
  etcd-snapshot.sh   manual encrypted etcd snapshot
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
kubectl apply -f kubernetes/device-plugins/intel-gpu-plugin.yaml
```

`gen-configs.sh` needs the age key to decrypt the secrets bundle. It runs `talosctl
validate` on every config it renders and deletes the output if validation fails, so a
broken config never reaches a node.

Nodes install to a disk picked by `/dev/disk/by-id`, not `/dev/sda`. `architect` has two
disks, and device names can swap between boots.

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

**The MS-01's Intel X710 is picky about SFP+ modules.** It checks them in firmware, so buy
passive MikroTik DACs and skip the third-party optics.

## Network

Right now everything sits on my flat home LAN. The API endpoint is `spire.home.arpa`,
pinned on every node with a `StaticHostConfig`, so the cluster keeps working even if home
DNS is down.

That pin currently points at `architect` directly. When a second control plane joins, it
has to point at a virtual IP instead, or losing `architect` takes the endpoint with it.

Later the lab gets its own routed subnet behind a MikroTik RB5009, which also brings BGP so
Cilium can advertise LoadBalancer IPs. The 10 GbE switch is for Ceph.

## What is next

- **Flux**, so the cluster pulls its state from this repo instead of me running `kubectl`.
- **Traefik** with Cilium handing out LoadBalancer IPs, and cert-manager for TLS.
- **Rook/Ceph** for replicated storage, once every MS-01 has a second NVMe for it.
- **Real backups** before anything stateful moves in.

I write about my projects at [marc-os.com](https://marc-os.com).
