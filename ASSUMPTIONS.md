# Assumptions

Everything I had to decide without Meridian, and how I resolved what they left
open. The clarification round is closed, so anything unanswered below is an
assumption I made and would confirm on day one of a real engagement.

## What I asked, and what Meridian answered

I sent three questions and two objections. Their reply, verbatim:

> Today our developers connect through a client VPN into the AWS account and
> reach the database from there. We are not attached to reproducing that on
> Google Cloud. Both requirements are real: the auditors will not move on if the
> database is open to the internet, and the developers need to run their
> migrations. How they get to the database is your call, we will follow your
> recommendation.
>
> We have not decided on a specific region. It's customer payment data and our
> legal team has been clear that it stays in the EU. The US thing is a maybe for
> next year, not now. We will follow your recommendation here.
>
> Nothing connects the two today. If we go ahead there will be a period where
> both estates run side by side, so assume a link will be needed at some point.
> Do not build it now, just do not leave us somewhere we cannot get out of
> later.
>
> On the default VPC: that is what we understood from our own reading, but we
> are not Google Cloud experts, that is why we brought you in. If we have it
> wrong, we will follow your recommendation to build it the right way.
>
> On the service account key: our platform team set that up a while ago and it
> is how the rest of our estate works, so there would need to be a good reason
> to deviate. If you think there is a better way, do it your way but write down
> why, so I can take it to them.

Four of the five came back as "your call, we will follow your recommendation",
which moves the weight of this document from *what did they tell me* to *what
did I decide and why*. The fifth — the service account key — is the only one
where they pushed back, and it is the only place I overrode a stated preference.
Their phrasing there ("so I can take it to them") is the reason the WIF
rationale below is written to be forwarded to their platform team rather than
just filed.

One thing I did not ask and should have: **what they run on AWS today**. The
brief says "one of our API services" and that they are on AWS, but never names
ECS, EKS, Lambda, or EC2. That would have sharpened the compute choice
considerably. It is recorded as an open assumption below.

## Resolved by the clarification round

**Developer access to the database.** Meridian described a client VPN into AWS
today, but said "how they get to the database is your call." I built no VPN,
no bastion, and no tunnel: schema migrations run as a **Cloud Run Job**
(`infra/cloudrun.tf`, `app/migrate.py`) triggered by the deploy pipeline.
Developers write a migration file and commit it; nobody needs network access to
the database at all.

This is a deliberate rejection of the workflow as briefed, not just a
convenience. **Engineers running migrations from their laptops against a
production payments database is the practice worth removing, independent of how
they connect.** It means schema changes that are not in version control, not
reviewed, not repeatable across environments, and not recoverable — plus an
audit trail that says "someone with a laptop" rather than "this commit, this
pipeline run, this approver". Solving only the connectivity question (VPN,
tunnel, bastion) would have preserved all of that. Running migrations as a
pipeline-triggered job removes the reason to connect at all: the migration is a
reviewed file in the repo, applied identically everywhere, with the job
execution as the audit record.

**For the cases a job cannot cover** — incident debugging, a genuine ad-hoc
query, inspecting production data during an investigation — the answer is *not*
to reopen laptop access to the database. The GCP-native path is **Cloud SQL Auth
Proxy over IAP TCP forwarding**: a small bastion instance with no public IP, no
open SSH port, and no VPN, reachable only through Identity-Aware Proxy. Access
is granted per-identity via IAM (`roles/iap.tunnelResourceAccessor`) rather than
by network location, every session is logged, and the proxy authenticates to
Cloud SQL with IAM credentials over TLS. Not built here — it is a real cost (an
always-on VM, IAP configuration, an IAM review process) that a three-week
evaluation does not need, and no such requirement was stated. It is the first
thing I would add if Meridian says they need break-glass access.

**Region.** `europe-west3` (Frankfurt). Meridian's legal team requires EU only;
GCP has no Lithuania region. Frankfurt over Warsaw or Finland for latency to the
German customer base, and it is a full-featured region. "US customers next year"
is explicitly not now — and Cloud Run makes that a new service in a new region
rather than a migration, so nothing here forecloses it.

