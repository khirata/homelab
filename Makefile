.PHONY: all clean deploy check install-deps backup test deploy-ntfy-client deploy-siem deploy-dashboards deploy-infisical env

-include .env
export

PLAYBOOK         = ansible/site.yml
INVENTORY        = ansible/inventory/hosts.ini

# Wraps ansible-playbook commands to inject secrets from Infisical.
# Requires INFISICAL_PROJECT_ID, INFISICAL_API_URL, and machine identity
# credentials (INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET) in .env.
INFISICAL_RUN    = infisical run \
                     --projectId $(INFISICAL_PROJECT_ID) \
                     --env prod \
                     --domain $(INFISICAL_API_URL) \
                     --

## Default: dry-run check
all: check

## Remove locally rendered/cached files (nothing to clean in this repo)
clean:
	@echo "Nothing to clean."

## Trigger a PostgreSQL backup on the remote server
backup:
	ssh $(SIEM_SERVER_USER)@$(SIEM_SERVER_IP) \
	  "sudo systemctl start pg-backup.service && journalctl -u pg-backup.service -n 20 --no-pager"

## Deploy the SIEM server stack (runs backup first if pg-backup.timer exists)
deploy: _pre-deploy-backup
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY)

## Deploy only the SIEM server (runs backup first)
deploy-siem: _pre-deploy-backup
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server

## Deploy only Grafana dashboards (no stack restart)
deploy-dashboards:
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags dashboards

## Update ntfy-client.env on all hosts (after rotating NTFY_TOKEN)
deploy-ntfy-client:
	$(INFISICAL_RUN) ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags ntfy_client_env

## Deploy Infisical itself — uses .env directly (bootstrapping: Infisical isn't running yet)
deploy-infisical:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags infisical

_pre-deploy-backup:
	@ssh $(SIEM_SERVER_USER)@$(SIEM_SERVER_IP) \
	  "systemctl list-units --type=service --all | grep -q pg-backup.service \
	   && sudo systemctl start pg-backup.service \
	   && echo '[backup] pre-deploy snapshot complete' \
	   || echo '[backup] pg-backup not yet installed, skipping'"

## Dry-run (no changes applied)
check:
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
	@infisical export \
	  --projectId $(INFISICAL_PROJECT_ID) \
	  --env prod \
	  --domain $(INFISICAL_API_URL) \
	  --format dotenv
