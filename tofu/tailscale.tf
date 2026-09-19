# ==============================================================================
# Tailnet policy
# ==============================================================================
# The tailnet was the one piece of infrastructure this repo did not describe.
# modules/firewall.nix accepts `iifname tailscale0` wholesale — every
# tailnet-only service is private by the ABSENCE of an internet rule, not by a
# bind address — so what a tailnet peer may reach was decided entirely in a web
# console, by a policy file nothing here could review or roll back.
#
# ONE DOCUMENT, NO PARTIAL OWNERSHIP. Worth stating plainly because the obvious
# wish is to have tofu own some rules and hand-edit others, and the provider
# forecloses it: "this resource controls a tailnet's entire policy file and not
# just the ACLs section within it", and it "will completely overwrite existing
# policy file contents". There is no section-level ownership and no
# ignore_changes that would give it — the whole file is one string attribute.
#
# What replaces that wish is tags. Rules here are written against `tag:vps`,
# and APPLYING A TAG TO A DEVICE IS NOT IN THIS FILE — it is a console action or
# `tailscale up --advertise-tags`. So moving a machine between trust classes
# needs no apply, no commit and no credential, which is the part that actually
# wanted to be ad-hoc. The rules themselves change rarely and belong in review.
#
# ------------------------------------------------------------------------------
# ROLLOUT ORDER, ONCE
# ------------------------------------------------------------------------------
#   1. Create the OAuth client: admin console -> Settings -> OAuth clients, one
#      scope, `acl` (write). Put the id and secret in terraform.tfvars.
#
#   2. READ THE CURRENT POLICY FIRST, in the admin console. This resource
#      replaces it wholesale and `overwrite_existing_content` is left at its
#      default of false precisely so the import in imports.tf is mandatory — but
#      an import only puts the old policy in STATE, it does not stop the apply
#      from replacing it. Whatever is in there today that is not in
#      tailscale-policy.hujson is about to be gone.
#
#   3. Tag the VPS: Machines -> hu-tao -> Edit ACL tags -> tag:vps. Do this
#      BEFORE the apply, not after. It is safe in that order because the stock
#      policy's `dst: ["*:*"]` covers tagged devices too, so nothing loses
#      access in the gap — and the policy file's `deny` tests cannot pass until
#      it is done, so a plan will refuse while the narrowing would be a no-op.
#
#   4. `tofu plan`, read the diff against the old policy, then apply.
#
# To undo any of it: remove the tag in the console and the broad
# device-to-device rule covers the VPS again, no apply needed.
#
# ------------------------------------------------------------------------------
# THIS MAKES THE OAUTH CLIENT A HARD DEPENDENCY OF EVERY PLAN
# ------------------------------------------------------------------------------
# One state, one provider set. After this lands, `tofu plan` needs the tailscale
# credentials even for an unrelated DNS change — a missing client id is a failed
# plan, not a skipped resource. That is the cost of not splitting this into a
# second root module with its own state, and it is the right trade here: two
# states is two things to keep, and the credential is created once.
# The provider itself is pinned in versions.tf with the other two: a module may
# carry only ONE required_providers block, so a second `terraform` block here
# would be a duplicate-configuration error rather than an addition.
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret

  # `tailnet` is deliberately unset: it defaults to the tailnet that owns the
  # credentials, which is the only one this client can reach anyway. Naming it
  # would be a second value to keep correct for no behaviour.
}

resource "tailscale_acl" "main" {
  # templatefile rather than file, for exactly one substitution: the VPS's
  # tailnet address, taken from the same var the dozzle/grafana/syncthing A
  # records use. One address in the repo, not two.
  acl = templatefile("${path.module}/tailscale-policy.hujson", {
    vps_ipv4 = var.tailnet_ipv4
  })

  # BOTH LEFT AT false, BOTH ON PURPOSE.
  #
  # overwrite_existing_content = true would let an apply replace a policy this
  # configuration has never read. False makes the import in imports.tf a
  # precondition, so the old policy is in state and shows up as the left-hand
  # side of the diff before anything is written.
  #
  # reset_acl_on_destroy = true would put the tailnet back to the DEFAULT
  # policy — `dst: ["*:*"]`, everything reachable — if this resource were ever
  # removed. A `tofu destroy` or a dropped block would then silently re-open the
  # tailnet while looking like a clean teardown. Leaving it false means the last
  # applied policy stays in force, which is the safe direction to fail in.
}
