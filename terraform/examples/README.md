# Example workloads

Applied by hand, not by Terraform — deliberately. The interesting event is
Karpenter reacting to an unschedulable pod, and if Terraform applied these too,
that would happen inside an apply and scroll past. Applying them separately
makes the causal chain visible:

```
kubectl apply → pod Pending → NodeClaim created → instance launched → node joins → pod Running
```

## The scheduling contract

> A pod requests an architecture. Karpenter picks an instance type that
> satisfies it. **A workload manifest never names an instance type.**

| File | Mechanism | Lands on |
| --- | --- | --- |
| `x86-deployment.yaml` | `nodeSelector: kubernetes.io/arch: amd64` | x86_64 Spot node |
| `arm64-deployment.yaml` | `nodeSelector: kubernetes.io/arch: arm64` | Graviton Spot node |
| `multi-arch-deployment.yaml` | `nodeAffinity` with `In [amd64, arm64]` | either — Karpenter chooses |

`arm64-deployment.yaml` is byte-identical to `x86-deployment.yaml` apart from the
name and one word in the nodeSelector. That is the honest summary of adopting
Graviton at the cluster level: a scheduling change. The work in a real migration
is upstream, in making the image multi-architecture.

## Run them

```bash
kubectl apply -f x86-deployment.yaml
kubectl get nodeclaims -w        # watch Karpenter provision; Ctrl-C when Ready

kubectl apply -f arm64-deployment.yaml
kubectl get nodeclaims -w
```

## The evidence

```bash
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

kubectl exec deploy/demo-x86   -- uname -m     # x86_64
kubectl exec deploy/demo-arm64 -- uname -m     # aarch64
```

**`uname -m` is the proof.** A node label says what Karpenter believes; `uname`
says what the kernel is actually running on. Confirm the capacity type against
AWS too, for the same reason:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' \
  --output table
```

`InstanceLifecycle: spot` from the AWS API is independent confirmation of the
`karpenter.sh/capacity-type=spot` label.

## Watching consolidation

```bash
kubectl delete -f x86-deployment.yaml -f arm64-deployment.yaml
kubectl get nodeclaims -w        # nodes drain and disappear after consolidateAfter
```

`consolidateAfter` is set to one minute so this is observable during a review.
Production sets it above the workload's warm-up time, or the cluster thrashes.

## Why the CPU requests are 1

Not arbitrary. The bootstrap nodes have roughly 0.8 CPU free each after the
Karpenter controller and the DaemonSets, so a pod requesting a full CPU cannot
fit on existing capacity — which is what forces Karpenter to provision rather
than letting the scheduler quietly place the pod. Without that, the x86 example
would land on a bootstrap node and demonstrate nothing.

## Cleanup

```bash
kubectl delete -f .
```

Delete these **before** `terraform destroy`. Karpenter-provisioned instances are
not Terraform-managed, so they have to drain while the controller is still alive
to drain them. The ordered teardown is in the parent README.
