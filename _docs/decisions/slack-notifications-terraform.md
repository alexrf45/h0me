# Decision: Slack notifications via Terraform + 1Password

Date: 2026-06-24 · Status: **proposed**

## Problem

The lab's Slack alerting is **fully wired but dead** — the Slack apps were spun down, so the
webhook the cluster still references no longer resolves to a live channel. Goal: reimplement
the Slack side **as code** (Terraform), publish the credential to **1Password** so the
observability layer ingests it via the existing ExternalSecret path, and stand up a **new
dev-only channel** now (a prod channel follows when the prod cluster lands).

## Key context — the wiring is live but pointed at a dead webhook

This is a **revival**, not a from-scratch build. Two consumers already read the **same**
1Password item `metrics_webhook_dev` (property `credential`):

- **Alertmanager** — `_lib/observability/kube-prometheus-stack/external-secret-slack.yaml`
  (ES `slack-webhook`, ns `monitoring`) feeds receivers `slack-critical` + `slack-warning` in
  `_lib/observability/kube-prometheus-stack/helmrelease.yaml`, both posting to `channel:
  "#alerts"` via `api_url_file`, `send_resolved: true`.
- **Gatus** — `_lib/applications/gatus/base/externalsecret.yaml` (ES `gatus-slack-webhook`,
  ns `gatus`) → `$SLACK_WEBHOOK_URL` in the deployment/configmap; all **6 monitored
  endpoints** alert via the same webhook.

Secret flow is unchanged: `ClusterSecretStore` `onepassword-connect`
(`_lib/secrets/cluster-secret-store/cluster-secret-store.yaml`, vault `HomeLab: 1`) → ESO →
k8s Secret. No Flux `notification-controller` `Provider`/`Alert` instances exist;
`_hack/yaml/argo-cd-slack.yaml` is reference-only, not deployed.

**Hard constraint on "via Terraform":** there is **no Terraform resource that creates a Slack
app or an incoming webhook** — the Slack provider (`pablovarela/slack`) manages channels,
users, and usergroups, not app/credential creation. So Terraform's realistic role is two-fold:

1. **Manage the channel** — `slack_conversation "dev_alerts"` (and `prod_alerts` later).
2. **Publish the credential to 1Password** — `onepassword_item`, exactly the pattern
   `_infra/cloudflare-tunnel/main.tf` (L22–36) already uses for the tunnel token:

   ```hcl
   resource "onepassword_item" "slack_dev" {
     vault    = var.op_vault_id
     title    = "slack_alerts_dev"
     category = "password"
     section {
       label = "slack"
       field {
         label = "webhook-url"   # or bot-token / signing-secret
         type  = "CONCEALED"
         value = var.slack_webhook_url   # bootstrapped value (see options)
       }
     }
   }
   ```

The **app + webhook/token itself is a one-time bootstrap** (Slack UI or an app manifest); its
value is fed into Terraform once, then Terraform owns publication/rotation into 1Password.
New TF would live at `_infra/slack-app/` (standalone integration, alongside
`_infra/cloudflare-tunnel/`). Slack provider docs:
<https://registry.terraform.io/providers/pablovarela/slack/latest/docs>.

---

## Option A — Incoming Webhook, single shared secret (revive-in-place)

Recreate one Slack app with an **incoming webhook** bound to a new `#dev-alerts` channel.
Terraform manages the channel (`slack_conversation`) and republishes the webhook URL to
1Password as `metrics_webhook_dev` / `credential` (same item the cluster already reads).
**Zero manifest changes** — both ExternalSecrets re-sync within their `refreshInterval` and
alerting goes green.

**Pros**
- Smallest possible change — both consumers work as-is; only the 1P value is refreshed.
- Matches the established `cloudflare-tunnel` TF→1Password publication pattern.
- Fastest path back to a working `#dev-alerts` feed (and Slack mobile push) today.