**Default VPC.** Objected to, and Meridian deferred ("if we have it wrong, we
will follow your recommendation"). Built a custom VPC (`infra/network.tf`). The
default network ships with permissive auto-created firewall rules (SSH/RDP/ICMP
open to `0.0.0.0/0`), which contradicts their own "auditors are strict" and
"reflect the production target" framing. Custom VPCs default-deny all ingress.

**AWS ↔ GCP connectivity.** Not built, per instruction ("do not build it now,
just do not leave us somewhere we cannot get out of later"). The VPC CIDR is
`10.60.0.0/16`, deliberately away from the common AWS defaults (`10.0.0.0/16`,
`172.31.0.0/16`) to reduce the chance of an overlap that would block a future
VPN or Interconnect. **This is a guess** — I never learned their real AWS CIDR
and would confirm before building any link.

## Decisions Meridian did not weigh in on

**CI authentication: Workload Identity Federation, not the static key Meridian
asked for.** Their platform team asked for a service account JSON key in a
GitHub secret, to match the rest of their estate. I built WIF instead
(`infra/bootstrap/iam.tf`): GitHub's OIDC token is exchanged for a short-lived
(1 hour) GCP token on each run, and no key exists at all. Four reasons:

1. The exercise lists "no long-lived credentials anywhere in the repository" as
   a hard requirement, not a preference.
2. Google is progressively disabling service account key creation via
   organization policy defaults (`disableServiceAccountKeyCreation`). The
   pattern we were asked to match is being retired, and breaks outright under
   that constraint — so matching it now buys compatibility with something
   Meridian will have to migrate off anyway.
3. `google_service_account_key` writes the private key into Terraform state in
   plaintext. "The key is not in the repo" would have been technically true
   while the key sat in the state bucket.
4. Meridian explicitly invited it: *"if you think there is a better way, do it
   your way but write down why, so I can take it to them."* They asked for a
   case to bring to their own platform team; quietly complying would have given
   them nothing.

**What this costs, kept visible deliberately:** their estate is now
inconsistent — this project authenticates differently from everything else they
run, which is a real operational cost (two patterns to understand, two runbooks).
If they decline the recommendation, reverting is a small change: a
`google_service_account_key` resource and `credentials_json` in the three
workflows. The security boundary in the WIF setup is the provider's
`attribute_condition`, which pins federation to exactly one GitHub repository —
without it, any repository on github.com could exchange a token for access to
this project. That condition must never be widened to a bare `true`.

**Compute service: Cloud Run.** The exercise asks for a reasoned choice. Cloud
Run because: it is container-native, scales to zero (a three-week PoC costs
almost nothing when idle), and — the deciding factor — a Cloud Run service is a
*mutable* resource, so Terraform can own the whole configuration while
`gcloud run deploy --image` updates only the image on each app deploy. App
Engine Flexible cannot express that split: its versions are immutable, so every
deploy recreates the entire version through Terraform. App Engine also allows
exactly one application per project with a region fixed forever, which would
make "serve US customers later" a whole new project.

**What Meridian runs on AWS today is unknown.** The brief says "one of our API
services" and that they run on AWS, but never names ECS, EKS, Lambda, or EC2. I
did not spend a clarification question on it. Cloud Run is the closest analogue
to ECS Fargate, the most common shape for a containerized API service on AWS, so
it is a defensible target — but if they are on EKS, GKE would be the more honest
"production target" and I would revisit.

**The database uses password authentication, and the app holds no project-level
IAM roles at all.** The app connects over raw TCP to Cloud SQL's private IP via
Direct VPC egress and authenticates with a Postgres password from Secret
Manager. It therefore does *not* need `roles/cloudsql.client` — that role grants
`cloudsql.instances.connect`/`get`, which are consumed by the Cloud SQL Auth
Proxy and the language connectors, both of which call the Cloud SQL Admin API.
We use neither. The role was in an earlier revision of this config as a leftover
from a design that assumed the Auth Proxy; it has been removed and the removal
verified by forcing a fresh revision and confirming `/health` still reports
`db: "ok"`. The app's service account now holds no project-level roles — only
`secretAccessor` on the two specific secrets it reads.

**For production I would switch to Cloud SQL IAM database authentication**,
which reverses that: `roles/cloudsql.client` becomes genuinely required, and in
exchange the database password stops existing. The app authenticates as its own
service account using short-lived OAuth tokens, `db-password` and its Secret
Manager entry disappear, and with them the rotation problem, the plaintext copy
in Terraform state, and the fact that project Viewer can read it. The cost is a
dependency on the Cloud SQL Python connector and a change to how both the
service and the migration job open connections — not worth it inside this
exercise's budget, but the right end state.

**IAM database authentication also covers human access, which makes it the
better answer to Meridian's original question.** Cloud SQL supports
`CLOUD_IAM_USER` for individual Google accounts and `CLOUD_IAM_GROUP` for
groups, alongside service accounts. A developer connects as *themselves* using
their own `gcloud` credentials — there is no shared `meridian_app` password to
distribute, rotate after someone leaves, or find pasted in a chat log. Access is
granted and revoked through IAM or group membership, and every session is
attributable to a named person in the audit log rather than to a shared
account.

Combined with the IAP bastion path described above, that is the full production
shape for break-glass access: IAP TCP forwarding for the network path (no VPN,
no public IP, IAM-gated), the Cloud SQL Auth Proxy for transport, and IAM
database authentication for identity — per-human, passwordless, and audited end
to end. Not built here for the same reason as the bastion: no such requirement
was stated, and the job-based migration flow removes the day-to-day need.

**Migrations run as a job, not at app startup.** An earlier version ran Alembic
in the FastAPI startup hook. On Cloud Run with scale-to-zero that would put a
database round trip in front of every cold start, and a bad migration would
degrade the service itself. As a separate job, a failed migration fails the
deploy visibly (`--wait` in `deploy-app.yml`) and never touches running traffic.
Migrations hold a Postgres advisory lock so overlapping executions serialize.

**`/health`'s `secret` check reports presence, not live reachability.** Both
secrets are injected by Cloud Run from Secret Manager at instance start
(`secret_key_ref` in `infra/cloudrun.tf`); the app never calls the Secret
Manager API. So `secret: "ok"` means the injected value is present and
non-empty — it is not hardcoded (removing the secret, the IAM binding, or the
env wiring makes it `error`), but it does not prove Secret Manager is reachable
*at that moment*. A live API read per request would prove more, but `/health` is
public and unauthenticated, so it would also give anyone an unbounded way to
drive Secret Manager API calls and cost. **This was a deliberate call.** If the
stronger signal is wanted, the right shape is a cached read with a TTL behind an
authenticated endpoint, not a live call on every public request.

**Ingress is not controlled by VPC firewall rules, and that surprises people.**
Cloud Run's front end sits outside the VPC, so no firewall rule in
`network.tf` governs who can reach the API. Exactly two settings do:
`ingress = "INGRESS_TRAFFIC_ALL"` on the service, and the `roles/run.invoker`
binding granted to `allUsers` — both in `infra/cloudrun.tf`. That combination
is deliberate: the exercise requires `/health` on a public URL.

The VPC *does* govern the outbound path. Direct VPC egress gives each instance
an IP from `10.60.1.0/24`, and that traffic is subject to VPC egress rules —
it is how the service reaches Cloud SQL's private IP across the Private
Services Access peering. So `allow_internal` in `network.tf` is about
east-west traffic inside the VPC, not about who can call the API.

For production, ingress control means: set
`ingress = "INTERNAL_AND_CLOUD_LOAD_BALANCING"`, put an external HTTPS load
balancer in front, and attach Cloud Armor for WAF rules, IP allowlisting, and
rate limiting — the last of which also caps the cost-amplification surface on
a public unauthenticated endpoint. Not built here: it adds a load balancer's
standing cost to a three-week PoC whose brief explicitly asks for a public
health URL. Anything beyond `/health` should also require authentication
(`run.invoker` granted to named identities instead of `allUsers`).

Only the API is exposed either way. The database has no public IP and is
unreachable from the internet, which is the actual constraint Meridian stated.

**Scale to zero, no minimum instances.** Cheapest for a three-week evaluation.
The cost is a ~1–3s cold start on the first request after an idle period
(requests pend rather than fail). For a production payments API I would set
`min_instance_count = 1` with startup CPU boost.

## Deliberately not built (PoC scope)

- **Cloud SQL**: single-zone (`ZONAL`), no backups, no read replica, no
  customer-managed encryption keys. Production wants `REGIONAL`, PITR, and — for
  a payments company — very likely CMEK, which I would have asked about with a
  second clarification round.
- **No PCI scope confirmed.** The brief never says whether this service touches
  cardholder data. If it does, network isolation is the floor, not the ceiling —
  segmentation, key management, logging, and access review all become in scope.
  I would ask this before any production design.
- **No monitoring, alerting, or log-based metrics.** No uptime check, no SLO, no
  alert policy.
- **`deletion_protection = false`** on Cloud SQL and Cloud Run, because this
  environment is meant to be torn down after the review. Production would be the
  opposite.
- **The Terraform state bucket has `force_destroy = false`** but no bucket-level
  retention policy or object versioning lifecycle rules beyond versioning being
  on.
- **Secrets have no rotation.** `db-password` is generated once by
  `random_password` and never rotated. Production would rotate on a schedule and
  the app would need to handle rotation without downtime.
