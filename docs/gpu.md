# GPUs

| Host | Card | Used by | Driver |
|---|---|---|---|
| skynet | Quadro P2200 | Plex (CT 103): hardware transcoding | NVIDIA `.run` installer, 580.178.04, built by DKMS |
| little-skynet | Quadro P620 | Nothing yet | None (removed) |

## skynet: Plex in an unprivileged container

The driver runs on the host. The container gets the device files plus a userspace copy of the
same driver's libraries. No GPU passthrough to a VM, so the card stays usable by the host.

**Host side**

- The kernel module comes from NVIDIA's `.run` installer (installed 2026-09-12, log in
  `/var/log/nvidia-installer.log`, `nvidia-uninstall` to remove it), registered with **DKMS**, so
  it's rebuilt for every new Proxmox kernel. `dkms status` lists one line per kernel.
- apt never touches this driver. It changes only when the `.run` installer runs again.
- Check: `nvidia-smi -L` lists `Quadro P2200`.

**Container side (CT 103, Ubuntu 24.04)**

- The device files are passed in with Proxmox device entries, owned by group `video` (gid 44)
  inside the container:

  ```
  dev0: /dev/nvidia0,gid=44
  dev1: /dev/nvidiactl,gid=44
  dev2: /dev/nvidia-uvm,gid=44
  dev3: /dev/nvidia-uvm-tools,gid=44
  dev4: /dev/nvidia-caps/nvidia-cap1,gid=44
  dev5: /dev/nvidia-caps/nvidia-cap2,gid=44
  ```

- The libraries come from NVIDIA's CUDA apt repo (`.../cuda/repos/ubuntu2404/...`), with **no
  kernel module** inside the container. They're the six `*-580` packages, **held** at the host
  driver's version:
  `libnvidia-cfg1-580 libnvidia-compute-580 libnvidia-decode-580 libnvidia-encode-580 libnvidia-gpucomp-580 nvidia-utils-580`.
- Plex: Settings → Transcoder → "Use hardware acceleration when available" (needs Plex Pass).

**The rule: the container's libraries must be exactly the host driver's version.** If they differ,
`nvidia-smi` inside the container fails with `Driver/library version mismatch`, and Plex silently
transcodes on the CPU. The `plex_gpu` health check alerts within about 10 minutes.

### Checking it works

```bash
nvidia-smi -L                               # host: the card
pct exec 103 -- nvidia-smi -L               # container: the same card, no error
pct exec 103 -- apt-mark showhold           # the six packages
pct exec 103 -- nvidia-smi                  # while something transcodes: "Plex Transcoder" listed
```

In Plex: the activity icon → Dashboard → Now Playing → the stream's video line says
`Transcode (hw)`. Force a transcode by picking a lower quality in the player.

### Upgrading the driver (both sides, on purpose)

1. Pick a version that's both on NVIDIA's site as a `.run` file **and** in the CUDA repo for
   Ubuntu 24.04 (`pct exec 103 -- apt-cache policy libnvidia-compute-580`).
2. Host: stop Plex (`pct stop 103`), run the new `.run` installer with `--dkms`, and check
   `dkms status` lists the new version for the running kernel and `nvidia-smi -L` works.
3. Container: `apt-mark unhold`, install all six packages at the matching version
   (`apt-get install <pkg>=<version>-1ubuntu1 ...`), `apt-mark hold` them again.
4. Start CT 103 and run the checks above.

### Kernel upgrades

Proxmox updates bring new kernels, and DKMS builds the module for each one. If that build fails,
the next reboot comes up without the module and Plex loses the GPU. `patch-hosts` checks this:
its summary ends with `DKMS MODULE MISSING for <kernel>: nvidia. DO NOT REBOOT` if the build
didn't happen. Then run `dkms autoinstall -k <kernel>` and read the error (usually missing
`proxmox-headers-<kernel>`). To fall back to the working kernel instead:
`proxmox-boot-tool kernel pin <old kernel>`.

## Incident: Plex on the CPU since 2026-11-21

| When | What |
|---|---|
| 2026-11-21 | A routine `apt upgrade` in CT 103 moved the six libraries from 580.178.04 to 580.196.07 (a newer version in NVIDIA's repo). The host stayed at 580.178.04. Plex started transcoding on the CPU. Nothing noticed |
| 2026-11-24 | After patching and rebooting skynet, the post-reboot check (`pct exec 103 -- nvidia-smi -L`) failed: `Driver/library version mismatch`, `NVML library version: 580.196` |
| 2026-11-25 | Found how each side is installed (host: `.run`; container: apt). Downgraded the container to `580.178.04-1ubuntu1` (simulated first with `apt-get install -s`), held the six packages, restarted Plex. Verified: `nvidia-smi` in the container, and Plex shows `Transcode (hw)` for decode and encode |

**Root cause:** the two halves of the driver are installed by different tools. The host's `.run`
install is invisible to apt, so the container's apt upgraded freely.
**Fix:** hold the container side, upgrade both together.
**Still missing:** monitoring. A check that `nvidia-smi` works in CT 103 would have caught this
on day one. Now there is one: `health-check` runs `pct exec 103 -- nvidia-smi -L` every 5 minutes and
alerts after two failures in a row ([monitoring.md](monitoring.md#health-checks-health-check)).

## little-skynet: Quadro P620, unused

- 2026-02: Debian's `nvidia-driver` (535, later 550) was installed.
- 2026-06-10: removed on purpose (`apt remove nvidia-driver nvidia-kernel-dkms`, then
  `apt autoremove`). 25 packages stayed behind, including a `nvidia-persistenced` unit that failed
  on every boot, showing up in `systemctl --failed`.
- 2026-11-25: all of it purged (`dpkg -l | grep -ci nvidia` is 0), no failed units.
- Before reusing the card: little-skynet has a `vfio.conf` from an earlier passthrough attempt,
  which names PCI addresses instead of vendor:device IDs. Check it isn't claiming the card.
- Idea for it: Immich's machine learning or video transcoding.
