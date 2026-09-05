# AI log

## 1. Tools used

Claude Code (Sonnet 5) in the terminal, driving the whole build: writing the
Terraform and the FastAPI app, running `gcloud`/`terraform`/`docker` directly,
watching CI runs via `gh`, and doing the web research on Cloud Run cold starts,
App Engine's deploy model, and the current state of service account keys.

Roughly a 50/50 split between me directing architecture and the model producing
code. Every architectural decision below that went the right way went that way
because I pushed back, not because the first output was correct.

## 2. Things the AI proposed that I rejected or corrected

### App Engine Flexible, and the design contradiction it produced

I told it to use App Engine. It complied, and then produced four mutually
contradictory designs in a row when I asked for two things that sounded
reasonable together: "app config in Terraform" and "app deploys shouldn't run
`terraform apply`."

What it should have said immediately — and only said when I asked directly what
the difference between App Engine and Cloud Run was — is that those two
requirements **cannot both hold on App Engine**. App Engine versions are
immutable: every deploy creates an entirely new version carrying its full
config, and `google_app_engine_flexible_app_version` can only be created or
replaced by Terraform. There is no "update just the image" operation. On Cloud
Run the service is mutable, so `lifecycle.ignore_changes` on the image plus
`gcloud run deploy --image` is the canonical pattern.

Instead of naming the conflict, it kept generating variants: repo variables
handed between two workflows, `-target` applies scoped to one resource,
generating `app.yaml` from Terraform. Each was a workaround for a constraint it
hadn't surfaced. **This cost the most time of anything in the exercise.** The
fix was to stop asking for implementations and ask what the platforms actually
do differently.

Switching to Cloud Run also closed a gap it had already flagged but not
connected: App Engine's Terraform resource has no field for
`instance_ip_mode`, so instances got public IPs. And App Engine allows one app
per project with a permanently fixed region, which directly conflicts with
Meridian's "we may need to serve US customers later."

### A live Secret Manager API read on a public, unauthenticated endpoint

Its `/health` called the Secret Manager API on every request, justified by the
exercise's wording ("read a secret from a GCP service storing it"). The reading
is defensible. The design is not: `/health` is public and unauthenticated, so
anyone can drive unbounded Secret Manager API calls and cost. It also made the
app depend on `google-cloud-secret-manager` for no functional gain.

Both secrets are now injected by Cloud Run via `secret_key_ref` and `/health`
checks presence. Still not hardcoded — removing the secret, the IAM binding, or
the env wiring turns it red, which I verified by starting the container without
the variable. The tradeoff is recorded in ASSUMPTIONS.md rather than hidden.

### Terraform outputs that nothing consumed

It added outputs reflexively — `artifact_registry_repo`, `cloudsql_private_ip`,
`state_bucket_name`, `ci_service_account_email` — none of which any workflow
read. Worse, when I asked it to template `app.yaml` at deploy time, it proposed
outputs for `vpc_network_name`, `app_subnet_name`, and
`app_service_account_email`: values that are string literals *in the Terraform
config itself*. Round-tripping a constant through remote state to read back the
value you wrote is pure ceremony.

All outputs are gone. The service URL comes from `gcloud run services
describe`, which also means the app pipeline needs no access to Terraform state
at all.

### Self-managing CI credentials

The CI service account and its key were originally in the main module — the
same module CI runs `terraform apply` on. Any drift, taint, or provider-driven
replacement would rotate the credential mid-run, with nothing updating the
GitHub secret, and the next run would simply fail to authenticate. I moved the
CI identity into `infra/bootstrap`, applied by hand, so the module CI manages
has no path to regenerate the credential CI is using.

### Over-scoped IAM

It gave the CI account `roles/editor` **plus** `roles/iam.securityAdmin` and
`roles/artifactregistry.admin`. `securityAdmin` is far broader than needed and
`artifactregistry.admin` was unnecessary — nothing in the config sets IAM
policy on the registry, and `roles/editor` already covers push/pull. Replaced
with the narrow roles matching the bindings this config actually makes:
`resourcemanager.projectIamAdmin`, `secretmanager.admin`, `run.admin`, and
`servicenetworking.networksAdmin`.

### Guessed API field names

It wrote `instance_ip_mode` on `google_app_engine_flexible_app_version`. The
field does not exist there. It type-checked in its head and failed on
`terraform validate`. After that I made it query the provider schema
(`terraform providers schema -json`) before writing any non-obvious resource,
which caught the correct shape of `env.value_source.secret_key_ref` and the
`manual_scaling` requirement without another round trip.

## 3. What the AI caught that I would have missed

Two things.

**Project Viewer implies read access to Terraform state, which holds the
database password in plaintext.** During an adversarial review of the deployed
IAM policy, it noticed the state bucket grants
`roles/storage.legacyObjectReader` to `projectViewer:*`. The exercise asks us to
grant the reviewers Viewer — so that grant also hands them the generated
database password. I would have granted Viewer without thinking about what else
it reaches. The real fix (state bucket in a separate project) is in the README's
"what I'd do differently."

**A logging bug that made a resilience feature untestable.** Alembic's `env.py`
calls `fileConfig()`, whose `disable_existing_loggers` defaults to `True` —
which silently disabled the app's own logger. The "migrations must not crash the
app" behaviour worked, but the failure was invisible in logs. Caught by actually
running a deliberately broken migration and noticing the expected error line was
missing.

## 4. Most useful prompt

> hold up bro. this doesnt make much sense. Whats the difference between app
> engine and cloud run?

Every implementation-level prompt before this produced another contradictory
workaround. Asking the model to explain the platforms instead of write code got
it to state the constraint it had been designing around for an hour — that App
Engine's immutable versions make "config in Terraform, image deployed by gcloud"
impossible — and the right architecture fell out immediately.

## 5. Proportion of AI-generated code

**Around 90%.** Nearly every line of Terraform, Python, and YAML was written by
the model. What was mine was the direction: choosing Cloud Run, rejecting
laptop migrations in favour of a job, insisting on WIF, killing the outputs,
shrinking the instance tiers, requiring `workflow_dispatch` and a plan file on
apply, and repeatedly refusing designs that didn't hold together.

The high number is the point. The model is fast and fluent and will confidently
produce a design that cannot work, or one that works but leaks money or access,
and it will keep patching around a constraint rather than naming it. It is very
good at the parts that are mechanical, and it does not reliably tell you when
you have asked for something impossible — you have to ask.
