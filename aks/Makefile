TERRAFORM_DIR := terraform
TFVARS := $(TERRAFORM_DIR)/terraform.tfvars
JOIN_TOKEN_FILE := $(TERRAFORM_DIR)/.join-token
JOIN_TOKEN_TTL ?= 2h


.PHONY: targets
targets:
	@awk -F: '/^[^ \.]*:/ { print $$1 }' Makefile

.PHONY: generate role join-token check-binary

# Render role.yaml from the Terraform-managed user-assigned identity. Run
# `make tf/apply` first.
generate: role

role: role.yaml.tpl
	@command -v terraform >/dev/null || { echo "terraform not found"; exit 1; }
	@MANAGED_IDENTITY_ID=$$(terraform -chdir=$(TERRAFORM_DIR) output -no-color -raw managed_identity_id 2>/dev/null) && \
	case "$$MANAGED_IDENTITY_ID" in /subscriptions/*) ;; *) echo "managed_identity_id terraform output is missing; run 'make tf/apply' first"; exit 1 ;; esac && \
	export MANAGED_IDENTITY_ID && \
	envsubst '$$MANAGED_IDENTITY_ID' < role.yaml.tpl > role.yaml
	@echo "Wrote role.yaml"

join-token:
	@command -v tctl >/dev/null || { echo "tctl not found"; exit 1; }
	@command -v jq >/dev/null || { echo "jq not found"; exit 1; }
	@TOKEN=$$(tctl tokens add --type=app --ttl=$(JOIN_TOKEN_TTL) --format=json | jq -r '(if type == "array" then .[0] else . end) | .metadata.name // .token // .name // empty') && \
	test -n "$$TOKEN" || { echo "failed to parse token from tctl output"; exit 1; } && \
	printf '%s\n' "$$TOKEN" > "$(JOIN_TOKEN_FILE)" && \
	echo "Wrote $(JOIN_TOKEN_FILE) with new app join token (ttl $(JOIN_TOKEN_TTL))"

check-binary:
	@test -f "$(TFVARS)" || { echo "$(TFVARS) not found; copy terraform.tfvars.example first"; exit 1; }
	@BINARY=$$(sed -n 's/^[[:space:]]*teleport_binary_path[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$(TFVARS)"); \
	test -n "$$BINARY" || { echo "teleport_binary_path is missing from $(TFVARS)"; exit 1; }; \
	case "$$BINARY" in \
		"~/"*) BINARY="$$HOME/$${BINARY#\~/}" ;; \
		/*) ;; \
		*) BINARY="$(TERRAFORM_DIR)/$$BINARY" ;; \
	esac; \
	test -f "$$BINARY" || { echo "teleport_binary_path does not exist: $$BINARY"; exit 1; }; \
	echo "Using Teleport binary: $$BINARY"

.PHONY: tf/init tf/plan tf/apply tf/destroy tf/output tf/repair-kube-deployment tf/clean blob/taint

tf/init:
	terraform -chdir=$(TERRAFORM_DIR) init

tf/plan: check-binary
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=terraform.tfvars

tf/apply: check-binary
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=terraform.tfvars

tf/destroy:
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=terraform.tfvars

tf/output:
	terraform -chdir=$(TERRAFORM_DIR) output

tf/repair-kube-deployment:
	terraform -chdir=$(TERRAFORM_DIR) state rm kubernetes_deployment_v1.teleport
	terraform -chdir=$(TERRAFORM_DIR) import kubernetes_deployment_v1.teleport teleport/teleport-app-service

tf/clean:
	-rm -f ./terraform/terraform.tfstate
	-rm -f ./terraform/terraform.tfstate.*

blob/taint:
	terraform -chdir=$(TERRAFORM_DIR) taint azurerm_storage_blob.teleport_binary

.PHONY: cluster

# Create/update the Azure resources and initialize kubectl for the AKS cluster.
cluster: join-token tf/init tf/apply kube/config

.PHONY: agent/rebuild

# Rebuild the AKS Teleport app_service pod with a fresh join token and binary.
agent/rebuild: join-token blob/taint tf/apply kube/restart-pod kube/pods

.PHONY: kube/configure kube/config kube/pods kube/logs kube/init-logs kube/events kube/restart-pod

# Initialize kubectl for the AKS cluster created by Terraform.
kube/configure: kube/config

kube/config:
	@command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
	@command -v terraform >/dev/null || { echo "terraform not found"; exit 1; }
	@RG=$$(terraform -chdir=$(TERRAFORM_DIR) output -no-color -raw resource_group_name) && \
	AKS=$$(terraform -chdir=$(TERRAFORM_DIR) output -no-color -raw aks_cluster_name) && \
	az aks get-credentials -g "$$RG" -n "$$AKS" --overwrite-existing

kube/pods: kube/config
	kubectl -n teleport get pods

kube/logs: kube/config
	kubectl -n teleport logs deploy/teleport-app-service

kube/init-logs: kube/config
	@POD=$$(kubectl -n teleport get pod -l app=teleport-app-service -o jsonpath='{.items[0].metadata.name}') && \
	kubectl -n teleport logs "$$POD" -c check-teleport-proxy --previous || \
	kubectl -n teleport logs "$$POD" -c check-teleport-proxy

kube/events: kube/config
	kubectl -n teleport get events --sort-by=.lastTimestamp

kube/restart-pod: kube/config
	kubectl -n teleport delete pod -l app=teleport-app-service

.PHONY: clean clean-genarated

clean: clean-generated

clean-generated:
	rm -f role.yaml
	rm -f terraform/.join-token
