# Troubleshooting

## Worker does not show in `ray status`

Check Tailscale:

```bash
ssh root@WORKER_PUBLIC_IP 'tailscale status && tailscale ip -4'
```

Check Ray service:

```bash
ssh root@WORKER_PUBLIC_IP 'journalctl -u ray-worker -n 200 --no-pager'
```

Check head reachability from worker:

```bash
ssh root@WORKER_PUBLIC_IP 'nc -vz $RAY_HEAD_TS_IP 6379'
```

## Tune trials hang

Common causes:

- Trial asks for more CPUs than available.
- LightGBM/XGBoost thread count oversubscribes CPUs.
- Data path missing on workers.
- Ray object store memory too large for 2 GB workers.

## Memory problems on 2 GB VMs

Use:

```yaml
cpus_per_trial: 1
n_rows: 5000
n_features: 20
```

This local lab is for infrastructure validation, not real HPO throughput.

## DigitalOcean apply fails from resource limit

Run fewer workers:

```bash
make do-up WORKER_COUNT=1
```

Then scale up gradually.
