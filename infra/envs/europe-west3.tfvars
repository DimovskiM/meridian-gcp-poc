# Meridian's current (and only, for now) environment — Frankfurt.
# EU-only per Meridian's legal requirement (payment data); Frankfurt over
# Warsaw/Finland for latency to the German customer base.
#
# To add another region later: copy this file, rename it, and change these
# three values — vpc_cidr must not overlap any other environment's range if
# they'll ever need to be connected (e.g. via VPN/Interconnect back to AWS).

project_id      = "meridian-payments-poc"
region          = "europe-west3"
vpc_cidr        = "10.60.0.0/16"
app_subnet_cidr = "10.60.1.0/24"
