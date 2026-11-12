# node-exporter-setup.sh

Sets up the Prometheus node exporter so that the central Prometheus can
scrape it over the tailnet, and only there.

```bash
sudo ./node-exporter-setup.sh            # menu
sudo ./node-exporter-setup.sh --setup    # setup dialogue once
sudo ./node-exporter-setup.sh --status   # state: package, service, bind address, ufw rule
sudo ./node-exporter-setup.sh --test     # fetch /metrics over the tailnet IP
sudo ./node-exporter-setup.sh --uninstall
```

`base-setup.sh` runs it as the monitoring step. The step is skipped
while the server is not in the tailnet.

## What it does

1. **Checks the current state.** It reads the tailnet IP and checks whether
   port 9100 is free (otherwise it suggests another port). It also reports
   the installed package and the ufw state.
2. **Installs the packages.** These are `prometheus-node-exporter` and
   `prometheus-node-exporter-collectors`. The collectors package provides,
   among others, the apt metrics through a systemd timer.
3. **Binds the exporter to the tailnet IP.** It writes
   `/etc/default/prometheus-node-exporter` with
   `--web.listen-address=<tailnet-ip>:9100 --collector.systemd --collector.textfile.directory=/var/lib/prometheus/node-exporter`.
   The package default listens on every interface; the original file is
   kept as `.orig`.
4. **Sets the start order.** A drop-in, `prometheus-node-exporter.service.d/tailnet.conf`,
   makes the exporter start after `tailscaled.service`. `Restart=always` with
   `RestartSec=15` makes it retry until the tailnet IP exists after a boot.
5. **Adds the firewall rule.** `ufw allow in on tailscale0 to any port 9100 proto tcp`,
   optionally limited to the tailnet IP of the Prometheus server. On a
   re-run, the tool replaces its own old rules.
6. **Tests the endpoint.** It fetches `/metrics` over the tailnet IP and
   checks for `node_*`, `node_systemd_unit_state` and `apt_*`.

Alerting happens in Prometheus and Alertmanager, not on the server. Keep
`disk-monitor.sh` as the local fallback with its own mail: it still reports
when the server is cut off from the tailnet.

## Settings

Stored in `node-exporter-setup.conf` next to the script:

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `9100` | Listening port |
| `SCRAPE_FROM` | empty | Tailnet IP of the Prometheus server; empty means the whole tailnet may scrape |
| `EXTRA_ARGS` | empty | Further exporter flags, e.g. `--collector.processes` |

## Presets and batch mode

A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default). A preset is a fixed value: its question is skipped -
interactively and in batch mode - and the tool prints one line instead, e.g.
`Tailnet IP of the Prometheus server ...: 100.64.0.9 (preset)`. A preset wins
over the value stored in `node-exporter-setup.conf`. One that is no valid
answer stops the setup with a message on stderr and exit code 1, before
anything is written.

With `BATCH=1` (set by `base-setup.sh`) `--setup` asks nothing: every
question without a preset takes its default (stored or built-in) and prints
one line with what it took.

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_SCRAPE_FROM` | tailnet IPv4 of the Prometheus server; `-` = the whole tailnet | empty (whole tailnet) |
| `DEFAULT_ALT_PORT` | port used when 9100 is taken by another process | `9101` |

## Prometheus side

```yaml
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['acme-crm-prod01:9100']   # MagicDNS name or tailnet IP
```

## Notes

- **The tailnet IP is written into the configuration.** If the IP ever
  changes, for example after the node is removed from Headscale and joined
  again, `--status` warns about it. Run `--setup` again in that case.
- **Without ufw** the bind to the tailnet IP still keeps the port off the
  public interfaces. The ufw rule is added on the next run after ufw has
  been enabled.
- **Uninstalling** removes the binding, the drop-in and the ufw rule. If you
  keep the packages, the service is stopped, because with the package
  default it would listen on every interface.
- **resource-monitor, net-monitor, tcp-monitor and http-monitor** are largely
  covered by Prometheus once the exporter runs (and, for HTTP/TCP checks, a
  blackbox exporter on the Prometheus side). They stay in the repository for
  servers without central monitoring.