**Cons**
- Webhook can't be TF-created — manual app/webhook bootstrap remains.
- One secret shared by Alertmanager **and** Gatus — rotating it touches both at once.
- Incoming webhooks are channel-locked and a legacy-leaning Slack surface (no Block Kit,
  no multi-channel routing).

## Option B — Bot token (app manifest), per-consumer secrets *(Recommended)*

Define the Slack app **declaratively via an app manifest** checked into `_infra/slack-app/`;
publish its **bot token + signing secret** to 1Password as a structured item; **split the
secret per consumer** — separate 1P entries / ExternalSecrets for `monitoring` vs `gatus` so
scope and rotation are independent. Channels (`#dev-alerts` now, `#prod-alerts` later) managed
by `slack_conversation`.

**Pros**
- Future-proof: a bot token posts to many channels, supports Block Kit formatting, and the
  app manifest is the closest thing to declarative "Slack-as-code".
- Decouples consumers — rotate or re-scope Alertmanager and Gatus independently.
- Clean dev/prod channel split; same bot serves both with channel-scoped routing.
- Directly enables the **GitHub-Actions-into-Slack** follow-up (review item **CI2**) off the
  same bot token from 1Password.

**Cons**
- More upfront wiring than Option A.
- **Alertmanager `slack_configs` speaks a webhook `api_url`, not a bot token.** Two honest
  sub-paths: (1) keep AM on an incoming webhook while Gatus/CI use the bot token — a
  documented hybrid, or (2) stand up a small relay and point AM at `webhook_configs` →
  bot-token poster. Option (1) is the pragmatic default.
- The app manifest still needs a one-time install/authorization in the workspace.

## Option C — Drop Slack, go straight to Pushover/ntfy push

Skip reviving Slack entirely: repoint Alertmanager at a native `pushover_configs` (or
`webhook_configs` → ntfy) receiver and switch Gatus to its pushover/ntfy provider.

**Pros**
- Serves the "alerts on my iPhone" goal most directly, with fewer hops and no Slack app
  lifecycle to maintain.
- One fewer third-party surface.

**Cons**
- Loses Slack's shared channel, history, threading — and the GitHub-Actions-into-Slack
  ambition (CI2).
- Still needs a secret in 1Password; larger manifest rewrite across both AM and Gatus.
- Doesn't match the stated intent to **reimplement Slack**; better treated as the *phone-push*
  milestone in the production-readiness checklist than as a replacement for Slack.

---

## Recommendation

**Option B, phased.** Phase 1: revive an incoming webhook into a new `#dev-alerts` channel
(Option-A mechanics) to get alerting green immediately and restore Slack mobile push. Phase 2:
layer the bot-token app-manifest in `_infra/slack-app/` and split the 1Password item per
consumer (`monitoring` keeps a webhook, `gatus`/CI move to the bot token). The dedicated
iPhone-push path (Pushover/ntfy, Option C's mechanism) is **not** discarded — it's tracked as
its own benchmark in `_docs/production-readiness-checklist.md` (M-OBS), independent of Slack.

ExternalSecret **shapes don't change** — only the 1Password item name(s)/keys do if the secret
is split. Terraform publishes the credential(s) to 1Password; ESO re-syncs on its
`refreshInterval`.

## Open questions

1. **Secret topology** — keep one shared `metrics_webhook_dev`, or split into per-consumer 1P
   items (separate Alertmanager vs Gatus)? *(Recommend split under Option B.)*
2. **Channels** — confirm `#dev-alerts` now, `#prod-alerts` when the prod cluster lands.
3. **`_infra/slack-app/` state backend** — local (it's app-tier, like `pve-tf-admin/`) vs S3
   (consistency with other `_infra/` integrations)?
4. **Workspace / app** — which Slack workspace; is there an existing app/manifest to import,
   or is this net-new?
5. **Option B Alertmanager path** — accept the AM-stays-on-webhook hybrid, or stand up a relay
   so AM also posts via the bot token?
