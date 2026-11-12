# base-tools.sh — base tools and shell comfort

Installs the packages you would install first on a fresh server anyway,
creates system-wide defaults for the shell, vim, nano and screen, and sets
the system basics: time synchronisation (NTP) and timezone, locale (UTF-8),
conservative kernel hardening (sysctl) and a swap file on small machines.

## Requirements

- Debian or Ubuntu (apt)
- root rights

## Usage

```bash
sudo ./base-tools.sh              # menu
sudo ./base-tools.sh --setup      # packages, defaults and time in one go
sudo ./base-tools.sh --time       # only time synchronisation and timezone
sudo ./base-tools.sh --locale     # only the locale
sudo ./base-tools.sh --sysctl     # only the kernel hardening
sudo ./base-tools.sh --swap       # only the swap file
sudo ./base-tools.sh --status     # shows what is installed and set
sudo ./base-tools.sh --uninstall  # remove the defaults
```

## Presets and batch mode

**A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default).** A set, non-empty variable is a fixed value (a
*preset*) — interactively as well as in batch mode the question is skipped and
one line shows what was taken, e.g. `Editors (nano vim)? -> no (preset)` or
`Timezone (e.g. Europe/Berlin, UTC): Europe/Berlin (preset)`. Every preset is
checked before anything is written: an invalid one (unknown timezone, a
yes/no value that is neither, a locale that is not UTF-8, bad `DEFAULT_SWAP`)
is an error on stderr with a non-zero exit code, and nothing is changed.

With `BATCH=1` (set by `base-setup.sh`) the remaining questions are not asked
either: they take their built-in default and print what they took.

```bash
sudo DEFAULT_TIMEZONE=Europe/Berlin DEFAULT_SWAP=no ./base-tools.sh --setup          # asks the rest
sudo BATCH=1 DEFAULT_TIMEZONE=Europe/Berlin DEFAULT_SWAP=no ./base-tools.sh --setup  # asks nothing
```

| Variable | Values | Built-in default | Question |
|---|---|---|---|
| `DEFAULT_PKG_EDITORS` | `Y` / `N` | `Y` | Editors |
| `DEFAULT_PKG_SESSIONS` | `Y` / `N` | `Y` | Terminal sessions |
| `DEFAULT_PKG_TOOLS` | `Y` / `N` | `Y` | Tools |
| `DEFAULT_PKG_NET` | `Y` / `N` | `N` | Network diagnostics |
| `DEFAULT_TIME_SETUP` | `Y` / `N` | `Y` | Set up time sync and timezone? |
| `DEFAULT_TIMEZONE` | e.g. `Europe/Berlin` | the current one | Timezone |
| `DEFAULT_NTP_SERVERS` | server names | the distribution's pool | (not asked) |
| `DEFAULT_LOCALE_SETUP` | `Y` / `N` | `Y` | Set the locale? |
| `DEFAULT_LANG` | a locale | `en_US.UTF-8` | System locale (LANG) |
| `DEFAULT_LOCALES` | locales, `-` = none | `de_DE.UTF-8` | Further locales |
| `DEFAULT_SYSCTL` | `Y` / `N` | `Y` | Apply the kernel hardening? |
| `DEFAULT_SWAP` | `auto` / `no` / size in MB | `auto` | Create /swapfile? and its size |

Yes/no values: `Y`, `yes`, `j`, `ja`, `1`, `true` or `N`, `no`, `nein`, `0`,
`false` (any case); anything else is an error. `DEFAULT_SWAP` answers both
swap questions: `auto` applies the usual rule (yes below 8 GB RAM, size from
the RAM), `no` declines, a number creates a swap file of that size.
`DEFAULT_LOCALES=-` means no further locales. `DEFAULT_NTP_SERVERS` is never
asked; when set it is written as described under *Time*.

## Menu

| Item | Effect |
|---|---|
| 1 | Set up everything: package selection, the defaults, the time |
| 2 | Install packages only |
| 3 | Write the defaults only |
| 4 | Time: synchronisation and timezone |
| 5 | Locale (UTF-8, further languages) |
| 6 | Kernel hardening (sysctl) |
| 7 | Swap file |
| 8 | Status: packages, files, time, locale, hardening, swap |
| 9 | Uninstall |
| q | Quit |

## Time

