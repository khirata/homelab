.PHONY: all clean deploy check install-deps backup test deploy-ntfy-client deploy-siem deploy-wazuh deploy-dashboards deploy-infisical redeploy-infisical env _pre-deploy-backup _infisical-check

-include .env
export

PLAYBOOK         = ansible/site.yml
INVENTORY        = ansible/inventory/hosts.ini

# Exchanges the machine identity's Universal Auth credentials for a short-lived
# access token. The CLI does NOT read INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET
# on its own — the only env var it honours is INFISICAL_TOKEN. Without an
# explicit token it silently falls back to whatever `infisical login` session
# the operator happens to have, and a user account with no membership on the
# project returns an EMPTY secret set with exit 0 (see docs/infisical.md).
# Token auth turns that same permissions gap into a loud 403.
#
# The credentials go through the CLI's own env vars rather than --client-id /
# --client-secret flags, so the secret never lands in argv (world-readable via
# `ps`) nor in the recipe line make echoes to the terminal. `export` above
# publishes these to every recipe. Only `infisical login` reads them; `run` and
# `export` ignore them entirely, hence the explicit token hand-off below.
INFISICAL_UNIVERSAL_AUTH_CLIENT_ID     = $(INFISICAL_CLIENT_ID)
INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET = $(INFISICAL_CLIENT_SECRET)

INFISICAL_LOGIN  = infisical login --method=universal-auth \
                     --domain=$(INFISICAL_API_URL) --plain --silent

# Puts the token in $$_t, aborting when login fails or yields an empty string
# (an empty INFISICAL_TOKEN would resurrect the silent user-session fallback).
INFISICAL_TOKEN_SH = _t=$$($(INFISICAL_LOGIN)) && test -n "$$_t" \
                       || { echo '[infisical] machine-identity login failed — check INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET in .env' >&2; exit 1; }

# Wraps ansible-playbook commands to inject secrets from Infisical.
# Requires INFISICAL_PROJECT_ID, INFISICAL_API_URL, and machine identity
# credentials (INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET) in .env.
# INFISICAL_API_URL must be the LAN address, never the Cloudflare Tunnel
# hostname: the tunnel sits behind Cloudflare Access, which 302s unauthenticated
# API calls to a login page and the CLI reads that as "no secrets".
# INFISICAL_CUSTOM_HEADERS could carry an Access service token past this, but we
# deliberately do not — it would place a broader, account-level credential in
# .env beside the Infisical one, adding no independent layer. Use WARP to reach
# the LAN when off-site. Rationale: docs/infisical.md.
INFISICAL_RUN    = $(INFISICAL_TOKEN_SH); INFISICAL_TOKEN=$$_t infisical run \
                     --projectId $(INFISICAL_PROJECT_ID) \
                     --env prod \
                     --domain $(INFISICAL_API_URL) \
                     --

INFISICAL_EXPORT = infisical export \
                     --projectId $(INFISICAL_PROJECT_ID) \
                     --env prod \
                     --domain $(INFISICAL_API_URL)

# Committed list of the keys Infisical must serve. Uncommented entries are
# required; `# KEY=` lines document optional ones without enforcing them.
SECRETS_TEMPLATE = infisical-secrets.template.env

# Bare KEY names from dotenv-formatted input — a file argument or stdin.
KEYS_OF          = grep -ohE '^[A-Za-z_][A-Za-z0-9_]*'

## Default: dry-run check
all: check

## Guard: abort unless Infisical serves every key $(SECRETS_TEMPLATE) requires.
## Token auth already turns a missing project grant into a 403; this catches the
## cases that stay silent — an environment that is authorised but empty, or a key
## renamed/dropped in the UI — which would otherwise render the matching
## lookup('env', ...) blank and deploy an empty credential.
_infisical-check:
	@$(INFISICAL_TOKEN_SH); k=$$(mktemp); INFISICAL_TOKEN=$$_t $(INFISICAL_EXPORT) --format dotenv --silent | $(KEYS_OF) | sort -u > $$k; \
	 n=$$(wc -l < $$k | tr -d ' '); miss=$$($(KEYS_OF) $(SECRETS_TEMPLATE) | sort -u | comm -23 - $$k | tr '\n' ' '); rm -f $$k; \
	 test "$$n" -gt 0 || { echo '[infisical] 0 secrets in prod — assign the machine identity to the project, then retry' >&2; exit 1; }; \
	 test -z "$$miss" || { echo "[infisical] missing from prod: $$miss" >&2; echo "[infisical] add them in the UI or via: infisical secrets set --file <filled copy of $(SECRETS_TEMPLATE)>" >&2; exit 1; }; \
	 echo "[infisical] $$n secrets available, all $(SECRETS_TEMPLATE) keys present"

