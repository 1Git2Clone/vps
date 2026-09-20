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
#   0. Set `tailnet_ipv4` in terraform.tfvars, from `tailscale status`. It is
#      OPTIONAL for the DNS records and MANDATORY here: unset, it renders
#      `"vps": ""` and every rule keyed on that host silently becomes a rule
#      about nothing. A plan will not catch it — one did not. Setting it also
#      creates the dozzle/grafana/syncthing A records, which is the documented
#      behaviour of the variable and shows up as `3 to add`.
#
#   1. Create the OAuth client: admin console -> Settings -> Trust-credentials
#      -> Credential -> OAuth. One scope: Policy File (write). Read is implied,
#      and the console auto-selects a few adjacent read scopes — expected, and
#      harmless. Put the id and secret in terraform.tfvars.
#
#   2. READ THE CURRENT POLICY FIRST, in the admin console, and diff it against
#      tailscale-policy.hujson BY EYE. This resource replaces it wholesale and
#      `overwrite_existing_content` is left at its default of false precisely so
#      the import in imports.tf is mandatory — but an import only puts the old
#      policy in STATE, it does not stop the apply from replacing it. Whatever
#      is in there today that is not in the file is about to be gone.
#
#      THIS STEP HAS ALREADY EARNED ITS KEEP. The first real plan showed the
#      live policy carried a `nodeAttrs` block granting four devices Mullvad
#      exit-node access and the tailnet Funnel, plus a `tag:friends-ssh` tagOwner and
#      ssh rule — none of it in the first draft of this file, all of it deleted
#      on apply, and none of it named in the plan as a loss. It is carried over
#      verbatim now. Read the `-` lines in that diff as deletions, because that
#      is exactly what they are.
#
#   3. `tofu apply -var vps_is_tagged=false`
#
#      With `-out`, THE VARIABLE GOES ON THE PLAN, not the apply: a saved plan
#      already has its values baked in, and `tofu apply -var ... the.tfplan`
#      either ignores the flag or refuses the extra argument depending on where
#      it lands in the command. So either apply directly as above, or
#      `tofu plan -out main.tfplan -var vps_is_tagged=false` and then a bare
#      `tofu apply main.tfplan`.
#
#      THE ORDER HERE WAS WRONG UNTIL 2026-09-20 and the mistake is worth
#      keeping, because it looks correct. It said to tag the VPS first. You
#      cannot: Tailscale refuses to assign a tag that no tagOwners entry
#      defines, and tag:vps is defined only in the policy that is waiting to be
#      applied. The policy in turn cannot be applied, because its deny
#      assertions fail while the VPS is untagged. Each step blocks the other,
#      and `tailscale_device_tags` would hit the same wall — it is the API's
#      rule, not a limitation of the console or of this provider.
#
#      This apply is the way out. It publishes tagOwners and the tag:vps rules
#      with the two unmeetable assertions omitted, and CHANGES NO ACCESS:
#      nothing carries the tag yet, so the VPS is still reached through the
#      autogroup:self rule exactly as before. Measured against
#      /acl/validate before being written down — the false rendering is
#      accepted, the true one is rejected with both errors.
#
#   4. Tag the VPS: Machines -> vps -> Edit ACL tags -> tag:vps. Offered now,
#      because step 3 defined it. Tailscale SSH keeps working across this
#      because step 3 also installed the tag:vps ssh rule.
#
#   5. `tofu plan`, read the diff, then `tofu apply`. The assertions come back
#      and now hold. THIS is the apply that narrows anything; the one in step 3
#      only made it possible.
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
    vps_ipv4   = var.tailnet_ipv4
    vps_tagged = var.vps_is_tagged
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
