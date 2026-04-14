# Auth worker map

Current auth-side long-lived worker:

- `interface.ex`
  - registers the auth service and resolves `data_service`

Business logic such as token issuance/verification remains in `AuthServer.AuthWorker`
at the parent directory level because it is a domain service rather than a
cluster-facing runtime process.