A synchronised clock is not optional: TLS certificates are checked against it,
TOTP codes are rejected when it drifts, logs of several machines can only be
put side by side with it, and cron jobs run by it. The timezone decides when
"03:00" in a cron job is — the update and reboot windows of auto-update
included.

- **Synchronisation:** if chrony or ntp keeps the clock already, that stays.
  Otherwise `systemd-timesyncd` is installed and enabled with the
  distribution's NTP pool; the tool then waits up to 30 seconds for the first
  sync and says so if it does not happen (outgoing 123/udp blocked?).
- **Timezone:** asked, the current one is the default. Setting it restarts
  cron, which reads the timezone only when it starts.
- **Container:** the clock comes from the host — only the timezone is set.

Presets from a caller: `DEFAULT_TIMEZONE` (e.g. `Europe/Berlin`),
`DEFAULT_NTP_SERVERS` (written to
`/etc/systemd/timesyncd.conf.d/50-base-tools.conf`).

## Locale

**UTF-8 is what matters**: with the POSIX/C locale, umlauts in file names,
logs and scripts are mangled. The system language stays English
(`LANG=en_US.UTF-8`) - error messages can be searched as they are, and the
tools parse English output. Further locales (default `de_DE.UTF-8`) are
generated so that applications can use German date formats, the decimal comma
and sorting with umlauts. Setting them system-wide would break scripts that
expect `1.5` instead of `1,5`. Takes effect for new logins.
Presets from a caller: `DEFAULT_LANG`, `DEFAULT_LOCALES`.

## Kernel hardening

`/etc/sysctl.d/90-base-tools-hardening.conf`, conservative values that break
nothing with Docker or Tailscale: no kernel addresses and no kernel log for
ordinary users, no unprivileged BPF, no core dumps of setuid programs, no ICMP
redirects and no source routing, SYN cookies. **Forwarding is not touched**
(Docker and Tailscale need it), and the reverse-path filter is *loose* (2) —
*strict* (1) breaks Tailscale's routing. Keys a kernel does not have are
skipped (`-` prefix). Not in containers (they share the host kernel). The
uninstall removes the file.

## Swap

Small VMs without swap: one memory spike and the OOM killer stops a service. If
no swap is active, `/swapfile` is offered (default yes below 8 GB RAM; size RAM,
at least 2 GB, at most 4 GB) with `vm.swappiness = 10` - used only in an
emergency. Not on btrfs (needs `btrfs filesystem mkswapfile`), not in
containers. `DEFAULT_SWAP` (`auto`, `no` or a size in MB) presets the answer.

## Packages

| Group | Packages | Default |
|---|---|---|
| **Base** | `git ca-certificates` | **always, no question asked** |
| Editors | `nano vim` | yes |
| Terminal sessions | `screen tmux` | yes |
| Tools | `htop curl wget unzip rsync tree ncdu bash-completion` | yes |
| Network diagnostics | `dnsutils net-tools mtr-tiny` | no |

`git` and `ca-certificates` cannot be deselected: without them you do not get
far on a server, every `https` needs `ca-certificates`, and the git updater
requires git. For the same reason they are not in the `apt purge` line the
uninstall prints.

Installation happens **package by package**, not in one call: a package name
that does not exist on the distribution at hand therefore does not abort the
whole run, it is only reported. Packages that are already installed are
skipped.

## Defaults

| File | Contents | Form |
|---|---|---|
| `/etc/profile.d/zz-base-tools.sh` | colours, aliases, history, prompt | own file |
| `/etc/bash.bashrc` | loads the file above for non-login shells too | marked block |
| `/etc/vim/vimrc.local` | line numbers, search, 4-space indent, `set mouse=` | own file |
| `/etc/nanorc` | line numbers, tabs, syntax includes | marked block |
| `/etc/screenrc` | scrollback 10000, status line, no start banner | marked block |

Among other things, the shell file sets:

```sh
alias ll='ls -alFh'              HISTSIZE=5000
alias grep='grep --color=auto'   HISTCONTROL=ignoreboth
LESS='-R'                        HISTTIMEFORMAT='%F %T  '
PS1: root red, normal user green, path blue
```

It bails out immediately if the shell is not interactive or not bash —
`/etc/profile.d/*.sh` is read by `dash` as well.

### Why a reference from /etc/bash.bashrc?

`/etc/profile.d` is only read by a **login** shell. But `ssh host command`, `su`
and screen start non-login shells and would otherwise get none of the settings.
`/etc/bash.bashrc` is read by interactive non-login shells, which is why the
reference sits there.

