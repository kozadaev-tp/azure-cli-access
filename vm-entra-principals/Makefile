TERRAFORM_DIR := terraform
SSH_KEY := id_rsa_azure
TFVARS ?= terraform.tfvars
TFVARS_FILE = $(if $(filter /%,$(TFVARS)),$(TFVARS),$(TERRAFORM_DIR)/$(TFVARS))
TSH_BINARY_PATH ?=
TF_APPLY_ARGS ?=

.PHONY: targets
targets:
	@awk -F: '/^[[:alnum:]_\/-]+:/ { print $$1 }' Makefile

.PHONY: cluster/apply cluster/remove-legacy-bot ssh-key check-tsh-binary

cluster/apply:
	@command -v tctl >/dev/null || { echo "tctl not found"; exit 1; }
	tctl create -f teleport-resources.yaml

cluster/remove-legacy-bot:
	@command -v tctl >/dev/null || { echo "tctl not found"; exit 1; }
	-tctl rm token/azure-app-registration-bot
	-tctl rm bot/azure-app-registration

ssh-key: $(SSH_KEY)

$(SSH_KEY):
	ssh-keygen -t rsa -b 4096 -f $(SSH_KEY) -C "azure-tsh-vm" -N ""

check-tsh-binary:
	@test -f "$(TFVARS_FILE)" || { echo "$(TFVARS_FILE) not found; copy terraform.tfvars.example first"; exit 1; }
	@BINARY='$(TSH_BINARY_PATH)'; \
	if test -z "$$BINARY"; then \
		BINARY=$$(sed -n 's/^[[:space:]]*tsh_binary_path[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$(TFVARS_FILE)"); \
	fi; \
	test -n "$$BINARY" || { echo "tsh_binary_path is missing from $(TFVARS_FILE)"; exit 1; }; \
	case "$$BINARY" in \
		"~/"*) BINARY="$$HOME/$${BINARY#\~/}" ;; \
		/*) ;; \
		*) BINARY="$(TERRAFORM_DIR)/$$BINARY" ;; \
	esac; \
	test -f "$$BINARY" || { echo "tsh_binary_path does not exist: $$BINARY"; exit 1; }; \
	FORMAT=$$(file -b "$$BINARY"); \
	case "$$FORMAT" in *ELF*x86-64*) ;; *) echo "tsh binary must be Linux AMD64; found: $$FORMAT"; exit 1 ;; esac; \
	echo "Using tsh binary: $$BINARY"

.PHONY: tf/init tf/plan tf/apply tf/destroy tf/output

tf/init:
	terraform -chdir=$(TERRAFORM_DIR) init

tf/plan: ssh-key
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=$(TFVARS)

tf/apply: ssh-key
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=$(TFVARS) \
		$(TF_APPLY_ARGS)

tf/destroy:
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=$(TFVARS) $(TF_APPLY_ARGS)

tf/output:
	terraform -chdir=$(TERRAFORM_DIR) output

.PHONY: vm/create tsh/upload vm/status vm/ssh vm/cloud-init vm/test

vm/create:
	$(MAKE) cluster/apply
	$(MAKE) tf/init
	$(MAKE) tf/apply
	$(MAKE) tsh/upload

tsh/upload: check-tsh-binary ssh-key
	@BINARY='$(TSH_BINARY_PATH)'; \
	if test -z "$$BINARY"; then \
		BINARY=$$(sed -n 's/^[[:space:]]*tsh_binary_path[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$(TFVARS_FILE)"); \
	fi; \
	case "$$BINARY" in \
		"~/"*) BINARY="$$HOME/$${BINARY#\~/}" ;; \
		/*) ;; \
		*) BINARY="$(TERRAFORM_DIR)/$$BINARY" ;; \
	esac; \
	IP=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_public_ip) && \
	USER=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_admin_username) && \
	SSH_OPTIONS='-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new' && \
	CONNECTED=false && \
	for attempt in $$(seq 1 30); do \
		if ssh -i "$(SSH_KEY)" $$SSH_OPTIONS "$$USER@$$IP" true; then \
			CONNECTED=true; \
			break; \
		fi; \
		echo "waiting for VM SSH ($$attempt/30)"; \
		sleep 10; \
	done; \
	test "$$CONNECTED" = true || { echo "unable to connect to $$USER@$$IP; remove a stale SSH host key and retry"; exit 1; }; \
	scp -i "$(SSH_KEY)" $$SSH_OPTIONS "$$BINARY" "$$USER@$$IP:/tmp/tsh" && \
	ssh -i "$(SSH_KEY)" $$SSH_OPTIONS "$$USER@$$IP" 'sudo install -o root -g root -m 0755 /tmp/tsh /usr/local/bin/tsh && rm -f /tmp/tsh' && \
	echo "Installed tsh on $$USER@$$IP"

vm/status:
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@RG=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw resource_group_name) && \
	VM=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_name) && \
	az vm get-instance-view -g "$$RG" -n "$$VM" --query 'instanceView.statuses[].displayStatus' -o tsv

vm/ssh:
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_command) && $$SSH

vm/cloud-init:
	@SSH=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_command) && \
	$$SSH sudo cloud-init status --wait

vm/test:
	@TEST=$$(terraform -chdir=$(TERRAFORM_DIR) output -raw test_command) && $$TEST
