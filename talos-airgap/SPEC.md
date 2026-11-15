# talos-airgap.sh — spec

Bash script that prepares everything a Talos cluster needs on the internet side, and loads it on the airgap side.
Companion of the blog post "Talos in an airgap environment" (j.hommet.net, FR/EN).

## Scope

- In: Talos ISO + installer for a hardware profile, all images (Talos defaults + user extra list), image cache,
  transfer bundle, push to an airgap registry, Talos machine config patch for registry mirrors.
- Out: Secure Boot (needs own keys + imager + key enrollment), cluster install/bootstrap, upgrades (= new bundle).

## Constraints

- Linux amd64 host, **no admin rights**: everything rootless. Binaries downloaded to `bundle/bin/`.
- Dependencies: `bash`, `curl`, `tar`, `sha256sum`. Downloaded: `talosctl` (pinned to the Talos version), `crane`.
- Optional: `docker` (to bake the image cache into the ISO with `imager`). Without docker: Factory ISO + registry (`--mode cache` then errors out).
- Proxy: `--proxy URL` (optional) exported as `HTTP(S)_PROXY`; `NO_PROXY` respected. All tools honor it.
- UEFI boot, no Secure Boot.

## Subcommands

```
talos-airgap.sh fetch [options]   # internet side, writes ./bundle
talos-airgap.sh push  [options]   # airgap side, reads ./bundle
```

### fetch

| Flag | Default | Notes |
|---|---|---|
| `--talos-version` | interactive | Missing + TTY: list from Factory `GET /versions`, newest stable preselected. Missing + no TTY: error. |
| `--k8s-version` | Talos default | |
| `--target` | interactive | `metal` \| `vm` (vm = `qemu-guest-agent`, nocloud platform) |
| `--cpu` | interactive | `intel` \| `amd` → `intel-ucode` / `amd-ucode`. Only for `--target metal` (vm: not asked) |
| `--gpu` | `none` | `none` \| `nvidia` \| `amd` (`amdgpu`) |
| `--nvidia-driver` | `open` | `open` (`nvidia-open-gpu-kernel-modules-*`) \| `proprietary` (`nonfree-kmod-nvidia-*`, pre-Turing) |
| `--nvidia-branch` | `production` | `production` \| `lts`; always adds `nvidia-container-toolkit-<branch>` |
| `--extensions` | | extra official extensions, comma separated |
| `--kernel-args` | `net.ifnames=0` | |
| `--extra-images` | | file, one image ref per line (Cilium, NVIDIA device plugin...) |
| `--extra-files` | | files copied as-is into `bundle/files/` (rendered `cilium.yaml`) |
| `--arch` | `amd64` | passed to crane/cache-create `--platform linux/<arch>` |
| `--proxy` | | |
| `--mode` | `both` | `cache` (ISO with image cache only) \| `registry` (image tars only) \| `both`. Avoids carrying images twice |
| `--out` | `./bundle` | |

Steps:

1. Resolve version (flag or interactive), download `talosctl` + `crane` into `bundle/bin/`, verify them against their
   published sha256 files.
2. Build schematic YAML from the profile, `POST https://factory.talos.dev/schematics` → schematic ID.
3. Image list = `talosctl image default` (k8s version applied) + `factory.talos.dev/installer/<id>:<ver>` + extra list.
4. (mode registry|both) `crane pull --platform linux/<arch>` each image → `bundle/images/<id>/` (OCI layout), `bundle/images.txt` (`ref<TAB>oci-dir`).
5. (mode cache|both) `talosctl images cache-create --image-cache-path bundle/image-cache.oci --images=-`.
6. ISO: docker available → fetch `ghcr.io/siderolabs/imager:<ver>` with `crane pull` (honors `--proxy`, the docker daemon
   proxy needs admin) then `docker load`; run `imager iso --image-cache` with extensions/kernel args derived from the
   same `schematic.yaml` as the installer → `bundle/talos-<ver>-cache.iso`. Check the ISO extension list matches the
   schematic, abort otherwise.
   Otherwise download Factory ISO `GET /image/<id>/<ver>/metal-<arch>.iso` (or nocloud for vm).
7. Save `schematic.yaml`, `profile.env` (profile + pinned talosctl/crane/imager versions), extra files, `SHA256SUMS`.

Idempotent: re-running with another profile into the same `--out` adds to it, no duplicate pulls.

### push

| Flag | Default | Notes |
|---|---|---|
| `--registry` | required | `reg.lan:5000` |
| `--registry-prefix` | | e.g. `mirror` → `reg.lan/mirror/ghcr.io/...` (Harbor projects) |
| `--registry-ca` | | CA PEM: used by crane and written to the Talos patch `tls.ca` |
| `--insecure` | | plain HTTP / skip verify (crane `--insecure`, `http://` endpoints) |
| `--registry-user` | | password from `REGISTRY_PASSWORD` env, never a flag |
| `--bundle` | `./bundle` | |

Steps:

1. Verify `SHA256SUMS`, abort on mismatch.
2. `crane auth login` if user given.
3. For each line of `images.txt`: `crane push <tar> <registry>[/<prefix>]/<upstream-registry>/<repo>:<tag>`.
4. Write `bundle/machine-patch.yaml`: one mirror per upstream (`docker.io`, `ghcr.io`, `registry.k8s.io`, `quay.io`,
   `factory.talos.dev`, ...) → `https://<registry>/v2/[<prefix>/]<upstream>`, `overridePath: true`, plus TLS/auth.
   `RegistryMirrorConfig` documents: Talos 1.12 or newer only.

## Registry layout

`ghcr.io/siderolabs/kubelet:v1.36.3` → `reg.lan[/prefix]/ghcr.io/siderolabs/kubelet:v1.36.3`. No manifest rewriting.

## Blog post outline

1. Why airgap + Talos
2. The flow: internet → bundle → transfer → registry / ISO with cache
3. Hardware matrix (CPU / GPU / VM → extensions, extra images)
4. `fetch`
5. Transfer and checksums
6. `push`
7. Machine config patch (mirrors, CA)
8. Booting with the image cache
9. Limits: Secure Boot (own keys), upgrades = new bundle
10. Links: Proxmox/OpenTofu/Talos post, AUR airgap post

## To verify while implementing

- Factory `/versions` and `/schematics` response formats.
- `talosctl image default` vs `images default` naming for the chosen version.
- `imager` flags for extensions (`--system-extension-image` from `ghcr.io/siderolabs/extensions:<ver>` digests), and whether `--privileged` is needed for `iso`.
- Exact mirror document schema for Talos >= 1.12.