### Why the prompt is set from PROMPT_COMMAND

Because `~/.bashrc` always gets the last word, and Debian's own `~/.bashrc`
sets `PS1`, `HISTSIZE` and the `ll`/`la`/`l` aliases itself — for root as well:

```
login shell:        /etc/profile -> /etc/profile.d/*  -> ~/.profile -> ~/.bashrc
interactive shell:  /etc/bash.bashrc                  -> ~/.bashrc
```

In both orders `~/.bashrc` comes last, so a `PS1` assigned in
`/etc/profile.d/zz-base-tools.sh` is overwritten a moment later. On a stock
Ubuntu — which is every machine that has not had its `~/.bashrc` edited — the
coloured prompt would simply never appear.

So the handful of settings that collide are applied **once more from
`PROMPT_COMMAND`**, which bash runs just before drawing the first prompt, when
every rc file has had its say. The hook then takes itself out of
`PROMPT_COMMAND` again, so:

- your own `PS1=…` afterwards is not fought over — it sticks,
- a `PROMPT_COMMAND` some other tool already set keeps running,
- sourcing the file twice does not register the hook twice.

Everything that does *not* collide with `~/.bashrc` (`dircolors`, the
`grep`/`df`/`du`/`..` aliases, `LESS`, the history format) is still set
directly, the plain way.

### Why `set mouse=` in vim?

From vim 8.2 on, the mouse is active by default. Selecting with the mouse then
puts vim into visual mode, and copying through the terminal stops working.
`set mouse=` restores the old behaviour.

## Foreign files

Nothing is overwritten blindly:

- In `/etc/bash.bashrc`, `/etc/nanorc` and `/etc/screenrc` the tool's own
  content sits between `# >>> base-tools >>>` and `# <<< base-tools <<<`.
  Everything outside stays untouched, and a repeated run only replaces the
  block.
- An existing `/etc/vim/vimrc.local` that did not come from here is backed up to
  `/etc/vim/vimrc.local.orig`.

## State and data

Everything lives **on the system side**, nothing next to the script — there is
not even a configuration file, the chosen options go straight into the files
that are created.

In `/etc/nanorc`, `/etc/screenrc` and `/etc/bash.bashrc` the tool's content sits
in a marker block; foreign content in the same files stays untouched and a
repeated run only replaces the block. `/etc/profile.d/zz-base-tools.sh` and
`/etc/vim/vimrc.local` belong to the tool alone — a `vimrc.local` found in place
is backed up to `.orig` and restored on uninstall.

That way the tool can be put on an already configured system at any time and
withdrawn again without a trace.

## Uninstall

Removes `/etc/profile.d/zz-base-tools.sh`, cuts the marked blocks out again and
restores `vimrc.local` from the `.orig` backup. Files that did not exist before
(typically `/etc/screenrc`) and would be empty after the removal are deleted. A
hand-written `vimrc.local` that did not come from this tool stays in place.

A backup is written to `/root/base-tools-uninstall-<time>.tar.gz` beforehand.

**Packages are not removed.** Taking nano and vim away from a server does more
damage than it cleans up. The matching command is printed:

```bash
apt purge nano vim screen tmux htop curl wget unzip rsync tree ncdu \
    bash-completion dnsutils net-tools mtr-tiny
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Colours missing in the running shell | The settings only take effect in a new session. Right now: `. /etc/profile.d/zz-base-tools.sh` |
| Prompt still uncoloured in a new session | Check that the file ends with the `_bt_first_prompt` hook (`tail /etc/profile.d/zz-base-tools.sh`). Without it, the `PS1` is overwritten by `~/.bashrc` — that was the behaviour before 2.2.0; re-run menu item 3 to rewrite the file |
| Own `PS1` from `~/.bashrc` is ignored | Intended: the hook applies its prompt after `~/.bashrc`. Set your prompt from `PROMPT_COMMAND` instead, or drop the prompt block from `/etc/profile.d/zz-base-tools.sh` |
| Colours missing with `ssh host command` | Deliberate: the file bails out for non-interactive shells |
| nano complains about `include` | `/usr/share/nano` is missing. The line is only written if the directory exists — a nano installed afterwards needs another run of menu item 3 |
| Prompt without colour after `su` | `su` without `-` keeps the old environment. Use `su -` |
