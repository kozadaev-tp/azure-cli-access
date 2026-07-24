# Azure CLI Access Via Teleport On AKS

End-to-end repro for running Teleport `app_service` in AKS with Azure Workload
Identity, then using `tsh az` against Azure resources. Terraform uploads a local
instrumented Teleport binary to Blob Storage and the AKS pod downloads and runs
that binary.

## Prerequisites

- `az`, `terraform`, `kubectl`, `envsubst`, `jq`, `tctl`, and `tsh` on your PATH
- A Teleport cluster you can reach with `tctl` and `tsh`
- An Azure subscription where you can create AKS, managed identities, RBAC, Key Vault, and Storage resources
- A Linux Teleport binary for the AKS node architecture, referenced by `teleport_binary_path` in `terraform.tfvars`

## 1. Log Into Azure

```sh
az login
az account set --subscription <SUBSCRIPTION_ID>
az account show --query id -o tsv
```

## 2. Configure Terraform

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
cd ..
```

Set at least:

```hcl
teleport_proxy_address = "teleport.example.com:443"
teleport_join_token_file = ".join-token"
teleport_binary_path   = "../teleport"
```

If your Teleport cluster is local behind a tunnel, use the tunnel's public FQDN
and port 443 for `teleport_proxy_address`. The AKS pod must be able to reach
`https://<teleport_proxy_address>/webapi/ping`; Terraform deploys an init
container that checks this before Teleport starts.

If the tunnel is interrupted, restore it and restart the stuck pod:

```sh
make kube/restart-pod
make kube/init-logs
```

## 3. Create A Teleport App Join Token

Use a static app token so the repro focuses on Azure Workload Identity for app
credentials, not on Teleport join authentication.

```sh
make join-token
```

This creates an app join token with `tctl` and writes it to `terraform/.join-token`.
Terraform reads that file via `teleport_join_token_file`. The default TTL is 2
hours; override it when needed:

```sh
make join-token JOIN_TOKEN_TTL=4h
```

If the token expired before the pod joined, rebuild the app service with a fresh
token:

```sh
make agent/rebuild
```

This regenerates `terraform/.join-token`, reapplies Terraform so the Kubernetes
secret is updated, restarts the Teleport pod, and shows pod status.

## 4. Provision The Repro

```sh
make tf/init
make tf/plan
make tf/apply
```

Or run the apply and initialize `kubectl` in one step:

```sh
make cluster
```

`make cluster` also runs `make join-token` first, so the static app token file
exists before Terraform reads it.

Terraform creates the resource group, user-assigned identity, RBAC assignments,
test Storage/Key Vault resources, AKS with Workload Identity enabled, an Azure
federated identity credential, and the Teleport `app_service` Deployment.

## 5. Initialize Kubernetes Access

```sh
make kube/configure
make kube/pods
make kube/logs
```

## 6. Create The Teleport Role

```sh
make role
tctl create -f role.yaml
```

Assign the role to your Teleport user:

```sh
tctl users update <your-teleport-user> --set-roles <existing-roles>,azure-cli-access
```

Log out and back in if needed:

```sh
tsh logout
tsh login --proxy=<proxy>
```

## 7. Reproduce With `tsh az`

Use the generated output for the exact login command:

```sh
terraform -chdir=terraform output tsh_apps_login_command
```

Then run workload-identity-backed Azure CLI commands through Teleport:

```sh
tsh az account show
tsh az keyvault list
tsh az keyvault secret show --vault-name <vault> --name dummy-api-token
```

Useful outputs:

```sh
terraform -chdir=terraform output key_vault_name
terraform -chdir=terraform output storage_account_name
terraform -chdir=terraform output az_keyvault_secret_show_commands
```

## Tear Down

```sh
terraform -chdir=terraform destroy -var-file=terraform.tfvars
tctl rm role/azure-cli-access
make clean-generated
```
