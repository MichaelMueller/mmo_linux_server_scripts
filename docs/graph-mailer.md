# graph-mailer.sh — Microsoft 365 mailer through Graph

Sends mail through the Microsoft Graph API and hooks itself in as a `sendmail`
replacement. Meant for environments in which Exchange Online no longer allows
SMTP AUTH — the classic route through msmtp then stops working, and Graph is the
intended replacement.

> **An alternative to `mail-setup.sh`, not an addition.** Both want to be
> `/usr/sbin/sendmail`. You pick one.

## Requirements

- root rights, `curl`, `base64` (installed when needed)
- an **app registration in Entra ID** with:
  - an application ID (client) and a directory ID (tenant)
  - a client secret
  - the **application permission** `Mail.Send` (not "delegated"), with admin
    consent
- a mailbox to send from (UPN, e.g. `server@company.com`)

> `Mail.Send` as an application permission allows sending from **any** mailbox
> in the tenant. If you want to narrow that down, set up an application access
> policy (`New-ApplicationAccessPolicy`) in Exchange Online for this one
> mailbox. That is the part you should not forget.

## Usage

```bash
sudo ./graph-mailer.sh              # menu
sudo ./graph-mailer.sh --test       # test mail
sudo ./graph-mailer.sh --status     # configuration and integration
sudo ./graph-mailer.sh --uninstall  # remove
./graph-mailer.sh --sendmail -t     # sendmail-compatible, mail from stdin
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit credentials |
| 2 | Send a test mail |
| 3 | Check the token (fetches a fresh one and shows errors in plain text) |
| 4 | Show status |
| 5 | Switch the sendmail integration on or off |
| 6 | Show the log |
| 7 | Uninstall |
| 8 | Quit |

## How sending works

1. **Fetch a token** — `client_credentials` against
   `login.microsoftonline.com/<tenant>/oauth2/v2.0/token`, scope
   `https://graph.microsoft.com/.default`. The token is cached in
   `/run/graph-mailer/token` and renewed 60 seconds before it expires. `/run`
   lives in tmpfs, so a reboot clears it by itself.
2. **Hand the mail over as MIME** — `POST /v1.0/users/<sender>/sendMail` with
   `Content-Type: text/plain` and the base64-encoded RFC 822 message in the
   body. HTTP 202 means accepted.

Why MIME instead of JSON? For a sendmail replacement it is the only robust way:
attachments, encodings, `Content-Type`, custom headers and UTF-8 subjects pass
through unchanged. With the JSON variant you would have to take the mail apart
and rebuild it — and every detail you overlook in the process is lost.

Limit: Graph accepts up to 4 MB this way.

## sendmail integration

```
/usr/local/sbin/graph-sendmail   -> exec graph-mailer.sh --sendmail "$@"
/usr/sbin/sendmail               -> symlink to graph-sendmail
```

An existing `/usr/sbin/sendmail` (from `msmtp-mta` or Postfix, say) is moved
aside with **`dpkg-divert --add --rename`** instead of being overwritten. That is
cleanly reversible, and a package update does not put the file back on top.

That way `mail`, cron mail and everything else that calls `sendmail` goes
through Graph as well.

### Supported sendmail options

| Option | Behaviour |
|---|---|
| `-t` | Recipients are in the headers (the standard case) |
| `-f`, `-r` | Envelope sender; it is logged, but Graph always sends from the configured mailbox |
| `-i`, `-oi`, `-oem`, … | are swallowed |
| Arguments without `-` | recipients |

Missing headers are added: `From`, `Date`, `Subject`, `Message-ID`,
`MIME-Version`, `Content-Type` and — when recipients come as arguments — `To`.
If the input does not start with a header, all of it counts as the body, just
like with the real sendmail.

Exit codes: `0` success, `75` (EX_TEMPFAIL) on a send error, `77` when not
called as root, `78` when not set up.

### Only root can send

The configuration is `0600`, and the script is not setuid. So a normal user
cannot send through Graph. For a server whose mail comes from cron and the
monitoring tools that is exactly right — and msmtp with a `0600 /etc/msmtprc`
behaves the same way.

## The client secret

By default in clear text in `/etc/graph-mailer.conf` (`0600`, root).
Alternatively a command supplies it:

```sh
CLIENT_SECRET=""
CLIENT_SECRET_CMD="cat /root/.graph-secret"
```

Neither the secret nor the token ever appears on the command line — both go
through a curl config on stdin, so that nothing lands in the process list.

Certificate-based authentication would be safer than a secret, but it requires
self-signed JWT assertions; this script does not do that. If you need it, you
are better served by a ready-made client.

**Client secrets expire** (in Entra ID usually after 6, 12 or 24 months). After
that, sending fails with `AADSTS7000215` or `AADSTS700082`. It is worth noting
the expiry date down.

## Files created

| Path | Contents |
|---|---|
| `/etc/graph-mailer.conf` | tenant, client, secret, sender (`0600`) |
| `/usr/local/sbin/graph-sendmail` | shim for the sendmail call |
| `/usr/sbin/sendmail` | symlink, the original moved to `.distrib` by dpkg-divert |
| `/run/graph-mailer/token` | cached token (`0600`, tmpfs) |
| `/var/log/graph-mailer.log` | send log (`0600`) |

## State and data

**Its own state, unavoidably:** the "service" is the Graph API, and there is
nothing locally that could hold the credentials. They live in
`/etc/graph-mailer.conf` (`0600`), the token in tmpfs under
`/run/graph-mailer/token` — so a reboot clears it away by itself.

The tool still gets along with an MTA that is already set up:
`/usr/sbin/sendmail` is **redirected rather than overwritten** through
`dpkg-divert`, the original stays as `.distrib` and comes back on uninstall. An
existing `/etc/msmtprc` is not touched — you can switch back and forth between
the two mailers at any time (menu item 5 here, menu item 1 in `mail-setup.sh`).

## Uninstall

Undoes the sendmail redirection (`dpkg-divert --remove --rename`), deletes the
shim, the configuration and the token, and asks separately about the log.
Beforehand a backup is written to
`/root/graph-mailer-uninstall-<time>.tar.gz` — **it contains the client
secret**, the file is `0600`.

If `/etc/msmtprc` is still present afterwards, that is pointed out:
`mail-setup.sh` can take sending over again.

The app registration in Entra ID stays and has to be deleted there.

## Troubleshooting

| Message / symptom | Cause |
|---|---|
| `AADSTS7000215: Invalid client secret` | The secret is wrong or expired |
| `AADSTS700016: Application not found` | Wrong client ID, or the wrong tenant |
| `AADSTS900023: Specified tenant identifier is not valid` | Typo in the tenant ID |
| HTTP 403 `ErrorAccessDenied` | `Mail.Send` is missing, is delegated instead of application, or the admin consent is missing |
| HTTP 404 `ResourceNotFound` | The sender mailbox does not exist (wrong UPN), or it is not an Exchange mailbox |
| HTTP 403 despite the correct permission | An application access policy in Exchange locks this mailbox out |
| HTTP 413 | The message is larger than 4 MB |
| `only root can send` | A service is trying to send as its own user — see above |
| The mail arrives but is not in "Sent" | With MIME sending the mailbox decides; there is no switch for that in this variant |
| Nothing works after `apt install` of an MTA | The package reset `/usr/sbin/sendmail`; menu item 5 hooks the redirection back in |
