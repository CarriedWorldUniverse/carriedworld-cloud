# Bootstrap

`bootstrap/` holds out-of-band cluster infrastructure that is applied once by
hand. These resources are not managed by the reconcile loop.

Current contents:

- `hosting-reconcile-cronjob.yaml`: the periodic hosting reconcile CronJob, plus
  its `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`.
- `hosting-git-token`: the secret required by the CronJob so it can clone this
  repository before running the reconcile script.
