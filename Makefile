.PHONY: all clean deploy check install-deps backup test

-include .env
export

PLAYBOOK   = ansible/site.yml
INVENTORY  = ansible/inventory/hosts.ini

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
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY)

## Deploy only the SIEM server (runs backup first)
deploy-siem: _pre-deploy-backup
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --limit siem_server

## Deploy only Grafana dashboards (no stack restart)
deploy-dashboards:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --tags dashboards

_pre-deploy-backup:
	@ssh $(SIEM_SERVER_USER)@$(SIEM_SERVER_IP) \
	  "systemctl list-units --type=service --all | grep -q pg-backup.service \
	   && sudo systemctl start pg-backup.service \
	   && echo '[backup] pre-deploy snapshot complete' \
	   || echo '[backup] pg-backup not yet installed, skipping'"

## Dry-run (no changes applied)
check:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --check

## Install required Ansible collections
install-deps:
	ansible-galaxy collection install -r ansible/requirements.yml

## Run linters locally (requires: pip install yamllint ansible-lint)
test:
	yamllint .
	ansible-lint $(PLAYBOOK)
