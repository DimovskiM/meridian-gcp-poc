# Bootstrapping sequence, in order:
#   1. First-ever run on a brand new project: this file doesn't exist yet (or
#      is commented out) — apply with local state, since the bucket it's
#      about to create obviously can't hold state before it exists.
#   2. Once the bucket exists (it does, as of this project): add this file
#      and run `terraform init -migrate-state` once, which copies the local
#      state into the bucket. All later runs read/write state from here.
#
# Uses "bootstrap/state" — a different prefix than the main module's
# "terraform/state" — so the two don't collide inside the same bucket.
terraform {
  backend "gcs" {
    bucket = "meridian-payments-tfstate"
    prefix = "bootstrap/state"
  }
}
