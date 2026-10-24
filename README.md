# FreeSWITCH source installer

`install-freeswitch.sh` builds [FreeSWITCH](https://github.com/signalwire/freeswitch) and its core
libraries from source. It also creates a dedicated service account and installs a systemd unit,
so FreeSWITCH starts at boot.

It builds:

| Component  | Source                                   | Installed to            |
|------------|------------------------------------------|-------------------------|
| libks2     | `signalwire/libks` (master)              | `/usr`                  |
| spandsp    | `freeswitch/spandsp` (default branch)    | `/usr/local`            |
| sofia-sip  | `freeswitch/sofia-sip` (default branch)  | `/usr/local`            |
| FreeSWITCH | `signalwire/freeswitch` (`v1.11` branch) | `/usr/local/freeswitch` |

## Requirements

- Debian 13 (trixie) or Ubuntu 24.04 (noble)
- Root access (the script exits if it isn't run as root)
- Internet access, for apt, GitHub and the sound packs
- Several GB of free disk space. The build is CPU-heavy, so expect anywhere from minutes to an hour, depending on core count.

## Quick start

```bash
chmod +x install-freeswitch.sh
sudo ./install-freeswitch.sh
```

When it finishes:

```bash
systemctl status freeswitch
/usr/local/freeswitch/bin/fs_cli
```

## Configuration

Override any of these with environment variables:

| Variable         | Default                 | Description                                         |
|------------------|-------------------------|-----------------------------------------------------|
| `PREFIX`         | `/usr/local/freeswitch` | FreeSWITCH install prefix                           |
| `JOBS`           | `$(nproc)`              | Parallel build jobs                                 |
| `SRC_DIR`        | `/usr/src`              | Where the source trees are cloned                   |
| `FS_BRANCH`      | `v1.11`                 | FreeSWITCH branch or tag. The default is the stable release branch, which gets each new 1.11.x release. Use a tag (e.g. `v1.11.3`) to pin a release. `master` is development code, not the stable release. |
| `INSTALL_SOUNDS` | `1`                     | `1` installs the English sound prompts and music-on-hold. Any other value skips them. |

`sudo` resets the environment, so put the variables after `sudo`:

```bash
sudo FS_BRANCH=v1.11.3 INSTALL_SOUNDS=0 JOBS=4 ./install-freeswitch.sh
```

## What the script does

1. Runs `apt-get update` and a non-interactive `upgrade` that keeps existing config files.
2. Installs the build dependencies (toolchain, autotools/cmake, and the codec, database and scripting dev packages).
3. Clones (or updates) **libks**, then builds it with CMake and installs it into `/usr`.
4. Clones (or updates) **spandsp**, then builds and installs it into `/usr/local`.
5. Clones (or updates) **sofia-sip**, builds and installs it, then checks that it is in the linker cache.
6. Clones (or updates) **FreeSWITCH** at `FS_BRANCH` and bootstraps it. It disables `mod_signalwire` in
   `modules.conf`, then configures with `--prefix=$PREFIX --disable-fhs`, builds and installs.
7. Optionally installs the sound and music-on-hold packs.
8. Creates the `freeswitch` system user and group. It makes them owners of `$PREFIX` and removes all access for other users.
9. Writes `/etc/systemd/system/freeswitch.service`, then enables and (re)starts the service.

## Installed layout

`--disable-fhs` keeps everything under the prefix:

```
/usr/local/freeswitch/
├── bin/        freeswitch, fs_cli, ...
├── conf/       XML configuration (vars.xml, sip_profiles/, dialplan/, ...)
├── db/         SQLite core databases
├── log/        freeswitch.log, CDRs
├── mod/        loadable modules
├── run/        freeswitch.pid
├── sounds/     prompts and music-on-hold
└── ...         recordings/, storage/, scripts/, certs/, ...
```

Source trees stay in `$SRC_DIR` (`/usr/src/{libks,spandsp,sofia-sip,freeswitch}`).

## Managing the service

```bash
sudo systemctl status freeswitch
sudo systemctl restart freeswitch
sudo journalctl -u freeswitch -f
sudo /usr/local/freeswitch/bin/fs_cli          # interactive console
sudo /usr/local/freeswitch/bin/fs_cli -x status
```

To change the daemon flags (default `-nonat`), create `/etc/default/freeswitch`:

```bash
DAEMON_OPTS="-nonat -nosql"
```

## Notes

- **mod_signalwire is disabled.** It needs a SignalWire token, which a self-hosted switch doesn't need.
- **Privileges.** The service starts as root so it can claim real-time CPU and I/O priority. It then drops
  to `freeswitch:freeswitch` (`-u`/`-g`). The tree is mode `o=` (no access for other users), so run `fs_cli`
  as root, or add your user to the `freeswitch` group.
- **Containers and VMs.** `CPUSchedulingPolicy=rr`, `IOSchedulingClass=realtime` and the `LimitRT*` settings
  can stop the service from starting where RT scheduling isn't available. If that happens, comment them out in
  the unit, or add a drop-in with `systemctl edit freeswitch`.
- **Safe to re-run.** Existing clones are fetched and fast-forwarded, the user and group are created only if
  missing, and the service is restarted so it picks up the new build.
- `libnode-dev` is installed but is only needed if you enable `mod_v8`. You can remove it from the
  package list to save space.

## Troubleshooting

- **`sofia-sip did not land in the linker cache`**: check that `/usr/local/lib` is listed in
  `/etc/ld.so.conf.d/` and run `ldconfig`.
- **configure can't find spandsp or sofia-sip**: the script sets
  `PKG_CONFIG_PATH=/usr/local/lib/pkgconfig`. If you run configure by hand, export that variable first.
- **The service fails to start**: check `journalctl -u freeswitch` and `/usr/local/freeswitch/log/freeswitch.log`.
  You can also run it in the foreground for debugging: `sudo /usr/local/freeswitch/bin/freeswitch -u freeswitch -g freeswitch -nonat`.
