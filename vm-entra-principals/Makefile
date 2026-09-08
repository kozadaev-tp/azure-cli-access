TERRAFORM_DIR := terraform
SSH_KEY := id_rsa_azure
TFVARS ?= terraform.tfvars
TFVARS_FILE = $(if $(filter /%,$(TFVARS)),$(TFVARS),$(TERRAFORM_DIR)/$(TFVARS))
TBOT_BINARY_PATH ?=
TF_APPLY_ARGS ?=

.PHONY: targets
targets:
	@awk -F: '/^[[:alnum:]_\/-]+:/ { print $$1 }' Makefile

.PHONY: cluster/render cluster/apply ssh-key check-binary

cluster/render: teleport-resources.yaml.tpl
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@SUBSCRIPTION_ID=$$(az account show --query id -o tsv) && \
	export SUBSCRIPTION_ID && \
	envsubst '$$SUBSCRIPTION_ID' < teleport-resources.yaml.tpl > teleport-resources.yaml
	@echo "Wrote teleport-resources.yaml"

cluster/apply: cluster/render
	@command -v tctl >/dev/null || { echo "tctl not found"; exit 1; }
	tctl create -f teleport-resources.yaml

ssh-key: $(SSH_KEY)

$(SSH_KEY):
	ssh-keygen -t rsa -b 4096 -f $(SSH_KEY) -C "azure-tbot-vm" -N ""

check-binary:
	@test -f "$(TFVARS_FILE)" || { echo "$(TFVARS_FILE) not found; copy terraform.tfvars.example first"; exit 1; }
	@BINARY='$(TBOT_BINARY_PATH)'; \
	if test -z "$$BINARY"; then \
		BINARY=$$(sed -n 's/^[[:space:]]*tbot_binary_path[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$(TFVARS_FILE)"); \
	fi; \
	test -n "$$BINARY" || { echo "tbot_binary_path is missing from $(TFVARS_FILE)"; exit 1; }; \
	case "$$BINARY" in \
		"~/"*) BINARY="$$HOME/$${BINARY#\~/}" ;; \
		/*) ;; \
		*) BINARY="$(TERRAFORM_DIR)/$$BINARY" ;; \
	esac; \
	test -f "$$BINARY" || { echo "tbot_binary_path does not exist: $$BINARY"; exit 1; }; \
	echo "Using tbot binary: $$BINARY"

.PHONY: tf/init tf/plan tf/apply tf/destroy tf/output

tf/init:
	terraform -chdir=$(TERRAFORM_DIR) init

tf/plan: check-binary ssh-key
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=$(TFVARS) \
		$(if $(TBOT_BINARY_PATH),-var='tbot_binary_path=$(TBOT_BINARY_PATH)',)

tf/apply: check-binary ssh-key
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=$(TFVARS) \
		$(if $(TBOT_BINARY_PATH),-var='tbot_binary_path=$(TBOT_BINARY_PATH)',) \
		$(TF_APPLY_ARGS)

tf/destroy:
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=$(TFVARS) $(TF_APPLY_ARGS)

tf/output:
	terraform -chdir=$(TERRAFORM_DIR) output

.PHONY: vm/create agent/rebuild vm/status vm/ssh vm/logs vm/restart vm/test

vm/create:
	$(MAKE) cluster/apply
	$(MAKE) tf/init
	$(MAKE) tf/apply

agent/rebuild: check-binary ssh-key
	@command -v terraform >/dev/null || { echo "terraform not found"; exit 1; }
	terraform -chdir=$(TERRAFORM_DIR) apply \
		-var-file=$(TFVARS) \
		$(if $(TBOT_BINARY_PATH),-var='tbot_binary_path=$(TBOT_BINARY_PATH)',) \
		-replace=azurerm_storage_blob.tbot_binary \
		-replace=azurerm_linux_virtual_machine.this \
		$(TF_APPLY_ARGS)

vm/status:
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@RG=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw resource_group_name) && \
	VM=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_name) && \
	az vm get-instance-view -g "$$RG" -n "$$VM" --query 'instanceView.statuses[].displayStatus' -o tsv

vm/ssh:
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_command) && cd terraform && $$SSH

vm/logs:
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_command) && cd terraform && \
	$$SSH sudo journalctl -u tbot -n 200 --no-pager

vm/restart:
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_command) && cd terraform && \
	$$SSH sudo systemctl restart tbot

vm/test:
	@TEST=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw test_command) && cd terraform && $$TEST

.PHONY: clean clean-generated

clean: clean-generated

clean-generated:
	rm -f teleport-resources.yaml
