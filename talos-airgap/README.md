# talos-airgap

Prepare everything a [Talos Linux](https://www.talos.dev) cluster needs on a connected host, carry it into an airgap
network, and load it into a registry there.

- **`fetch`** (internet side): builds a schematic with the
  [Image Factory](https://factory.talos.dev) for your hardware, downloads all the images, creates an image cache and
  builds a bootable ISO with that cache inside.
- **`push`** (airgap side): verifies the bundle, pushes the images to your registry and writes the Talos registry
  mirror patch.

Rootless: no `sudo` needed. Only `bash`, `curl`, `tar` and `sha256sum` (or `shasum`) must be present; `talosctl` and
`crane` are downloaded into the bundle and checked against their published checksums, so the airgap host needs nothing
pre-installed.

## Requirements

| | Internet side (`fetch`) | Airgap side (`push`) |
|---|---|---|
| OS | Linux or macOS, amd64 or arm64 | Linux or macOS, amd64 or arm64 |
| Tools | bash, curl, tar, sha256sum | bash, sha256sum |
| Optional | docker (bakes the image cache into the ISO) | — |
| Network | factory.talos.dev, github.com, the image registries (or a proxy) | the destination registry |

## Quick start

```bash
# internet side
./talos-airgap.sh fetch --talos-version 1.13.10 --target metal --cpu amd

# copy ./bundle to the airgap side (USB disk, data diode...), then:
cd bundle
./talos-airgap.sh push --registry reg.lan:5000 --registry-ca /path/to/ca.pem
```

Any missing version or profile value is asked interactively (the Talos version list comes from the Image Factory).
In a non-interactive context (CI, cron), missing values stop the script with an error.

## Examples

**Proxmox / QEMU virtual machines**, with iSCSI tools for a CSI driver:

```bash
./talos-airgap.sh fetch --talos-version 1.13.10 --target vm --extensions iscsi-tools
```

**Intel servers with an NVIDIA GPU** (open kernel modules, production branch by default):

```bash
./talos-airgap.sh fetch --talos-version 1.13.10 --target metal --cpu intel --gpu nvidia
```

**Older NVIDIA GPU** (pre-Turing, e.g. GTX 10xx) on the LTS branch:

```bash
./talos-airgap.sh fetch --talos-version 1.13.10 --target metal --cpu amd --gpu nvidia \
  --nvidia-driver proprietary --nvidia-branch lts
```

**AMD CPU + AMD GPU**, behind a corporate proxy:

```bash
./talos-airgap.sh fetch --talos-version 1.13.10 --target metal --cpu amd --gpu amd \
  --proxy http://proxy.corp:3128
```

**Cilium as CNI**: render the chart once, list its images, carry both:

```bash
helm template cilium cilium/cilium --version 1.20.1 -n kube-system -f values.yaml > cilium.yaml
grep -oE 'image: *"?[^" ]+' cilium.yaml | sed -E 's/image: *"?//' | sort -u > cilium-images.txt

./talos-airgap.sh fetch --talos-version 1.13.10 --target vm \
  --extra-images cilium-images.txt --extra-files cilium.yaml
```

**Several hardware profiles in one bundle**: run `fetch` several times with the same `--out`; images already pulled
are reused, each profile adds its own ISO and installer image.

```bash
./talos-airgap.sh fetch --talos-version 1.13.10 --target vm
./talos-airgap.sh fetch --talos-version 1.13.10 --target metal --cpu intel --gpu nvidia
```

**Push to a Harbor project with credentials**:

```bash
REGISTRY_PASSWORD='...' ./talos-airgap.sh push --registry harbor.lan --registry-prefix talos \
  --registry-user robot-talos --registry-ca ca.pem
```

**Lab registry over plain HTTP**:

```bash
./talos-airgap.sh push --registry 10.0.0.5:5000 --insecure
```

## What to carry: `--mode`

| Mode | Bundle contains | Use when |
|---|---|---|
| `both` (default) | ISO with image cache + images for the registry | you have a registry and want a self-sufficient first boot |
| `cache` | ISO with image cache only | no registry at all; requires docker on the internet side |
| `registry` | images only + Factory ISO | you only need the registry; no docker needed |

Without docker, `both` falls back to the plain Factory ISO (no cache inside): nodes then need the registry from the
first boot.

## Bundle content

```
bundle/
├── bin/                 talosctl and crane (pinned, checksum verified)
├── images/<id>/         one OCI layout per image (modes registry/both)
├── images.txt           image ref -> directory
├── image-cache.oci/     Talos image cache (modes cache/both)
├── talos-<ver>-<platform>-<arch>-<schematic>.iso
├── schematic.yaml       Image Factory schematic (extensions, kernel args)
├── profile.env          profile and pinned tool versions
├── files/               --extra-files (rendered manifests...)
├── talos-airgap.sh      the script itself
├── SHA256SUMS
└── machine-patch.yaml   written by push
```

## Registry layout and Talos patch

Images keep their upstream registry as a path:
`ghcr.io/siderolabs/kubelet:v1.36.3` → `reg.lan:5000[/prefix]/ghcr.io/siderolabs/kubelet:v1.36.3`. No manifest needs
rewriting.

`push` writes `machine-patch.yaml`: one `RegistryMirrorConfig` per upstream registry and, with `--registry-ca` or
`--insecure`, a `RegistryTLSConfig`. Use it when generating the machine configuration:

```bash
talosctl gen config my-cluster https://10.0.0.10:6443 --config-patch @bundle/machine-patch.yaml
```

## Integrity

`fetch` prints a fingerprint of `SHA256SUMS`; `push` prints it again before verifying every file. **Write the
fingerprint down on the internet side and compare it on the airgap side**: the checksums inside the bundle only catch
corruption, the fingerprint compared out of band also catches tampering.

## Limits

- **Talos 1.12 or newer only.** Older `talosctl` has no `image k8s-bundle`, and the registry patch uses the
  `RegistryMirrorConfig` documents introduced in 1.12.
- **No Secure Boot.** Factory Secure Boot images are signed with Sidero Labs keys, but an ISO with an embedded image
  cache must be built locally with `imager`, which means your own signing keys and enrolling them on every machine.
  UEFI without Secure Boot only.
- **Image cache in the ISO needs docker** on the internet side (the `imager` container). The imager image itself is
  pulled with crane, so the docker daemon needs no proxy configuration.
- **Registry credentials are not written to the patch.** Add a `RegistryAuthConfig` document by hand if your nodes must
  authenticate to pull.
- **`--registry-ca` replaces the system trust store** for the push only (`SSL_CERT_FILE`): give the CA that signed the
  registry certificate.
- **Upgrades = a new bundle.** Run `fetch` again with the new `--talos-version`, carry, `push`.
- **Extra images are taken as-is**: the script does not render Helm charts, see the Cilium example.
- **Image Factory JSON is parsed with `sed`** to avoid a `jq` dependency; an API format change would need a fix.
- The first pull of a new schematic installer can take several minutes: the Image Factory builds it on demand.

Run `./talos-airgap.sh --help` for every option, and see [SPEC.md](SPEC.md) for the design decisions.
