# JIT Infra - Flows

Diagrams for [jit-infra-poc.md](./jit-infra-poc.md). Mermaid, so they render in GitHub
and diff as text.

VS Code needs the *Markdown Preview Mermaid Support* extension; the built-in preview
does not render Mermaid.

**Keep these current.** The claim state machine is the novel logic in this design - if
it changes and the diagram does not, the diagram becomes actively misleading. Update it
in the same step that changes the behaviour.

---

## 1. Create - annotation to running infra

```mermaid
sequenceDiagram
    autonumber
    actor T as Tenant
    participant K as kube-apiserver
    participant C as jit-controller
    participant R as jit-runner
    participant TF as OpenTofu
    participant D as Docker daemon

    T->>K: apply Deployment (jit.infra/redis)
    K-->>C: watch: Deployment created
    C->>C: claim name = {ns}-redis
    C->>K: create InfraClaim (ownerRef=Namespace, finalizer)
    C->>C: allocate IP from jit-ipam
    C->>R: POST /v1/runs {module, version, workspace, params}
    R->>R: fetch module at git ref
    R->>TF: tofu init (backend = MinIO, key ns/{ns}/redis)
    R->>TF: tofu apply
    TF->>D: create container @ 172.19.0.100
    D-->>TF: container id
    TF-->>R: outputs
    R-->>C: 200 {address, port, url}
    C->>K: create Secret + Service + EndpointSlice
    C->>K: claim status = Ready
    Note over K,T: kubelet was blocking the pod on the<br/>missing Secret - it now starts
```

The readiness gate is the absence of the Secret, not an explicit wait. A pod sits in
`CreateContainerConfigError` until the last step.

---

## 2. Soft delete - Deployment removed

```mermaid
sequenceDiagram
    autonumber
    actor T as Tenant
    participant K as kube-apiserver
    participant C as jit-controller
    participant R as jit-runner

    T->>K: delete deploy vote
    Note over C: resync tick (30s)
    C->>K: list Deployments annotating this module
    K-->>C: none
    C->>K: claim status = Orphaned, expiresAt = now + TTL
    Note over C,R: container keeps running

    alt redeployed inside the window
        T->>K: apply Deployment
        C->>K: list Deployments
        K-->>C: vote references redis
        C->>K: status = Ready, expiresAt cleared
        Note over C: same container, data intact,<br/>nothing reprovisioned
    else TTL expires
        C->>C: sweep finds now > expiresAt
        C->>R: DELETE /v1/runs/{workspace}
        R-->>C: 200 destroyed
        C->>K: delete Secret + Service + EndpointSlice
        C->>K: release finalizer
    end
```

---

## 3. Hard delete - Namespace removed

```mermaid
sequenceDiagram
    autonumber
    actor P as Platform team
    participant K as kube-apiserver
    participant C as jit-controller
    participant R as jit-runner

    P->>K: delete ns voting-a
    K->>K: GC deletes owned InfraClaims
    K-->>C: claim deleting (finalizer held)
    C->>R: DELETE /v1/runs/{workspace}
    R-->>C: 200 destroyed
    C->>K: release finalizer
    K->>K: Terminating -> gone
    Note over C: expiresAt ignored.<br/>Deleting a namespace is deliberate.
```

If the runner call fails, the finalizer is **not** released and the namespace stays in
`Terminating`. Escape hatch: `tofu destroy` by hand, then patch the finalizer off.

---

## 4. Claim state machine

The novel logic. Everything in Stage C of the build plan exists to make this correct.

```mermaid
stateDiagram-v2
    [*] --> Pending: annotation seen
    Pending --> Ready: apply succeeded
    Pending --> Failed: runner error
    Failed --> Pending: retry with backoff
    Ready --> Orphaned: last reference gone
    Orphaned --> Ready: a reference returns
    Orphaned --> Deleting: TTL expired
    Ready --> Deleting: namespace deleted
    Orphaned --> Deleting: namespace deleted
    Deleting --> Deleting: destroy failed, finalizer held
    Deleting --> [*]: destroyed, finalizer released
```

Two transitions carry the design:

- `Orphaned --> Ready` is resurrection. It is why a rollout costs nothing.
- `Orphaned --> Deleting` on **namespace deleted** bypasses the TTL. Soft and hard paths
  converge on the same destroy, at different speeds.

---

## 5. Resync loop

Why a loop and not just a delete watch: events are missed when the controller restarts.
The watch makes the common case fast; the resync makes it correct.

```mermaid
flowchart TD
    A[resync tick] --> B[list InfraClaims]
    B --> C[for each claim]
    C --> D[list Deployments in ns<br/>annotating this module]
    D --> E{any references?}
    E -->|yes| F[status = Ready<br/>clear expiresAt]
    E -->|no| G{already Orphaned?}
    G -->|no| H[status = Orphaned<br/>expiresAt = now + TTL]
    G -->|yes| I{now > expiresAt?}
    I -->|no| J[leave running]
    I -->|yes| K[destroy via runner<br/>release finalizer]
```

`referencedBy` is recomputed on every pass rather than maintained incrementally, which
is what makes refcounting work without a counter: two Deployments asking for Redis
produce one claim, and it only orphans when the last one goes.

---

## 6. Components

```mermaid
flowchart LR
    subgraph cluster["k3d cluster voting-app"]
        direction TB
        V[vote] --- W[worker] --- RS[result]
        CTRL[jit-controller]
    end

    subgraph net["docker network k3d-voting-app 172.19.0.0/16"]
        direction TB
        RUN[".10 jit-runner<br/>holds docker.sock"]
        MIN[".11 MinIO<br/>tf state"]
        RED[".100 redis"]
        PG[".101 postgres"]
        PGA[".102 pgadmin"]
    end

    CTRL -->|"HTTP + bearer"| RUN
    RUN --> MIN
    RUN -->|tofu apply| RED
    RUN --> PG
    RUN --> PGA
    V -.->|Service + EndpointSlice| RED
    W -.->|Service + EndpointSlice| PG
```

Solid arrows are control flow, dotted are data. The controller never touches Docker and
never holds state credentials - that separation is the point of the split-plane shape.
