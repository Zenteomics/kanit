workz is one executable. This page lists what it needs from the system, builds it from source and checks that isolated runs work on your machine.

## Requirements

- **Linux on x86-64.** Other systems and architectures are not supported.
- **cgroup v2.** `stat -fc %T /sys/fs/cgroup` prints `cgroup2fs`.
- **A systemd user manager with delegated controllers.** `systemctl --user status` works in your session, and the `cpu`, `memory` and `pids` controllers are delegated to it (see [below](#check-isolation)).
- **Unprivileged user namespaces**, for the run's private network. Most distributions allow them; `sysctl user.max_user_namespaces` prints a number above 0.
- **bash** at `/bin/bash`, `/usr/bin/bash` or `/usr/local/bin/bash`, for rule commands.
- **Rootless Podman**, only for [container rules and services](Containers-and-Services.md).
- **Zig 0.16.0**, to build workz.

Without a systemd user manager or cgroup v2, `workz run --no-isolation` still runs workflows within the budget, but without per-attempt limits, counters or a private network ([Running workflows](Running-Workflows.md#without-isolation)).

## Build

workz reads TOML with [z-toml](https://github.com/eneskemalergin/z-toml) 0.4.1. `build.zig.zon` pins it by URL and hash, so the first build downloads it; nothing else is needed. From the root of a workz checkout:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/workz version
```

```text
workz 0.6.0
```

`ReleaseSafe` keeps Zig's safety checks in the shipped executable. A plain `zig build` gives a Debug build for development, and `zig build test --summary all` runs the unit tests.

Put the executable on your `PATH`, for example:

```sh
install -m 755 zig-out/bin/workz ~/.local/bin/workz
```

The examples in this guide call `workz` and assume it is on your `PATH`. The build also installs `LICENSE` and `THIRD_PARTY.md`, the notice of the z-toml library linked into the binary, in `zig-out/share/doc/workz/`; give them with any copy of the binary you hand on.

## Shell completion

`workz completion bash` prints a completion script for commands, options and the rule names of a workflow. Load it in the current shell, or install it for every new one:

```sh
source <(workz completion bash)
workz completion bash > ~/.local/share/bash-completion/completions/workz
```

## Check isolation

A run starts with `systemd-run --user --scope -p Delegate=yes`, and workz then creates a cgroup for every attempt inside that scope. This needs the user manager to own the `cpu`, `memory` and `pids` controllers:

```sh
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
```

```text
cpu io memory pids
```

If `cpu`, `memory` or `pids` is missing, delegate them to every user manager with a systemd drop-in, then log out and back in:

```sh
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
```

Then try a one-rule workflow in an empty directory:

```sh
mkdir isolation-check && cd isolation-check
printf '[workflow]\nname = "check"\n\n[[rules]]\nname = "hello"\noutput = ["hello.txt"]\nshell = "echo hello > hello.txt"\nmemory = "64M"\n' > workflow.toml
workz run workflow.toml
```

On a terminal the run ends with a short summary that starts with `completed` and names the launch's page; off a terminal it prints `[1/1] completed hello (3 ms)` and a one-line JSON summary with `"status":"completed"`. If it stops with an error instead, [Troubleshooting](Troubleshooting.md#starting-a-run) explains each one.
