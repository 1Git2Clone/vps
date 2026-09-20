# ==============================================================================
# State recovery
# ==============================================================================
# The state file is gitignored (it holds every value tofu has ever read, tokens
# included), so a fresh clone has no state and neither does a machine whose copy
# was lost. Without this file, that clone's `tofu plan` proposes creating a
# second server and moving DNS to it — and a run of hand-typed `tofu import`
# commands from someone's shell history is how it gets rebuilt.
#
# These blocks are that list, checked in. An import block is inert while state
# already tracks the address, so on a healthy checkout they do nothing; on an
# empty one, `tofu plan` shows "N to import" and rebuilds state on apply. Same
# outcome as the by-hand sequence, but reviewable, and it cannot forget one.
#
# WHAT A RECOVERY PLAN LOOKS LIKE, so a wrong one is recognisable:
#
#   Plan: 32 to import, 0 to add, 1 to change, 0 to destroy.
#
# The one change is hcloud_server.vps gaining three provider-side booleans
# (ignore_remote_firewall_ids, keep_disk, shutdown_before_deletion) that the
# importer never sets. Anything else — any `+ public_net`, any `-`, any
# `-/+` — means stop.
#
# Expect a SECOND change, tailscale_acl.main, until the policy in this repo has
# been applied at least once: the import reads whatever the tailnet is serving,
# and the diff against tailscale-policy.hujson is the point. Counted here rather
# than measured from an empty state, which is not something to try casually
# against live infrastructure.
#
# Why public_net in particular: the hcloud importer and its Read both leave it
# out of state, so before server.tf ignored it a recovery plan proposed ADDING
# the block, and on this resource that detaches the current primary IPs before
# reattaching. On 2026-09-05 that took 167.233.24.58 off the running mail
# server; delete_protection on the IP is why it was ten minutes of downtime
# rather than a lost address. `tofu apply -refresh-only` does NOT repair this
# — refresh is the same Read that omits the block. lifecycle.ignore_changes on
# server.tf is the fix, and this file's job is to make sure the recovery that
# needs it is never typed by hand.
#
# A non-zero plan against infrastructure you know is unchanged means the STATE
# is wrong, not the infrastructure. Never resolve an unexpected diff with a
# plain apply.

locals {
  # Cloudflare record IDs, keyed the way module.dns keys them. Record IDs are
  # facts about the zone, not derivable, so they are written down.
  dns_a_records = {
    git       = "acf3cabcabfb15082fb920c213408b7f"
    mail      = "d95eaec80d7ef0326de086aa2d7dd883"
    mc        = "8b5b420ea4b1c920e560ae488c7d824e"
    mc2       = "ae7ae954818b8660e32346a2ff864308"
    minecraft = "cc4c0e13050cc0b3fd928f65db032ce9"
    music     = "e4aea113292b407283fcbb447abe723f"
    pages     = "0c8b8dbe295b4f125050da6acbe836a6"
    search    = "77ca2c34bc4fe585462349a4e0cd76b8"
    smtp      = "1a8fa2eac6aab44c98e9cb46a39073d5"
    status    = "2f7cf86c32a9d0f0aab797eebbac6d13"
  }

  # The tailnet-only names, same idea. These were created in the dashboard
  # before var.tailnet_ipv4 was set, so tofu's first plan after setting it
  # proposed CREATING three records that already existed — which is a duplicate
  # or a 81058, not a no-op. Verified against the API before being written down:
  # all three are A, unproxied, TTL auto, pointing at the same address
  # module.dns would have used, so the import is clean and changes nothing.
  dns_tailnet_records = {
    dozzle    = "3ab68becc67f0b5cfa1270091b18b720"
    grafana   = "007693e357dd0d4a75056a3e42882ad8"
    syncthing = "de30585a21727101a2e0c3480f0eca43"
  }
}

# --- Hetzner -----------------------------------------------------------------

import {
  to = hcloud_ssh_key.main
  id = "118051438"
}

import {
  to = hcloud_primary_ip.main
  id = "134632948"
}

import {
  to = hcloud_primary_ip.main_v6
  id = "147045245"
}

import {
  to = hcloud_server.vps
  id = "163906050"
}

# <prefix>-<primary ip id>-<address>; `p` is the primary-ip prefix.
import {
  to = hcloud_rdns.primary_ipv4
  id = "p-134632948-167.233.24.58"
}

# The runner's cloud firewall, and its attachment by the same id — the same
# pairing module.hetzner-firewall uses below. THESE TWO HAD NO BLOCK until now:
# `tofu state list` returned thirty resources and this file declared thirty, but
# NOT THE SAME THIRTY, and the counts matching by coincidence is what let the gap
# survive under a header claiming this file "cannot forget one".
#
# Recovering without them does not fail, which is the problem. It proposes
# CREATING a second firewall and attaching it, leaving the real one attached to
# the runner and unmanaged — so the next tightening of the ingress rules would
# land on a copy that filters nothing, while the plan reads clean.
import {
  to = hcloud_firewall.runner
  id = "11645120"
}

import {
  to = hcloud_firewall_attachment.runner
  id = "11645120"
}

import {
  to = module.hetzner-firewall.hcloud_firewall.main
  id = "11483636"
}

# The attachment is imported by the firewall's own id.
import {
  to = module.hetzner-firewall.hcloud_firewall_attachment.main
  id = "11483636"
}

