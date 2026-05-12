# NetApp DR Starter Kit

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A Validated Pattern - GitOps-first **disaster recovery** setup for OpenShift using **FSx for NetApp ONTAP** and **Trident Protect:** values + charts → Argo CD; FSx ONTAP + Trident Protect for replicated storage and app protection. Ansible updates the value layer so the declared state in Git matches each environment.

## Two ways to build AWS infrastructure

| Path | What runs the infrastructure | When to use it |
| ---- | ---------------------------- | ---------------- |
| **Crossplane (default)** | Crossplane controllers on the cluster apply AWS APIs from manifests; Ansible **only discovers** clusters and **writes Helm values** | Day-2 GitOps: commit values, let Argo CD sync managed resources (FSx, S3, VPC peering, Route53, and related wiring) |
| **Terraform playbooks (legacy)** | `ansible/dr-setup.yaml` drives **Terraform** modules under `terraform/` (remote state in S3 per `values-trident.yaml`) | Brownfield or environments that still want Ansible-orchestrated Terraform instead of Crossplane |

The default deployment method is the **Crossplane** path below.

## What the Crossplane path does

Given **production** and **DR** kubeconfigs, `make crossplane-setup` (or `ansible-playbook ansible/crossplane-setup.yaml`):

1. **Discovers** each cluster (VPC, subnets, route tables, region, etc.) from the Kubernetes/OpenShift API.
2. **Patches** repository Helm values (`values-hub.yaml`, `values-secondary.yaml`, `values-global.yaml`, and related keys) so charts match your AWS layout.
3. You **commit and push**; **Argo CD** syncs Crossplane **managed resources** (for example FSx ONTAP, S3 AppVault bucket, VPC peering, Route53 failover claims, provider config, and supporting jobs).

Teardown is **`make destroy-dr`**, which runs `ansible/crossplane-destroy.yaml` (Argo pause, ONTAP cleanup, Crossplane deletes, and an AWS CLI fallback for orphans). Confirm by typing `yes` when prompted.

## Prerequisites

- Two **OpenShift** clusters on **AWS** (typically different regions for cross-region DR).
- **Kubeconfig** files for both clusters (paths under `$HOME` if you use `./pattern.sh`, so they bind-mount into the utility container).
- **Ansible** with collections from `ansible/ansible-requirements.yml` (`amazon.aws`, `kubernetes.core`).
- **`oc` or `kubectl`** able to reach both clusters (discovery and optional resource checks).
- **AWS credentials** on the machine running setup (for example Route53 hosted zone discovery and any AWS API calls the playbooks perform); permissions depend on what you enable in values.
- **`./pattern.sh`**: **Podman** (Validated Patterns utility container) for `make install`, `validate-*`, and other common targets from `Makefile-common`.
- **Terraform** `>= 1.0.0` and **AWS CLI** — required for the **legacy** `dr-setup.yaml` path; useful for debugging and for destroy fallbacks.
- **Python 3** with **`boto3`** and **`kubernetes`**.
- **`~/.fsx`** with the FSx/SVM admin password (used where playbooks need ONTAP API access, for example during destroy/cleanup).

## Cloud (AWS) Permissions

- [Minimum Required Permissions](docs/iam-netapp-dr-starter-kit-policy.json) - The account you use will require an IAM policy with specific AWS permissions for crossplane to create/destroy the managed resources (FSx ONTAP, S3 AppVault bucket, VPC Peering and Route53 failover claims).

## Quick start (Crossplane + pattern)

```bash
# Discover both clusters and update Helm values in this repository
./pattern.sh make crossplane-setup \
  PROD_KUBECONFIG="${HOME}/.kube/kubeconfig-prod" \
  DR_KUBECONFIG="${HOME}/.kube/kubeconfig-dr"

git diff    # review values-hub.yaml, values-secondary.yaml, values-global.yaml, …
git add -A && git commit -m "Crossplane values after cluster discovery"
git push    # let Argo CD sync Crossplane managed resources

# Copy the values-secret.yaml.template to your home directory
cp values-secret.yaml.template ~/values-secret-netapp-dr-starter-kit.yaml

# Create a file called ~/.fsx to use for your Ontap filesystem and SVM creation
printf '%s\n' 'YourSecurePassword' > ~/.fsx
chmod 600 ~/.fsx

# Install the Validated Pattern on a target cluster (from Makefile-common; uses Podman)
./pattern.sh make install
```

For Route53 / zone discovery, ensure AWS credentials are configured as described in `ansible/crossplane-vars.yml` and playbook comments.

## Make targets (this repository)

| Target | Description |
| ------ | ----------- |
| `make crossplane-setup` | Run `ansible/crossplane-setup.yaml`: discover prod/DR clusters and **write** Crossplane-related Helm values (then commit/push for GitOps). |
| `make destroy-dr` / `make dr-destroy` | Run `ansible/crossplane-destroy.yaml`: pause Argo, clean ONTAP/SnapMirror, scrub AppVault S3, delete Crossplane claims, AWS CLI fallback; **requires typing `yes`**. |
| `make deps-js` | `npm ci` for Node devDependencies. |
| `make lint-biome` | Run **Biome** checks (JSON format aligns with GitHub super-linter). |
| `make format-biome` | Apply Biome formatting (e.g. Grafana dashboard JSON). |

