# base-tools.sh — base tools and shell comfort

Installs the packages you would install first on a fresh server anyway, and
creates system-wide defaults for the shell, vim, nano and screen.

## Requirements

- Debian or Ubuntu (apt)
- root rights

## Usage

```bash
sudo ./base-tools.sh              # menu
sudo ./base-tools.sh --status     # shows what is installed and set
sudo ./base-tools.sh --uninstall  # remove the defaults
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up everything: package selection and then all the defaults |
| 2 | Install packages only |
| 3 | Write the defaults only |
| 4 | Status: a checklist of packages and files |
| 5 | Uninstall |
| 6 | Quit |

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
| Colours missing with `ssh host command` | Deliberate: the file bails out for non-interactive shells |
| nano complains about `include` | `/usr/share/nano` is missing. The line is only written if the directory exists — a nano installed afterwards needs another run of menu item 3 |
| Prompt without colour after `su` | `su` without `-` keeps the old environment. Use `su -` |
