# Azure CLI access via Teleport

End-to-end setup for proxying `az` through Teleport using an Azure user-assigned
managed identity. This walks through provisioning the Azure side, rendering
the Teleport `role`/`token` resources with live values, and verifying access
with `tsh az`.

## Prerequisites

- `az` CLI, `terraform`, `envsubst`, `tctl`, and `tsh` on your PATH
- A Teleport cluster you can reach with `tctl` (admin) and `tsh` (user)
- An Azure subscription you can create resources in
- A Linux Teleport binary for the VM architecture, referenced by `teleport_binary_path` in `terraform.tfvars`

## 1. Log into Azure

```sh
az login
az account set --subscription <SUBSCRIPTION_ID>   # only if you have multiple
az account show --query id -o tsv                 # sanity check
```

`make` reads the active subscription via `az account show`, so make sure the
right one is selected before generating files.

## 2. Render the join token

```sh
make join
```

This produces `join.yaml` from `join.yaml.tpl` with the live subscription ID.

## 3. Generate the VM SSH key

```sh
make ssh-key
```

This creates `id_rsa_azure` / `id_rsa_azure.pub` in this directory using a
4096-bit RSA key (Azure rejects ed25519 at VM provisioning). The target is
idempotent — it does nothing if the files already exist. Terraform reads the
public key from `../id_rsa_azure.pub` by default; override
`admin_ssh_public_key_path` in `terraform.tfvars` to use a different key.

## 4. Provision Azure resources

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit values for your env
vim terraform.tfvars
```

At minimum set `teleport_proxy_address` and `teleport_binary_path`. The binary
path is read by Terraform, so relative paths are resolved from the `terraform/`
directory. Then:

```sh
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Apply creates the resource group, user-assigned managed identity, role
assignments, test storage account/container, uploads the Teleport binary to
Blob Storage, and creates a Linux VM that installs Azure CLI, downloads the
binary with `az storage blob download`, and runs that binary as the
Teleport Application Service. The VM joins the cluster using the Azure
delegated join method — no static token needs to be placed on the host.

When done, return to the parent directory:

```sh
cd ..
```

## 5. Render the Teleport role

```sh
make role
```

This reads `managed_identity_id` from terraform output and the subscription
from `az account show`, then renders `role.yaml` from `role.yaml.tpl`.

Tip: `make generate` runs both `join` and `role` in one shot.

## Recreate The VM With A New Binary

After rebuilding Teleport locally, re-upload the binary and force a fresh VM so
cloud-init downloads and runs it again:

```sh
make vm/recreate-binary TELEPORT_BINARY_PATH=../teleport
```

If `teleport_binary_path` is already set in `terraform/terraform.tfvars`, you can
omit `TELEPORT_BINARY_PATH`. Add `TF_APPLY_ARGS=-auto-approve` when you want a
non-interactive apply.

## 6. Create the Teleport resources

```sh
tctl create -f join.yaml
tctl create -f role.yaml
```

## 7. Assign the role to your Teleport user

```sh
tctl users update <your-teleport-user> --set-roles <existing-roles>,azure-cli-access
```

Replace `<existing-roles>` with the comma-separated list of roles the user
already has (see `tctl users ls`). You may need to log out and back in with
`tsh logout && tsh login ...` for the new role to take effect.

## 8. Use `tsh az`

Log into the Azure CLI app through Teleport, selecting the managed identity:

```sh
tsh apps login azure-cli --azure-identity ...
```

Then run `az` commands proxied through Teleport:

```sh
tsh az account show
tsh az storage account list
tsh az storage container list --account-name <storage-account> --auth-mode login
```

The storage account name and container created by terraform are available as
outputs:

```sh
terraform -chdir=terraform output storage_account_name
terraform -chdir=terraform output storage_container_name
```

## Tear-down

```sh
terraform -chdir=terraform destroy -var-file=terraform/terraform.tfvars
tctl rm role/azure-cli-access
tctl rm token/azure-token
make clean-generated
```