Additional Validated Patterns targets (`install`, `validate-schema`, `argo-healthcheck`, …) come from **`Makefile-common`**. Run **`./pattern.sh make help`** for the full list.

## Architecture

```text
┌─────────────────────────────┐          ┌─────────────────────────────┐
│   Production Region         │          │   DR Region                 │
│                             │          │                             │
│  ┌───────────────────────┐  │  VPC     │  ┌───────────────────────┐  │
│  │  OpenShift Cluster    │  │ Peering  │  │  OpenShift Cluster    │  │
│  │  (Argo CD + Crossplane)│◄─┼──────────┼─►│  (Argo CD + workloads)│  │
│  └───────────────────────┘  │          │  └───────────────────────┘  │
│                             │          │                             │
│  ┌───────────────────────┐  │ SnapMir  │  ┌───────────────────────┐  │
│  │ FSx for NetApp ONTAP  │  │  ror     │  │ FSx for NetApp ONTAP  │  │
│  │ <cluster>-<region>-fsx │◄─┼──────────┼─►│ <cluster>-<region>-fsx │  │
│  └───────────────────────┘  │          │  └───────────────────────┘  │
└─────────────────────────────┘          └─────────────────────────────┘
```

Crossplane (hub) reconciles **AWS** resources declared in Git; workloads use **Trident / Trident Protect** (`AppMirrorRelationship`, AppVault, optional Route53 / DNS reconciler and monitoring charts) as configured in values.

## Helm values (high level)

| File | Role |
| ---- | ---- |
| `values-global.yaml` | Pattern-wide options, S3 AppVault / DR failover app list, global DNS domains. |
| `values-hub.yaml` | Hub cluster: Crossplane AWS infra, VPC peering, Route53 failover, FSx-related keys, `drDnsReconciler`, and more. |
| `values-secondary.yaml` | DR / secondary cluster overrides. |
| `values-trident.yaml` | Trident / storage class defaults; **legacy** Terraform state bucket settings for `dr-setup.yaml`. |
| `values-secret.yaml` (from template) | Secrets; not committed. Use Validated Patterns secret loading flows. |

## Helm charts under `charts/all/`

| Chart | Purpose |
| ----- | ------- |
| `crossplane` / `crossplane-providers` | Crossplane runtime and AWS provider wiring. |
| `crossplane-aws-infra` | Managed resources: FSx, S3, security groups, VPC peering, Route53 failover, endpoint jobs, and related RBAC. |
| `trident` / `trident-protect-config` | Trident backend and Trident Protect apps, AMR, snapshots, DNS export, hooks. |
| `dr-dns-reconciler` | Optional Route53 reconciliation from DR state. |
| `dr-monitoring` | Prometheus rules, Grafana dashboard ConfigMap for Trident DR signals. |
| `wordpress` | Example workload (optional). |

## Project structure

```text
├── ansible/
│   ├── crossplane-setup.yaml      # Discover clusters → write Crossplane Helm values
│   ├── crossplane-destroy.yaml    # Teardown (Argo, ONTAP, Crossplane, AWS fallback)
│   ├── crossplane-vars.yml        # Extra defaults for Crossplane playbooks
│   ├── dr-setup.yaml              # Legacy: Terraform FSx + VPC peering + state bucket
│   ├── dr-vars.yml
│   ├── site.yaml                  # RHPDS-style bootstrap → ./pattern.sh make install
│   ├── ansible-requirements.yml
│   └── roles/                     # cluster_discovery, fsx_ontap_terraform, vpc_peering_terraform,
│                                  # terraform_state, route53_failover_terraform, …
├── charts/all/                    # Subcharts (Crossplane, Trident Protect, DR DNS, monitoring, …)
├── terraform/
│   ├── fsx-ontap/                 # FSx ONTAP module (legacy Ansible+Terraform path)
│   ├── vpc-peering/
│   └── route53-failover/          # Terraform module used by route53_failover_terraform role
├── values-*.yaml                  # Helm / pattern values
├── pattern.sh                     # Podman wrapper for Validated Patterns tooling
├── Makefile                       # crossplane-setup, destroy-dr, Biome helpers
├── Makefile-common                # Validated Patterns install/validate targets
├── biome.json / package.json      # Local Biome (JSON) checks matching CI super-linter
├── .ansible-lint
└── .github/workflows/             # ansible-lint, super-linter, jsonschema, …
```

## Next steps after infrastructure

1. **Trident** and backends on both clusters (FSx SVM endpoints from status/outputs).
2. **Trident Protect**: AppVault, applications, **`AppMirrorRelationship`** for cross-region replication.
3. **Application DR**: follow your GitOps promotion process; optional **Route53 failover** and **`dr-dns-reconciler`** if you enabled them in values.

## Continuous integration and local checks

- **ansible-lint** and **super-linter** run in GitHub Actions (see `.github/workflows/`).
- For JSON (for example `charts/all/dr-monitoring/dashboards/trident-dr.json`), run **`make lint-biome`** after **`make deps-js`** so formatting matches super-linter’s Biome rules.

## More documentation

- Validated Patterns hub: [pattern metadata](https://validatedpatterns.io/patterns/netapp-dr-starter-kit/) (see `pattern-metadata.yaml` in-repo for links and tier).
