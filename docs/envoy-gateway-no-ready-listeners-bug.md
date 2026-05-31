# Issue: Envoy Gateway sets `Accepted: False` with non-standard `NoReadyListeners` reason

## Summary

Envoy Gateway sets `Accepted: False` on an HTTPRoute when the listener it is
attached to is not yet programmed (e.g. the TLS secret referenced by the
listener does not exist). The reason used — `NoReadyListeners` — is not defined
in the Gateway API spec.

This causes a circular dependency with cert-manager HTTP-01 + external-dns:
DNS cannot be created (external-dns requires an accepted route) and the cert
cannot be issued (cert-manager requires DNS), so neither ever resolves.

---

## Spec

[`apis/v1/shared_types.go` L342–397](https://github.com/kubernetes-sigs/gateway-api/blob/124954708648c30b0da3d51b51d51fefdf87b9bb/apis/v1/shared_types.go#L342-L397)

The Gateway API spec defines the following valid reasons for the `Accepted`
condition on a route (used with both `True` and `False` status):

```go
RouteReasonAccepted                RouteConditionReason = "Accepted"
RouteReasonNotAllowedByListeners   RouteConditionReason = "NotAllowedByListeners"
RouteReasonNoMatchingListenerHostname RouteConditionReason = "NoMatchingListenerHostname"
RouteReasonNoMatchingParent        RouteConditionReason = "NoMatchingParent"
RouteReasonUnsupportedValue        RouteConditionReason = "UnsupportedValue"
RouteReasonPending                 RouteConditionReason = "Pending"
RouteReasonIncompatibleFilters     RouteConditionReason = "IncompatibleFilters"
```

`NoReadyListeners` is not among them.

The spec also defines `Accepted` via `RouteParentStatus`:

> A Route MUST be considered "Accepted" if at least one of the Route's rules
> is implemented by the Gateway.
>
> Note that the route's availability is also subject to the Gateway's own
> status conditions and listener status.

The second sentence notes that listener status affects route _availability_
separately from route _acceptance_. What "implemented by the Gateway" means
in the context of a listener that is accepted but not yet programmed is
ambiguous in the spec.

---

## Envoy Gateway behavior

[`internal/gatewayapi/route.go` L2290–2301](https://github.com/envoyproxy/gateway/blob/8d3cfb4540a817ec8078c8169b5b054861885c7f/internal/gatewayapi/route.go#L2290-L2301)

```go
if !HasReadyListener(allowedListeners) {
    routeStatus := GetRouteStatus(routeContext)
    status.SetRouteStatusCondition(routeStatus,
        parentRefCtx.routeParentStatusIdx,
        routeContext.GetGeneration(),
        gwapiv1.RouteConditionAccepted,
        metav1.ConditionFalse,
        "NoReadyListeners",
        "There are no ready listeners for this parent ref",
    )
    continue
}
```

When no listeners are ready (e.g. TLS secret missing), EG sets
`Accepted: False` with reason `NoReadyListeners`. The reason value is not
defined in the spec.

---

## Observed impact

Setup: Envoy Gateway + cert-manager (HTTP-01 / Let's Encrypt) + external-dns
(`gateway-httproute` source) + ListenerSet with a port 443 HTTPS listener.

On a fresh cluster:

1. ListenerSet deployed with `cert-manager.io/cluster-issuer` annotation.
   Port 443 listener references a TLS secret that does not exist yet.
2. HTTPRoute attached to port 443 listener via `sectionName`.
3. Envoy Gateway sets `Accepted: False / NoReadyListeners` on the HTTPRoute
   because the TLS secret is missing.
4. external-dns checks `Accepted` condition ([`source/gateway.go:780-781`](https://github.com/kubernetes-sigs/external-dns/blob/main/source/gateway.go#L780-L781)),
   skips the HTTPRoute → no A record created.
5. cert-manager cannot complete HTTP-01 challenge (no DNS) → cert not issued.
6. TLS secret never created → listener never programmed → HTTPRoute never
   accepted → back to step 4.

The circular dependency is unresolvable without a workaround.

### Workaround

Add a second HTTPRoute on a port 80 listener (which requires no TLS secret
and is always programmed). external-dns sees this accepted route, creates the
A record, cert-manager completes HTTP-01, cert is issued, port 443 listener
becomes programmed, original HTTPRoute becomes accepted.

This workaround is required **per hostname** and adds boilerplate to every
app chart.

---

## Conformance tests

The Gateway API conformance suite has a test for invalid TLS configuration
([`conformance/tests/gateway-invalid-tls-configuration.go`](https://github.com/kubernetes-sigs/gateway-api/blob/main/conformance/tests/gateway-invalid-tls-configuration.go)).
It asserts on the listener's `ResolvedRefs: False / InvalidCertificateRef`
condition and `AttachedRoutes: 0`, but makes no assertion on the `Accepted`
condition of any attached HTTPRoute in this scenario.

There is no conformance test covering HTTPRoute `Accepted` status when the
listener has an invalid or missing TLS certificate ref. The expected behavior
is unspecified.

---

## Question

Should a route be considered `Accepted` when the listener is `Accepted: True`
but `Programmed: False`? The spec's definition of "implemented by the Gateway"
is ambiguous here, and there is no conformance test that covers this scenario.
If the intended answer is that `Accepted` should remain `True`, then
`NoReadyListeners` should use a different condition (e.g. `Programmed: False`)
rather than `Accepted: False`, so that downstream tools relying on `Accepted`
are not affected.
