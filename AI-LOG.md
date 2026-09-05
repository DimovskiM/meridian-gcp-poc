# AI log

## 1. Tools used

Claude Code in the terminal, driving the whole build: writing the Terraform and
the FastAPI app, running `gcloud`/`terraform`/`docker` directly, watching CI
runs via `gh`, and doing the web research on Cloud Run cold starts and scaling
behaviour, migration patterns for serverless workloads, and the current state of
service account keys.

Started on **Sonnet 5** and switched to **Opus 5** partway through. The switch
was a direct response to the model producing successive workarounds around a
constraint instead of naming the constraint — the deploy-pipeline design
described below, where it kept generating variants rather than saying which of
two requirements could not hold at once.

Two workflow features mattered more than the model choice:

- **`/plan`** — forced a written plan before any code. Reviewing a plan is far
  cheaper than reviewing a half-built environment, and it is where the scope
  problems surfaced. Its main limitation is described in section 4: it reasons
  hard about what you leave open and not at all about what you hand it as
  fixed.
- **`/goal`** — kept the session anchored to the exercise's actual deliverables
  across a long build with several reversals. Without it the model drifts
  toward whatever was discussed most recently rather than what still needs
  finishing.

Roughly a 50/50 split between me directing architecture and the model producing
code. Every architectural decision below that went the right way went that way
because I pushed back, not because the first output was correct.

## 2. Things the AI proposed that I rejected or corrected

### Workarounds instead of naming a contradiction

The most expensive correction in the exercise, and the reason I switched models
mid-build. I asked for two things that sound compatible: the app's configuration
should live in Terraform, and an app deploy should not run `terraform apply`.
On some compute services those can both hold; on others they cannot, because
the deployed unit is immutable and only Terraform can replace it.

Rather than saying which situation we were in, it produced four mutually
contradictory designs in sequence — repo variables handed between two
workflows, `-target` applies scoped to a single resource, generating a
deployment manifest from Terraform, moving config back and forth between the
two. Each was a workaround for a constraint it had never surfaced, and each
looked plausible in isolation.

The fix was to stop asking for implementations and ask what the platforms
actually do differently. Cloud Run's service is a *mutable* resource, so
`lifecycle.ignore_changes` on the image plus `gcloud run deploy --image` is the
canonical split, and the requirement I had been asking for is simply the normal
pattern there. That reframing also surfaced two things nobody had connected to
the compute decision: one candidate had no Terraform field for internal-only
instance IPs at all, and its one-application-per-project model with a
permanently fixed region conflicts directly with Meridian's "we may need to
serve US customers later."

**The general failure mode: it will optimise inside a constraint indefinitely
rather than tell you the constraint is the problem.** It is worth periodically
asking "is what I'm asking for actually possible here?" rather than "why isn't
this working?"

### Migrations at application startup

Its first design ran Alembic in the FastAPI startup hook. That works, and I
shipped it far enough to test it, but it is wrong for a service that scales to
zero: every cold start pays a database round trip before serving, and a bad
migration degrades the service itself rather than failing somewhere visible.

Migrations now run as a separate Cloud Run Job before the new revision goes
live, under a Postgres advisory lock so overlapping executions serialise. A
failed migration fails the deploy with `--wait` and never touches running
traffic. This also satisfies a requirement it had solved awkwardly the first
time — "the app must not die if migrations fail" — by removing the app's
involvement entirely rather than wrapping the startup hook in a try/except.

### A project-level IAM role the app never needed

It granted the application's service account `roles/cloudsql.client` and
carried it through several revisions. The app connects over raw TCP to Cloud
SQL's private IP and authenticates with a Postgres password, so it never calls
the Cloud SQL Admin API — that role only matters for the Auth Proxy or the
language connectors, neither of which is in use. It was a leftover from an
earlier connection design that the model never revisited when the design
changed.

Removed, and verified by forcing a fresh revision and confirming `/health` still
reports `db: "ok"`. The application service account now holds **no project-level
roles at all** — only `secretAccessor` on the two specific secrets it reads.

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

The planning brief, given in `/plan` mode before any code existed. It is the
single prompt that produced the most durable output — roughly 70% of what
finally shipped came out of the first plan it generated.

> We're building a production-shaped slice of a GCP environment for a payments
> customer evaluating a move off AWS. Don't write code yet — I want a plan
> first.
>
> Hard constraints, none of these are negotiable: everything in Terraform with
> remote state in GCS, nothing created by hand in the console; the Postgres
> database must not be reachable from the internet under any circumstances;
> two secrets stored in GCP and read by the app under its own identity; no
> long-lived credentials anywhere in the repo; a public `/health` returning
> candidate, deployed commit SHA, region, and live `db` and `secret` checks
> that must be real per-request checks, not hardcoded.
>
> The customer asked for two things I want you to treat as suspect rather than
> as requirements. They asked for the default VPC "to keep it simple", and they
> asked for a service account JSON key in a GitHub secret because that's what
> the rest of their estate does. They also said developers need to run schema
> migrations from their laptops, against a database that is simultaneously
> supposed to be unreachable. Their clarification reply defers to us on the VPC
> and on how developers reach the database, and invites us to deviate on the
> key if we write down why. Data must stay in the EU — legal requirement — and
> they may want US customers next year. There is no AWS-to-GCP link today but
> assume one will be needed later, so don't paint them into a corner on
> addressing.
>
> For each of those three, tell me what you'd build instead and what it costs
> them, rather than resolving it silently. Where the brief is genuinely
> ambiguous, say so and mark it as an assumption instead of guessing. Give me
> the file layout, the build order, and how I'd verify it end to end.

What survived from that first plan, essentially unchanged: the custom VPC and
the reasoning for rejecting the default network; `europe-west3`; private-IP
Cloud SQL over Private Services Access; Secret Manager with per-secret IAM
rather than project-wide; the separate bootstrap module solving the
state-bucket chicken-and-egg; a VPC CIDR chosen away from common AWS defaults;
migrations automated rather than run from laptops, guarded by a Postgres
advisory lock; FastAPI with Alembic and a small real schema; `terraform plan`
on PRs; the commit SHA in `/health`; and the README/ASSUMPTIONS/AI-LOG split.

What did not survive is the more interesting part, and it follows a pattern:
almost every later reversal was something I had handed the plan as fixed rather
than left open for it to decide.

The clearest example is the CI credential. I told it to build the service
account key the way Meridian asked for, and it did — competently, with the key
in Secret Manager for easy hand-off, and no argument. It only made the case for
Workload Identity Federation when I stopped instructing and asked it to
research what current practice actually is; at which point it surfaced that
Google is retiring service account keys via organization policy defaults, that
`google_service_account_key` writes private key material into Terraform state,
and that the exercise's own "no long-lived credentials" line makes the key a
requirement violation rather than a preference. All of that was available on the
first pass. None of it came out while I was giving instructions.

The same shape repeats: where I described a problem, the plan reasoned about it
and was usually right. Where I specified a solution, it implemented that
solution and stopped thinking. **The value of the planning step is proportional
to how much of the problem you hand it as open** — a constraint stated as fixed
is a constraint it will optimise around rather than question, including when the
constraint is the thing that is wrong.

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
