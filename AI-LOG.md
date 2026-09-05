# AI log

## 1. Tools used

Claude Code in the terminal, driving the whole build: writing the Terraform and
the FastAPI app, running `gcloud`/`terraform`/`docker` directly, watching CI
runs via `gh`, and doing the web research on Cloud Run cold starts, App Engine's
deploy model, and the current state of service account keys.

Started on **Sonnet 5** and switched to **Opus 5** partway through, during the
App Engine/Cloud Run problem described below. The switch was a direct response
to the model producing successive workarounds instead of identifying the
constraint underneath them.

Two workflow features mattered more than the model choice:

- **`/plan`** — forced a written plan before any code. The first plan went to
  App Engine because I had specified it, which is exactly how the wrong
  decision got locked in early. Reviewing a plan is much cheaper than reviewing
  a half-built environment, and it is where I caught scope problems.
- **`/goal`** — kept the session anchored to the exercise's actual deliverables
  across a long build with several reversals. Without it the model drifts
  toward whatever was discussed most recently rather than what still needs
  finishing.

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

### `ignore_changes` used to paper over drift it had not diagnosed

After the final apply, `terraform plan` still reported a pending change: a
service-level `scaling` block being removed. Its fix was to add `scaling` to
`lifecycle.ignore_changes` with a confident explanation that the API populates
the block on create.

That explanation was a guess, and `ignore_changes` on a block nobody had
investigated is exactly how real drift gets hidden later. Querying the Cloud Run
**v2** API directly (`gcloud run services describe` returns the older knative
shape and shows nothing here) and dumping the provider schema showed the actual
cause: the service-level `scaling` block has no `max_instance_count` field at
all, and the provider writes it into state with zero-valued defaults on create
regardless of whether the config declares it. Omitting it therefore guarantees a
permanent diff.

The fix is one declared block at its real default, not a suppression:

```hcl
scaling {
  min_instance_count = 0
}
```

`terraform plan` now reports no changes.

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

> ok lets refactor with cloud run. but first evaluate if the requirements
> sepcify anything. Like what they did in aws before and other things. Also
> does cloud run need warmup time or?

Quoted verbatim, typos included. Three things in one instruction: do not start
refactoring yet, re-read the requirements for anything that constrains the
choice, and tell me the operational downside of the platform you are about to
recommend.

Each part changed the output. The requirements check surfaced that Meridian's
"we may need to serve US customers later" actively argues against App Engine
(one app per project, region fixed permanently) — a point neither of us had
connected to the compute decision. It also surfaced what the brief *never* says:
what they run on AWS today, which I had not asked in the clarification round and
which is now recorded as an open assumption rather than quietly assumed away.
The cold-start question produced the scale-to-zero tradeoff and, following from
it, the decision to move migrations out of app startup into a Cloud Run Job.

The general lesson: prompts that ask the model to *validate the premise* before
executing are worth more than prompts that ask it to build the thing well. Left
to itself it will build the thing well and never mention that the premise was
wrong.

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

## 6. What I would add for a real engagement

Everything above was a single operator in one long session. On a real project
with several people and a repository that outlives the engagement, the tooling
itself has to be set up so the next person — or the next session — starts with
the context rather than rediscovering it.

**A `CLAUDE.md` at the repo root.** The single highest-leverage file. It would
carry the things that are expensive to re-derive and easy to violate by
accident: the architecture and why Cloud Run rather than App Engine or GKE; the
ownership split (Terraform owns Cloud Run configuration, `gcloud run deploy`
owns only the image, and the `ignore_changes` fields that keep them from
fighting); the bootstrap-versus-main-module boundary and why CI must never
manage its own identity; the constraints that are decisions rather than
oversights — EU-only region, no public IP on the database, no long-lived
credentials, migrations as a job and never from a laptop; and the conventions
for extending it, such as adding a region by copying an `envs/*.tfvars` file.

The point is that a model reading this repo cold will otherwise re-suggest
exactly the things that were already rejected here: the default VPC, a service
account key, migrations at app startup, an `ignore_changes` band-aid over drift
nobody diagnosed. I hit several of those in this session precisely because that
context lived only in my head.

**Skills for the repeatable operations.** The things I ran by hand and would not
want anyone improvising: bootstrapping a new environment in the right order
(bootstrap module, then variables, then main module); adding a region; rotating
the database password; the pre-submission verification sweep (`terraform plan`
clean on both modules, `/health` returning the right shape, no public IP on the
instance, no key material anywhere in the tree). A skill is the difference
between a documented runbook and one that actually gets followed, and it is
where the "did you remember to check X" failures disappear.

**Subagents for the work that benefits from a cold reader.** A security-review
agent pointed at the deployed IAM policy rather than the config — that is how
the state-bucket finding surfaced, and it is worth running on a schedule rather
than once. A cost-review agent to catch the class of mistake that does not fail
loudly: an over-sized Cloud SQL tier, a min-instance count nobody meant to set,
a load balancer left running. A drift-check agent on a cron, since the
convergence problems in this build were only visible by running `plan` after
each deploy and would otherwise have shipped silently.

**Hooks and settings.** A pre-commit hook that blocks anything matching key
material or a private key block — cheap, and it removes an entire category of
mistake rather than relying on someone remembering to grep. A permissions
allowlist for the read-only `gcloud`/`terraform` commands used constantly, so
the genuinely destructive ones still prompt and actually get read.

Two things in this session argue for all of the above. The permission classifier
blocked a recursive `gcloud storage rm` and forced me into the Terraform-native
path, which was the correct fix — a guardrail catching a real mistake. And I ran
`gcloud run deploy` by hand to force a fresh revision when I should have
triggered the pipeline, which is exactly the manual change the exercise
prohibits. A hook or a skill would have caught that; my own discipline did not.