## Remove locally rendered/cached files (nothing to clean in this repo)
clean:
	@echo "Nothing to clean."

## Trigger a PostgreSQL backup on the remote server
## Uses ; not && so the log tail always prints, even on failure; the final
## is-failed check still makes this target exit non-zero on a real failure.
backup:
	$(INFISICAL_RUN) ssh $$SIEM_SERVER_USER@$$SIEM_SERVER_IP \
	  "sudo systemctl start pg-backup.service; \
	   journalctl -u pg-backup.service -n 20 --no-pager; \
	   ! systemctl is-failed --quiet pg-backup.service"

## Deploy the SIEM server stack (runs backup first if pg-backup.timer exists)
deploy: _infisical-check _pre-deploy-backup
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY)

## Deploy only the SIEM server (runs backup first)
deploy-siem: _infisical-check _pre-deploy-backup
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server

## Deploy only the Wazuh stack containers (indexer, dashboard, nginx proxy) — no backup pre-step
deploy-wazuh: _infisical-check
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server --tags wazuh_stack

## Deploy only Grafana dashboards (no stack restart)
deploy-dashboards: _infisical-check
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags dashboards

## Update ntfy-client.env on all hosts (after rotating NTFY_TOKEN)
deploy-ntfy-client: _infisical-check
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags ntfy_client_env

## Bootstrap Infisical — uses .env directly (first deploy, Infisical not yet running)
## All secrets must be present in .env (not yet in Infisical).
deploy-infisical:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server,postgresql_server --tags docker,postgresql,infisical

## Update a running Infisical — injects secrets from Infisical (use after initial bootstrap)
redeploy-infisical: _infisical-check
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server --tags infisical

## NOTE: previously this used a single &&/|| chain, so a pg-backup unit that
## exists but genuinely fails to start printed the same "not yet installed,
## skipping" message as a host where it was never installed — masking backup
## failures right before a deploy. This distinguishes "not installed" (skip,
## fine) from "installed but failed" (abort the deploy, which depends on this
## target) and always shows the log tail so the failure is visible inline.
_pre-deploy-backup:
	@$(INFISICAL_RUN) ssh $$SIEM_SERVER_USER@$$SIEM_SERVER_IP \
	  "systemctl list-units --type=service --all | grep -q pg-backup.service || { echo '[backup] pg-backup not yet installed, skipping'; exit 0; }; \
	   sudo systemctl start pg-backup.service; journalctl -u pg-backup.service -n 20 --no-pager; \
	   systemctl is-failed --quiet pg-backup.service && { echo '[backup] pre-deploy snapshot FAILED — aborting deploy' >&2; exit 1; }; \
	   echo '[backup] pre-deploy snapshot complete'"

## Dry-run (no changes applied)
check: _infisical-check
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --check

## Install required Ansible collections
install-deps:
	ansible-galaxy collection install -r ansible/requirements.yml

## Run linters locally (requires: pip install yamllint ansible-lint)
test:
	yamllint .
	ansible-lint $(PLAYBOOK)

## Print all Infisical secrets as KEY=VALUE lines (dotenv format).
## Use this to load secrets into the current shell for ad-hoc ansible-playbook runs:
##   eval $(make env)
##   ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --limit siem_server
##
## Note: prefer `infisical run -- ansible-playbook ...` when possible — it never
## prints secrets to stdout (no terminal scroll-back exposure).
env:
	@$(INFISICAL_TOKEN_SH); INFISICAL_TOKEN=$$_t $(INFISICAL_EXPORT) --format dotenv
