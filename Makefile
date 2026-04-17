.PHONY: deploy check install-deps

-include .env
export

PLAYBOOK   = ansible/site.yml
INVENTORY  = ansible/inventory/hosts.ini

## Deploy the SIEM server stack
deploy:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY)

## Dry-run (no changes applied)
check:
	ansible-playbook $(PLAYBOOK) -i $(INVENTORY) --check

## Install required Ansible collections
install-deps:
	ansible-galaxy collection install -r ansible/requirements.yml
