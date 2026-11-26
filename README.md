# k8s-log-router

Sends the logs of chosen Kubernetes workloads to a
[Samma SIEM](https://github.com/samma-io/siem) detection lane. You label a pod
and its logs reach the matching detection engine.

```
pod label samma.io/detection: traefik
  → node log shipper (fluent-bit or a Vector agent)
  → k8s-log-router (allowlist)
  → NATS samma.logs.svc.traefik (stream SIEM_SERVICES)
  → detection-engine (ENGINE_LOG_SOURCE=traefik) → samma.alerts.traefik
```

The router is a single [Vector](https://vector.dev) Deployment. It has no
Kubernetes API access and no host mounts: shippers send it records that already
carry pod metadata, and it forwards only the ones that are allowed.

## Opting in a workload

Label the **pod template** (`spec.template.metadata.labels`). Labels on the
Deployment's own metadata do not travel with the logs.

```yaml
spec:
  template:
    metadata:
      labels:
        samma.io/detection: traefik
```

## The allowlist

A label is only a request. A record is forwarded when its lane is listed in
`lanes` at the top of [`router/k8s-router.vrl`](router/k8s-router.vrl) **and**
the pod runs in a namespace allowed for that lane:

```
lanes = {
  "traefik": ["traefik"]
}
```

Everything else is dropped. Without this, anyone allowed to label a pod could
write into any lane (for example `wazuh`) and forge or flood its alerts.

To add a lane, add one line, apply, and run a detection engine for it with
`ENGINE_NATS_STREAM=SIEM_SERVICES` and `ENGINE_NATS_SUBJECT=samma.logs.svc.<lane>`,
plus a durable consumer `detection-engine-<lane>` on that subject.

## Records

- **A JSON log line** is parsed, and its fields are kept at the top level, so
  rules match the application's own names (Traefik: `RequestPath`,
  `DownstreamStatus`, `request_User-Agent`, ...).
- **A plain line** is kept as `message`.
- **The envelope is written last**, so a log line cannot forge it:

| Field | Value |
|---|---|
| `source` | the lane, also the NATS subject suffix |
| `feed` | `k8s` |
| `event_time` | the shipper's timestamp, UTC, millisecond precision |
| `k8s` | `{namespace, pod, container, node}` |
| `search_text` | the line, at most 2000 characters |

## Install

You need a Samma SIEM with JetStream NATS in namespace `samma`, and a stream
covering `samma.logs.svc.>`:

```bash
nats stream add SIEM_SERVICES --subjects 'samma.logs.svc.>' --max-age 24h \
  --max-bytes 100MiB --storage file --retention limits --discard old --replicas 1 --defaults
```

Then apply the router at a pinned commit:

```bash
kubectl apply -k "github.com/samma-io/k8s-log-router?ref=<commit>"
```

The ConfigMap name carries a content hash, so a config change rolls the pod.
For another namespace or NATS address, use a kustomize overlay.

## Connecting shippers

The Service `k8s-log-router` (ClusterIP) listens on two ports:

| Port | Protocol | For |
|---|---|---|
| 24224 | Fluent forward | fluent-bit with the kubernetes filter (`Labels On`, the default) |
| 6000 | Vector native | a Vector agent with the `kubernetes_logs` source |

Unlabelled records are dropped cheaply, so a shipper can send everything.

**fluent-bit:** add an output.

```
[OUTPUT]
    Name          forward
    Match         kube.*
    Host          k8s-log-router.samma.svc.cluster.local
    Port          24224
    Retry_Limit   5
```

fluent-bit's service account must be able to get and list pods and namespaces,
or records arrive without the `kubernetes` metadata and every one is dropped.

**Vector agent:**

```yaml
sources:
  pods:
    type: kubernetes_logs
    extra_label_selector: samma.io/detection
sinks:
  router:
    type: vector
    inputs: [pods]
    address: k8s-log-router.samma.svc:6000
```

## Testing

`hack/test.sh` runs the VRL unit tests in
[`router/tests/k8s-router.yaml`](router/tests/k8s-router.yaml) and checks the
kustomize build, in Docker, with no cluster. CI runs the same checks, plus
gitleaks.

Check a live install:

```bash
nats stream info SIEM_SERVICES
nats sub 'samma.logs.svc.>'
```

## API server audit log (`audit/`)

A second, separate component: `k8s-audit-collector` tails the Kubernetes API
server audit log on control-plane nodes and publishes the events to
`samma.logs.k8s` for the `k8s` detection lane.

```
kube-apiserver audit log (control-plane node, hostPath, read-only)
  → k8s-audit-collector DaemonSet (filter VRL)
  → NATS samma.logs.k8s (stream SIEM_AUDIT)
  → detection-engine (ENGINE_LOG_SOURCE=k8s) → samma.alerts.k8s
```

The raw log is several MiB a minute even on a small cluster, almost all of it
controllers reading and renewing their own state. [`audit/k8s-audit.vrl`](audit/k8s-audit.vrl)
keeps what a rule can use, well under 1% of the bytes:

- **Always kept:** 401 and 403 responses, and anything by `system:anonymous`.
- **Dropped:** stages other than `ResponseComplete`; nodes and control-plane
  components; leases, access and token reviews; event writes; status
  subresource writes; `watch`; `get`/`list` except on secrets and on
  `pods/exec`, `attach`, `portforward`, `log` and `serviceaccounts/token`;
  ConfigMap writes by service accounts outside `kube-system`; and the `noisy`
  list at the top of the VRL (Argo CD Applications, ARC runner sets).
- **Bodies:** `responseObject` is always removed. `requestObject` is kept only
  for pods, services and RBAC objects, so a Secret or ConfigMap body never
  leaves the node.

Each record is the audit event unchanged, plus `source: k8s`, `feed: audit`,
`event_time` and a one-line `search_text`.

Install (the stream first; size it for about 20 MB a day per small cluster):

```bash
nats stream add SIEM_AUDIT --subjects samma.logs.k8s --max-age 3d \
  --max-bytes 64MiB --storage file --retention limits --discard old --replicas 1 --defaults
kubectl apply -k 'github.com/samma-io/k8s-log-router/audit?ref=<commit>'
```

It runs as uid 65534 because Talos writes the audit log as `nobody`, mode
0600. On kubeadm, point the hostPath and `AUDIT_LOG` at `--audit-log-path`.
Its checkpoint lives in an emptyDir and it starts at the end of the file, so
a restart never replays old events, and events written while the pod is
down are missed.
