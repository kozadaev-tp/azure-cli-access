# Teleport Workload Identity with an Entra App Registration

This PoC runs `tbot` on an Azure VM, issues a Teleport JWT SVID, and exchanges
that JWT for an Azure access token belonging to an Entra App Registration. It
validates that Teleport Workload Identity federation supports App Registration
service principals without a client secret.

The VM's user-assigned managed identity is only used to join `tbot` to Teleport
and download the `tbot` binary. The workload authenticates as a separate App
Registration provisioned by Terraform.

## Prerequisites

- `az`, `terraform`, `envsubst`, and `tctl` on your PATH.
- An active Azure CLI session for the target subscription.
- An active `tctl` session with permission to create roles, bots, workload
  identities, and join tokens.
- Permission in Entra ID to create App Registrations, service principals, and
  federated identity credentials. An Application Administrator or equivalent
  role may be required.
- A Linux AMD64 `tbot` binary. The configured local build is uploaded to private
  Blob Storage and downloaded by the VM during cloud-init.
- A publicly reachable Teleport Workload Identity OIDC discovery endpoint.

For this environment, the discovery document is:

```text
https://snobb.co.uk/workload-identity/.well-known/openid-configuration
```

## How it works

1. The VM authenticates with its attached UAMI and joins Teleport using the
   Azure delegated join method.
2. `tbot` requests the `azure-app-registration` Workload Identity and writes a
   JWT SVID to `/opt/workload-identity/jwt_svid`.
3. The App Registration trusts exactly this issuer, subject, and audience:

```text
issuer:   https://snobb.co.uk/workload-identity
subject:  spiffe://snobb.co.uk/svc/azure-app-registration
audience: api://AzureADTokenExchange
```

4. Azure CLI sends the JWT to Microsoft Entra's token endpoint as a federated
   client assertion.
5. Entra issues an access token for the App Registration's service principal.
6. The test uploads and downloads a blob using that token.

No client secret or certificate is created.

## Configure

Create the local variable file:

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set at least:

```hcl
teleport_proxy_address = "example.teleport.sh:443"
teleport_cluster_name  = "example.teleport.sh"
tbot_binary_path       = "/path/to/linux-amd64/tbot"
```

`teleport_cluster_name` is the Teleport cluster name, not necessarily the Proxy
DNS name. It becomes the SPIFFE trust domain and must match the `sub` claim in
the JWT SVID.

## Provision

Log in to Azure and Teleport:

```sh
az login
az account set --subscription <subscription-id>
tsh login --proxy=<teleport-proxy>
```

Render and inspect the Teleport resources:

```sh
make cluster/render
cat teleport-resources.yaml
```

Provision the Teleport resources and Azure infrastructure:

```sh
make vm/create
```

This operation converts the previous Application Access lab. Terraform will
remove its Key Vault and Azure Application Access role assignments and recreate
the VM with `tbot` cloud-init.

To inspect the infrastructure change first:

```sh
make tf/init
make tf/plan
```

## Verify

Check cloud-init and `tbot`:

```sh
make vm/status
make vm/logs
```

Run the complete exchange test on the VM:

```sh
make vm/test
```

The test:

- validates the JWT's issuer, subject, and audience;
- runs `az login --service-principal --federated-token ...`;
- prints the Azure CLI account identity;
- uploads, downloads, compares, and deletes a test blob.

Successful Azure CLI output should identify the account as a
`servicePrincipal` whose name is the Terraform `application_client_id` output.

Federated identity credentials and Azure role assignments can take several
minutes to propagate. Retry `make vm/test` if the initial exchange or blob
operation is rejected immediately after provisioning.

Useful outputs:

```sh
make tf/output
terraform -chdir=terraform output application_client_id
terraform -chdir=terraform output workload_identity_issuer
terraform -chdir=terraform output workload_identity_subject
```

## Rebuild tbot

After rebuilding the local Linux `tbot` binary:

```sh
make agent/rebuild
```

Use `TBOT_BINARY_PATH=/other/path/tbot` to override the path in
`terraform.tfvars` for one invocation.

## Tear down

```sh
make tf/destroy
tctl rm token/azure-app-registration-bot
tctl rm bot/azure-app-registration
tctl rm workload_identity/azure-app-registration
tctl rm role/azure-app-registration-issuer
make clean-generated
```
