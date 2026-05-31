# cert-manager 1.21: HTTP redirect migration

## Current state (pre-1.21)

cert-manager does not support `http01-parentreffallback`, so the HTTP-01 ACME
challenge cannot fall back to a listener defined on the parent Gateway. Instead,
the HTTP-01 solver needs its own listener on the ListenerSet.

**`charts/api/templates/listenerset.yaml`** has two listeners:

| Listener | Port | Protocol | Purpose                                     |
| -------- | ---- | -------- | ------------------------------------------- |
| `api`    | 443  | HTTPS    | TLS-terminated app traffic                  |
| `solver` | 80   | HTTP     | ACME HTTP-01 challenge + bootstrap redirect |

**`charts/api/templates/httproute.yaml`** has two routes:

| Route          | Parent                                | Purpose                                                                                                         |
| -------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `api`          | ListenerSet `api` → `api` listener    | App traffic (HTTPS)                                                                                             |
| `api-redirect` | ListenerSet `api` → `solver` listener | HTTP → HTTPS redirect (also gives external-dns an accepted route to create the A record before the cert exists) |

The `api-redirect` route is necessary because external-dns requires an accepted
HTTPRoute to create a DNS record. The HTTPS `api` listener is not programmed
until the cert exists, so its attached HTTPRoute is never accepted — creating a
circular dependency. The `solver` listener is programmed without a cert, so
`api-redirect` is accepted immediately and breaks the cycle.

## After cert-manager 1.21

cert-manager 1.21 adds `acme.cert-manager.io/http01-parentreffallback: "true"`
([upcoming releases](https://cert-manager.io/docs/releases/#upcoming-releases)).
When set on a ListenerSet, cert-manager places its HTTP-01 challenge HTTPRoute
on the parent Gateway's HTTP listener instead of requiring a dedicated solver
listener on the ListenerSet.

This allows a single gateway-level redirect to handle all apps.

## Migration steps

### 1. Add a port 80 listener to the Gateway (`charts/infra/templates/gateway.yaml`)

```yaml
listeners:
  - name: placeholder
    port: 65535
    protocol: HTTP
    hostname: placeholder.invalid
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            placeholder: placeholder
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

### 2. Add a global redirect HTTPRoute to the infra chart

New file `charts/infra/templates/httproute-redirect.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: gateway
      namespace: envoy-gateway-system
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

No `hostnames` field — matches all hostnames on the `http` listener. cert-manager's
challenge HTTPRoute uses an `Exact` path match which beats this wildcard redirect.

### 3. Update the ListenerSet annotation (`charts/api/templates/listenerset.yaml`)

Add the parentreffallback annotation and remove the `solver` listener:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: { { .Values.certIssuer.name } }
    acme.cert-manager.io/http01-parentreffallback: "true"
spec:
  listeners:
    - name: api
      hostname: { { .Values.hostname } }
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: api-tls
      allowedRoutes:
        namespaces:
          from: Same
```

### 4. Remove the per-app redirect route (`charts/api/templates/httproute.yaml`)

Delete the `api-redirect` HTTPRoute. The global infra redirect covers it.

The `api` HTTPRoute stays as-is, still referencing `sectionName: api` on the
ListenerSet. The `sectionName: solver` reference in the TODO comment can also
be removed.

## End state

- One port 80 listener on the Gateway (infra chart)
- One global `http-redirect` HTTPRoute in the infra chart — covers all apps
- Each app's ListenerSet has only the HTTPS listener + the parentreffallback annotation
- cert-manager places its challenge HTTPRoute on the Gateway's `http` listener automatically
- external-dns sees the challenge HTTPRoute (accepted on the ready `http` listener) and creates the A record
