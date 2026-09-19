# ==============================================================================
# DNSSEC
# ==============================================================================
# Cloudflare signs the zone; the PARENT publishes the DS that makes anyone
# check the signature. Those are two different jobs in two different places, and
# only the first one can live here.
#
#   * SIGNING is a zone setting, and that is this resource. It is already on —
#     this block ADOPTS it (see imports.tf) rather than creating it.
#   * The DS RECORD goes in the `.dev` zone, not in this one. A zone cannot
#     vouch for itself — that is the whole point of the chain — so it is
#     published by the registry, which only takes it from the registrar. There
#     is no `cloudflare_dns_record` that can do it and none should be added: a
#     DS in your own zone is inert, and the one that matters is the one at the
#     parent.
#
# So the split is permanent: tofu owns the half that is an API call, and
# `tofu output dnssec_ds` prints the half a human pastes into the registrar.
#
# THE REGISTRAR IS HOSTINGER, and its DS cannot be managed from here by anyone.
# The `hostinger/hostinger` provider (0.1.23) carries `dns_record`, `vps`,
# `vps_ssh_key` and `vps_post_install_script` — no domain resource and nothing
# for DNSSEC — and its `dns_record` is for zones Hostinger itself hosts, which
# this is not. That is fine rather than a gap: a DS changes only when the key
# behind it does, Cloudflare rotates the ZSK (which the DS does not cover) and
# not the KSK, so this is a write-once value for the life of the zone. Automating
# a field that is touched once is how you end up with an apply path that can
# break the domain, which is the same reason the resource below sets nothing.
#
# CHAIN IS LIVE as of 2026-09-20. Confirm with the AD bit, never with this
# resource's status — a signed zone with no DS at the parent looks identical to
# a working one from the inside:
#
#   dig +dnssec @1.1.1.1 hu-tao.dev SOA | grep -E '^;; flags:.* ad'
#
# Verified against two independent validating resolvers rather than the
# dashboard: 1.1.1.1 and 8.8.8.8 both return AD=1 for the DS at the parent
# (2371 13 2 6814B774…), for `git` A, and for the apex MX. If that ever stops
# being true the whole domain is dark for validating resolvers — mail included —
# so it is worth re-checking after anything that touches the zone's keys.
#
# NOTHING HERE IS SECRET. A DS, a DNSKEY and the public key inside it are all
# published in the global DNS by design — anyone can `dig` them out of the
# parent the moment they exist. The private half never leaves Cloudflare and
# this configuration never sees it, which is why the outputs are plain rather
# than `sensitive = true`.
#
# ---------------------------------------------------------------------------
# WHY THIS BLOCK SETS NOTHING BUT `zone_id`, AND IGNORES THE REST
# ---------------------------------------------------------------------------
# The provider offers `status`, `dnssec_multi_signer` and `dnssec_presigned`,
# and a first draft of this file set all three. A plan proved that draft
# dangerous, which is the only reason this comment is longer than the resource:
#
#   ~ status              = "pending" -> "active"
#   ~ dnssec_multi_signer = true -> false
#   ~ key_tag             = 2371 -> (known after apply)
#   ~ digest              = "6814B77425..." -> (known after apply)
#   ~ public_key          = "mdsswUyr3D..." -> (known after apply)
#
# Read the last three lines. An apply that touches this resource puts the KEY
# MATERIAL back in play — the provider cannot promise the key tag and digest
# survive, because it does not know what Cloudflare does with a re-assert. If
# they do change after the DS is published, the chain breaks at the parent and
# the domain goes dark for every validating resolver on the internet. That is a
# whole-domain outage, not a service outage: mail, git and the web all resolve
# through the same name.
#
# `status` was never the fault it looked like either. It read "pending" while
# that draft was written, which is Cloudflare's word for "signed, waiting for
# the DS at your registrar" — and it flipped to "active" ON ITS OWN once
# Hostinger published the DS, with nothing applied here in between. The plan was
# re-run after that flip and still reports 0 to change, which is the property
# `ignore_changes` is here to hold.
#
# The ordering that mattered is now history, and worth keeping for the next
# person who enables this on a second domain: publish the DS at the registrar
# with the key that exists TODAY, confirm the AD bit, and only then consider
# whether multi-signer is worth an apply that could rotate it. Adoption first,
# opinions later.
#
# (Multi-signer IS wrong for this zone — it is for a domain served by two
# authoritative providers that each sign with their own key, and this one has
# only ever had kenneth/reza.ns.cloudflare.com. It is just not worth risking a
# live chain to fix a setting that changes nothing while the second provider
# does not exist.)
#
# Dropping the three arguments is NOT enough on its own: an optional argument
# left out is read as `null`, so a bare `zone_id` block planned
# `status = "pending" -> null` and `dnssec_multi_signer = true -> null` — still
# an in-place update, still key material "known after apply". `ignore_changes`
# is what makes the adoption inert, the same pattern hcloud_server.vps uses for
# ssh_keys/image/public_net. Measured, not assumed:
#
#   bare zone_id            Plan: 1 to import, 0 to add, 1 to change, 0 to destroy
#   + ignore_changes        Plan: 1 to import, 0 to add, 0 to change, 0 to destroy
#
# The cost is the usual one: a change to any of the three has to be made by
# hand and then reflected here, because this block will never propose one. That
# is the right trade for three settings that are correct today and whose apply
# path cannot promise to leave the signing key alone.
resource "cloudflare_zone_dnssec" "main" {
  zone_id = var.cloudflare_zone_id

  lifecycle {
    ignore_changes = [
      status,
      dnssec_multi_signer,
      dnssec_presigned,
    ]
  }
}
