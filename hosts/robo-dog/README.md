# hosts/robo-dog

Host-level (non-k8s) systemd units for `robo-dog` (the GB10 inference node,
tailnet 100.92.111.3). Not managed by k3s or Argo/hosting reconcile -- these
run directly on the box via systemd and are tracked here for reference and
disaster recovery only. Applying a change here means manually copying the
file to `/etc/systemd/system/` on robo-dog and running
`sudo systemctl daemon-reload && sudo systemctl restart <unit>` -- nothing
auto-syncs this directory to the host.

## ds4-server.service

The `ds4` (DwarfStar) model server, serving `deepseek-v4-flash` /
`deepseek-v4-pro` on `:8000`. As of 2026-08-02, running the GA-0731 MXFP4
streamed-cache config (`--ssd-streaming-cache-experts 75GB`, `--ctx 32768`)
per `research/gb10/MEASUREMENTS.md` commit `a335048` in the `ds4` repo
(`~/src/ds4` on robo-dog) -- see that doc's "PRODUCTION CONFIG BLOCK" for the
full quality/throughput rationale. The prior production config (resident
IQ2XXS quant) is documented in-line in the unit file's rollback comment; the
IQ2 gguf is kept on disk specifically so reverting is a one-line `ExecStart`
edit, no re-download.