# --- Three resources in state that nothing declares ---------------------------
# hcloud_network.main, hcloud_network_subnet.main and hcloud_server_network.vps
# are in terraform.tfstate as ordinary managed resources with real ids
# (12666492, 12666492-10.0.1.0/24, 163906050-12666492) and NO `resource` block
# anywhere in this configuration — grep the repo; they appear only in state and
# in two design docs.
#
# THEY GET NO IMPORT BLOCK ON PURPOSE. An import must name a declared resource,
# and `tofu plan` rejects one that does not with "Configuration for import
# target does not exist" — which fails every plan in this directory, including
# unrelated ones. Adding them here was tried on 2026-09-20 and backed out.
#
# What they do instead is nothing. Two separate plans that day refreshed all
# three and then excluded them from `resource_changes` entirely — not created,
# not destroyed, not even no-op. Reproducible, and deliberately not explained
# here: guessing at a mechanism would be worse than recording the observation.
#
# The declarative fix is a `removed` block with `lifecycle { destroy = false }`,
# which drops them from state without touching the real network. Not written yet
# because it changes what the next apply does, and the apply this was last
# touched for was meant to carry only DNSSEC and the tailnet policy. Decide
# first whether the 10.0.1.0/24 private network is wanted at all: nothing in
# this repo addresses it, and the discord bot reaches pgbouncer and tempo over
# the docker bridge instead.

# --- Cloudflare --------------------------------------------------------------
# Import id is <zone id>/<record id>.

import {
  for_each = local.dns_a_records
  to       = module.dns.cloudflare_dns_record.a[each.key]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

# The tailnet names carry the SAME for_each GUARD AS THE RESOURCE, and that is
# not decoration. module.dns creates these only when tailnet_ipv4 is set; an
# import block naming an instance that the configuration does not declare is a
# planning error, not a skipped block. Without the guard, a clone that has not
# set tailnet_ipv4 — a legitimate state, the variable defaults to empty — would
# fail every plan in this directory rather than simply having no such records.
import {
  for_each = var.tailnet_ipv4 == "" ? {} : local.dns_tailnet_records
  to       = module.dns.cloudflare_dns_record.tailnet[each.key]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

# The tailnet policy file, adopted rather than written over. `tailscale_acl`
# leaves `overwrite_existing_content` at false precisely so this import is
# mandatory: without it the provider refuses to touch a policy tofu has never
# read. The id is ignored by the provider ("ID doesn't matter" in its own import
# docs) because a tailnet has exactly one policy file; `acl` is the spelling its
# documentation uses.
#
# An import puts the CURRENT policy in state, which is what makes the first plan
# a readable diff instead of a blind replacement. It does not stop the apply
# from replacing it -- read that diff. See tofu/tailscale.tf.
import {
  to = tailscale_acl.main
  id = "acl"
}

# DNSSEC was switched on in the dashboard before tofu knew about it, so this is
# an adoption rather than a creation — without it the first plan proposes
# CREATING a zone setting that already exists. The id is the bare zone id: a
# zone has exactly one DNSSEC configuration, so there is no second component to
# address, unlike the DNS records below which are `<zone>/<record>`.
import {
  to = cloudflare_zone_dnssec.main
  id = var.cloudflare_zone_id
}

import {
  to = module.dns.cloudflare_dns_record.mx
  id = "${var.cloudflare_zone_id}/b48a6f27879595810a33aa4008ae2911"
}

import {
  to = module.dns.cloudflare_dns_record.spf
  id = "${var.cloudflare_zone_id}/0c55af3747393d3acf02473e0934806e"
}

import {
  to = module.dns.cloudflare_dns_record.dkim_cloudflare
  id = "${var.cloudflare_zone_id}/41ecb6bf7630acc3cfa46ac4e331d632"
}

import {
  to = module.dns.cloudflare_dns_record.dkim_default
  id = "${var.cloudflare_zone_id}/0a98a2557a7e75061f71f3874885d2cb"
}

import {
  to = module.dns.cloudflare_dns_record.dmarc
  id = "${var.cloudflare_zone_id}/91f99f89efbb9b2b3203f8a710ad1389"
}

import {
  to = module.dns.cloudflare_dns_record.minecraft2_srv
  id = "${var.cloudflare_zone_id}/065cd7f358df976afa6a2f484e59c61e"
}

import {
  to = module.dns.cloudflare_dns_record.bsky
  id = "${var.cloudflare_zone_id}/49002efb9babb52cd5dc5a207fb42cd0"
}

# The CI runner, created in the console on 2026-09-18 and adopted here. Its
# primary IPs are deliberately NOT imported: server.tf declares no public_net
# block for this box, so there is nothing for them to be imported into. They
# stay Hetzner-managed and auto-delete with the server, which is the right
# lifecycle for an address that carries neither DNS nor a PTR.
import {
  to = hcloud_server.runner["forgejo-runner"]
  id = "166488672"
}

# THE RUNNER BECAME A for_each. Its state address changed from
# hcloud_server.runner to hcloud_server.runner["forgejo-runner"], and without
# this block tofu reads that as "destroy one server, create another" — which on
# a delete-protected box fails the apply outright, and on an unprotected one
# would have destroyed a limited-availability CX server to rename a state key.
#
# A `moved` block rather than a hand-run `tofu state mv`: the migration lives in
# the repo, applies itself on the next plan, and is still correct for anyone
# planning from a state that has already moved (it becomes a no-op).
moved {
  from = hcloud_server.runner
  to   = hcloud_server.runner["forgejo-runner"]
}
