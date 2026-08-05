TERRAFORM_DIR := terraform
SSH_KEY := id_rsa_azure
TFVARS ?= terraform.tfvars
TFVARS_FILE = $(if $(filter /%,$(TFVARS)),$(TFVARS),$(TERRAFORM_DIR)/$(TFVARS))
TELEPORT_BINARY_PATH ?=
TF_APPLY_ARGS ?=

.PHONY: targets
targets:
	@awk -F: '/^[[:alnum:]_\/-]+:/ { print $$1 }' Makefile

.PHONY: generate role join join/apply ssh-key check-binary

# Render role.yaml and join.yaml from templates, substituting the current
# Azure subscription (via `az account show`) and the managed identity URI
# (from terraform output). Run `terraform apply` in ./terraform first.
generate: role join

role: role.yaml.tpl
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@command -v terraform >/dev/null || { echo "terraform not found"; exit 1; }
	@SUBSCRIPTION_ID=$$(az account show --query id -o tsv) && \
	MANAGED_IDENTITY_ID=$$(terraform -chdir=$(TERRAFORM_DIR) output -no-color -raw managed_identity_id 2>/dev/null) && \
	case "$$MANAGED_IDENTITY_ID" in /subscriptions/*) ;; *) echo "managed_identity_id terraform output is missing — did you run 'terraform apply' in $(TERRAFORM_DIR)?"; exit 1 ;; esac && \
	export SUBSCRIPTION_ID MANAGED_IDENTITY_ID && \
	envsubst '$$SUBSCRIPTION_ID $$MANAGED_IDENTITY_ID' < role.yaml.tpl > role.yaml
	@echo "Wrote role.yaml"

join: join.yaml.tpl
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@SUBSCRIPTION_ID=$$(az account show --query id -o tsv) && \
	export SUBSCRIPTION_ID && \
	envsubst '$$SUBSCRIPTION_ID' < join.yaml.tpl > join.yaml
	@echo "Wrote join.yaml"

join/apply: join
	@command -v tctl >/dev/null || { echo "tctl not found"; exit 1; }
	tctl create -f join.yaml

ssh-key: $(SSH_KEY)

$(SSH_KEY):
	ssh-keygen -t rsa -b 4096 -f $(SSH_KEY) -C "azure-teleport-vm" -N ""

check-binary:
	@test -f "$(TFVARS_FILE)" || { echo "$(TFVARS_FILE) not found; copy terraform.tfvars.example first"; exit 1; }
	@BINARY='$(TELEPORT_BINARY_PATH)'; \
	if test -z "$$BINARY"; then \
		BINARY=$$(sed -n 's/^[[:space:]]*teleport_binary_path[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$(TFVARS_FILE)"); \
	fi; \
	test -n "$$BINARY" || { echo "teleport_binary_path is missing from $(TFVARS_FILE)"; exit 1; }; \
	case "$$BINARY" in \
		"~/"*) BINARY="$$HOME/$${BINARY#\~/}" ;; \
		/*) ;; \
		*) BINARY="$(TERRAFORM_DIR)/$$BINARY" ;; \
	esac; \
	test -f "$$BINARY" || { echo "teleport_binary_path does not exist: $$BINARY"; exit 1; }; \
	echo "Using Teleport binary: $$BINARY"

.PHONY: tf/init tf/plan tf/apply tf/destroy tf/output tf/clean blob/taint

tf/init:
	terraform -chdir=$(TERRAFORM_DIR) init

tf/plan: check-binary ssh-key
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=$(TFVARS) \
		$(if $(TELEPORT_BINARY_PATH),-var='teleport_binary_path=$(TELEPORT_BINARY_PATH)',)

tf/apply: check-binary ssh-key
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=$(TFVARS) \
		$(if $(TELEPORT_BINARY_PATH),-var='teleport_binary_path=$(TELEPORT_BINARY_PATH)',) \
		$(TF_APPLY_ARGS)

tf/destroy:
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=$(TFVARS) $(TF_APPLY_ARGS)

tf/output:
	terraform -chdir=$(TERRAFORM_DIR) output

tf/clean:
	-rm -f $(TERRAFORM_DIR)/terraform.tfstate
	-rm -f $(TERRAFORM_DIR)/terraform.tfstate.*

blob/taint:
	terraform -chdir=$(TERRAFORM_DIR) taint azurerm_storage_blob.teleport_binary

.PHONY: vm/create agent/rebuild vm/status vm/ssh vm/logs vm/restart

# Create/update the Teleport join resource and Azure VM in dependency order.
vm/create:
	$(MAKE) join/apply
	$(MAKE) tf/init
	$(MAKE) tf/apply

# Re-upload the Teleport binary and recreate the VM so cloud-init installs it.
agent/rebuild: check-binary ssh-key
	@command -v terraform >/dev/null || { echo "terraform not found"; exit 1; }
	terraform -chdir=$(TERRAFORM_DIR) apply \
		-var-file=$(TFVARS) \
		$(if $(TELEPORT_BINARY_PATH),-var='teleport_binary_path=$(TELEPORT_BINARY_PATH)',) \
		-replace=azurerm_storage_blob.teleport_binary \
		-replace=azurerm_linux_virtual_machine.this \
		$(TF_APPLY_ARGS)

vm/status:
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@RG=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw resource_group_name) && \
	VM=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_name) && \
	az vm get-instance-view -g "$$RG" -n "$$VM" --query 'instanceView.statuses[].displayStatus' -o tsv

vm/ssh:
	@command -v tsh >/dev/null || { echo "tsh not found"; exit 1; }
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw tsh_ssh_command) && $$SSH

vm/logs:
	@command -v tsh >/dev/null || { echo "tsh not found"; exit 1; }
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw tsh_ssh_command) && \
	$$SSH sudo journalctl -u teleport -n 200 --no-pager

vm/restart:
	@command -v tsh >/dev/null || { echo "tsh not found"; exit 1; }
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw tsh_ssh_command) && \
	$$SSH sudo systemctl restart teleport

.PHONY: clean clean-generated

clean: clean-generated

clean-generated:
	rm -f role.yaml join.yaml
