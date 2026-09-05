# Meridian Payments — GCP proof of concept

A containerized HTTP API on Cloud Run talking to a private-IP Cloud SQL
Postgres, provisioned entirely with Terraform.

**Live:** https://meridian-api-n53g5ye65a-ey.a.run.app/health

```json
{"candidate":"Mihajlo Dimovski","commit":"c9dc03e","region":"europe-west3","db":"ok","secret":"ok"}
```

`commit` is the SHA of the deployed application image, so it tracks the last
change under `app/` rather than the newest commit on `main`.

`db` runs a real `SELECT 1` and `secret` checks the Secret Manager–injected
token on every request; neither is hardcoded.

## Architecture

```
GitHub Actions ──(OIDC, no keys)──> Cloud Run ──(Direct VPC egress)──┐
                                     meridian-api                     │
                                        │ startup probe /health       │
                                        ▼                             ▼
                                  Secret Manager            Cloud SQL Postgres
                                  db-password                private IP only
                                  third-party-api-token      10.156.80.3
                                                                      ▲
                                  Cloud Run Job ──────────────────────┘
                                  meridian-migrate (alembic upgrade head)
```

Custom VPC (`10.60.0.0/16`), Cloud SQL reachable only via Private Services
Access peering. The database has no public IP (`ipv4Enabled = false`).

## Decisions

**Cloud Run over App Engine / GKE.** A Cloud Run service is a *mutable*
resource, so Terraform owns the whole configuration — env vars, VPC egress,
service account, scaling, probes — while `gcloud run deploy --image` changes
only the image per deploy, with `lifecycle.ignore_changes` keeping the two from
fighting. App Engine Flexible cannot express that split: its versions are
immutable, so every deploy recreates the whole version through Terraform. App
Engine also permits one application per project with a region fixed forever,
which would make Meridian's "serve US customers later" a new project. GKE is
more machinery than one service justifies.

**Migrations as a Cloud Run Job, not from laptops.** Meridian asked for
developers to run migrations from their machines. Migrations run in the deploy
pipeline instead (`app/migrate.py`), under a Postgres advisory lock, before the
new revision goes live. Nobody needs network access to the database. The
practice worth removing was unversioned, unreviewed schema changes — not just
the connectivity. See ASSUMPTIONS.md, including the IAP-bastion path if they
need genuine break-glass access.

**Workload Identity Federation, not the service account key Meridian asked
for.** GitHub's OIDC token is exchanged for a short-lived GCP token per run.
The exercise requires no long-lived credentials; Google is retiring SA keys via
org policy defaults; and `google_service_account_key` writes private key
material into Terraform state. Deviation and its cost recorded in
ASSUMPTIONS.md.

**Custom VPC, not the default network.** Objected to in the clarification round
and Meridian deferred. The default network ships with SSH/RDP/ICMP open to
`0.0.0.0/0`, which contradicts their own "auditors are strict" framing.

**Commit SHA baked into the image at build time** (`--build-arg GIT_COMMIT`)
rather than passed through infra config, so it travels with the artifact.

## Layout

```
app/                FastAPI service, Alembic migrations, migrate.py job entrypoint
infra/              Terraform: VPC, Cloud SQL, secrets, IAM, Cloud Run, registry
infra/envs/         Per-region tfvars — copy one to add a region
infra/bootstrap/    Applied by hand once: state bucket, CI identity, WIF pool
.github/workflows/  plan (PR), deploy-infra, deploy-app
README.md           This file
ASSUMPTIONS.md      Every assumption, and Meridian's clarification reply
AI-LOG.md           Tool use, what I rejected, what it caught
```

## Running it

Against **this** project, both modules are already bootstrapped — `terraform
init` then `apply` works directly in either directory.

Against a **new** project there is a chicken-and-egg step, because a GCS backend
block cannot take variables: the bucket name is a literal in
`infra/bootstrap/main.tf`, `infra/bootstrap/backend.tf` and `infra/backend.tf`,
and GCS bucket names are globally unique. Change that name in all three first,
then:

```bash
# 1. Bootstrap cannot use the bucket it is about to create, so run it on
#    local state: comment out the backend block, apply, then migrate.
cd infra/bootstrap
#    (comment out infra/bootstrap/backend.tf)
terraform init
terraform apply -var="project_id=YOUR_PROJECT" -var="github_repository=OWNER/REPO"

#    Restore backend.tf and move the local state into the bucket it created:
terraform init -migrate-state
```

`github_repository` is the security boundary for CI authentication — only OIDC
tokens from that repository can impersonate the CI service account — so it must
be set, not left on its default.

Then the main module:

```bash
cd infra
terraform init
terraform apply -var-file=envs/europe-west3.tfvars -var="third_party_api_token=..."
```

The first apply creates the Cloud Run service against a placeholder image;
`deploy-app.yml` replaces it on the first app deploy.

Adding a region means copying `infra/envs/europe-west3.tfvars`, changing the
region and CIDRs, and applying with the new file.

CI needs repo variables `GCP_PROJECT_ID`, `GCP_REGION`, `WIF_PROVIDER`,
`CI_SERVICE_ACCOUNT` and one secret, `THIRD_PARTY_API_TOKEN`. All three
workflows also run on `workflow_dispatch`.

Locally, the app runs against any Postgres — set `DB_HOST`, `DB_PORT`,
`DB_NAME`, `DB_USER`, `DB_PASSWORD`, `THIRD_PARTY_API_TOKEN`, `REGION`.

## Time spent

About five hours, which was the budget. Roughly half went to the infrastructure
and the CI/CD pipelines, a quarter to the app and its migrations, and a quarter
to decisions that needed research before they could be made: the compute
service, keyless CI authentication, and where migrations should run. The
pipeline work absorbed more time than expected — most of it in the last mile,
where the app and infra pipelines have to converge cleanly rather than fight
each other over the same resources. AI-LOG.md covers what that cost.

## What I would do differently with more time

- **Front the service with a load balancer and Cloud Armor.** Right now
  `run.invoker` is granted to `allUsers` because the exercise requires a public
  `/health`. Production wants `ingress = INTERNAL_AND_CLOUD_LOAD_BALANCING`,
  WAF rules, and rate limiting — the last of which also caps the cost surface
  on an unauthenticated endpoint.
- **Move the Terraform state bucket to a separate project.** Project Viewer
  includes storage read access, and state holds the generated database password
  in plaintext — so granting reviewers Viewer also grants them that password.
  Separating the projects breaks that link.
- **Cloud SQL: `REGIONAL`, backups, PITR, and CMEK.** All disabled here for a
  three-week PoC. A payments company will likely require customer-managed keys;
  I did not spend a clarification question on it.
- **Time-bound privileged access.** Every human grant here is permanent —
  project Owner and the read-only reviewer binding. Production should have no
  standing production privileges at all: just-in-time elevation via Privileged
  Access Manager, where a role is requested with a justification, approved, and
  expires on its own. Combined with IAM database authentication and IAP
  tunnelling (both in ASSUMPTIONS.md), that makes access attributable,
  passwordless, and temporary.
- **Secret rotation.** `db-password` is generated once and never rotated.
- **Monitoring.** No uptime check, no alert policy, no SLO, no log-based
  metrics.
- **Tests.** The app has no automated tests; correctness was verified by
  running the container against a real Postgres and exercising the failure
  paths by hand.

ASSUMPTIONS.md records every assumption and open question. AI-LOG.md covers
tool use, what I rejected, and what the AI caught that I would have missed.
