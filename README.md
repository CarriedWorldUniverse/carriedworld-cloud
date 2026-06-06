# carriedworld-cloud

`carriedworld-cloud` is the Carried World hosting platform: declarative service configs for the platform and dispatch fabric, reconciled onto the dMon k3s cluster.

## Directory Map

- `hosting/` - service definitions, Helm chart inputs, and apply tooling for hosted workloads.
- `clusters/` - cluster-specific manifests for dMon.
- `bootstrap/` - bootstrap resources that install or schedule platform reconciliation.
- `docs/` - architecture notes, plans, and runbooks.
