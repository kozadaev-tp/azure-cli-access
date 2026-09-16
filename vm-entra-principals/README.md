# Teleport Workload Identity with an Entra App Registration

This PoC uses `tsh` on an Azure VM to request a Teleport JWT SVID and exchange
it for an Azure access token belonging to an Entra App Registration. It
validates that Teleport Workload Identity federation supports App Registration
service principals without a client secret or certificate.

The PoC intentionally does not run `tbot`. A Teleport user approves each
headless `tsh` request, making this a manual testing and debugging workflow
rather than an unattended workload deployment.

## Prerequisites

- `az`, `terraform`, `tctl`, and `tsh` on your workstation PATH.
- An active Azure CLI session for the target subscription.
- An active `tctl` session with permission to create roles and Workload
  Identities.
- A Teleport user that can be assigned the `azure-app-registration-issuer`
  role.
- Permission in Entra ID to create App Registrations, service principals, and
  federated identity credentials. An Application Administrator or equivalent
  role may be required.
- A Linux AMD64 `tsh` binary compatible with the Teleport cluster.
- A publicly reachable Teleport Workload Identity OIDC discovery endpoint.

For this environment, the discovery document is:

```text
https://snobb.co.uk/workload-identity/.well-known/openid-configuration
```

## How it works

1. Terraform creates an App Registration, its service principal, a federated
   identity credential, an Azure VM, and Blob Storage test resources.
2. The Makefile uploads a locally built Linux `tsh` binary to the VM over SSH.
3. The test invokes `tsh workload-identity issue-jwt` on the VM using headless
   authentication. The configured Teleport user approves the request.
4. Teleport issues a five-minute JWT SVID with these claims:

```text
issuer:   https://snobb.co.uk/workload-identity
subject:  spiffe://snobb.co.uk/svc/azure-app-registration
audience: api://AzureADTokenExchange
```

5. Azure CLI sends the JWT to Microsoft Entra as a federated client assertion.
6. Entra issues an access token for the App Registration service principal.
7. The test uploads, downloads, compares, and deletes a blob using that token.

The JWT SVID and Azure CLI token cache are stored in temporary directories and
removed after each test.

## Configure

Create the local variable file:

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set at least:

```hcl
teleport_proxy_address = "example.teleport.sh:443"
teleport_cluster_name  = "example.teleport.sh"
teleport_user          = "alice@example.com"
tsh_binary_path        = "~/projects/teleport-build.git/builds/linux/tsh"
```

`teleport_cluster_name` is the Teleport cluster name, not necessarily the Proxy
DNS name. It becomes the SPIFFE trust domain and must match the `sub` claim in
the JWT SVID.

Build the Linux AMD64 `tsh` binary used by this development environment from
the Teleport source checkout:

```sh
mkdir -p ~/projects/teleport-build.git/builds/linux
cd ~/projects/core.git
CC=/opt/homebrew/bin/x86_64-unknown-linux-gnu-gcc \
  GOOS=linux \
  GOARCH=amd64 \
  CGO_ENABLED=1 \
  go build \
    -buildvcs=false \
    -tags "webassets_embed webassets" \
    -o ~/projects/teleport-build.git/builds/linux/tsh \
    -trimpath \
    -buildmode=pie \
    ./tool/tsh
```

The Makefile rejects a binary that is not an x86-64 Linux ELF executable.

## Configure Teleport

Log in to Teleport and apply the role and Workload Identity:

```sh
tsh login --proxy=<teleport-proxy> --user=<teleport-user>
make cluster/apply
```

Assign `azure-app-registration-issuer` to the Teleport user configured by
`teleport_user`. For a local user, first inspect its existing roles:

```sh
tctl get user/<teleport-user> --format=yaml
```

Then include all existing roles when updating the user, because `--set-roles`
replaces the complete role list:

```sh
tctl users update <teleport-user> \
  --set-roles=<existing-role-1>,<existing-role-2>,azure-app-registration-issuer
```

For an SSO user, add `azure-app-registration-issuer` to the appropriate OIDC,
SAML, or GitHub connector role mapping instead of modifying the ephemeral user
resource.

If this environment previously ran the `tbot` version of the PoC, remove its
obsolete Bot and Azure join token:

```sh
make cluster/remove-legacy-bot
```

## Provision Azure

Log in to Azure and select the target subscription:

```sh
az login
az account set --subscription <subscription-id>
```

Inspect the infrastructure change:

```sh
make tf/init
make tf/plan
```

Provision the Azure resources and upload `tsh`:

```sh
make vm/create
```

Migrating an existing deployment removes the VM UAMI, delegated-join RBAC, and
private `tbot` binary blob. Changing VM cloud-init may replace the VM. If SSH
reports a changed host key while `vm/create` uploads `tsh`, remove the old entry
and retry the upload:

```sh
ssh-keygen -R <vm-public-ip>
make tsh/upload
```

## Verify

Wait for cloud-init and verify the uploaded client:

```sh
make vm/status
make vm/cloud-init
make vm/ssh
tsh version
exit
```

Run the complete exchange test:

```sh
make vm/test
```

The remote `tsh` process prints a headless request ID and an approval command.
Run that command from a second workstation terminal using the same Teleport
user. For example:

```sh
tsh headless approve \
  --proxy=<teleport-proxy> \
  --user=<teleport-user> \
  <request-id>
```

After approval, the test:

- issues a fresh JWT SVID;
- validates its issuer, subject, and audience;
- runs `az login --service-principal --federated-token ...`;
- prints the Azure CLI account identity;
- uploads, downloads, compares, and deletes a test blob.

Successful Azure CLI output identifies the account as a `servicePrincipal`
whose name is the Terraform `application_client_id` output.

Federated identity credentials and Azure role assignments can take several
minutes to propagate. Retry `make vm/test` if the initial exchange or Blob
operation is rejected immediately after provisioning.

Useful outputs:

```sh
make tf/output
terraform -chdir=terraform output application_client_id
terraform -chdir=terraform output workload_identity_issuer
terraform -chdir=terraform output workload_identity_subject
```

After rebuilding `tsh`, upload it without changing the VM:

```sh
make tsh/upload
```

Use `TSH_BINARY_PATH=/other/path/tsh make tsh/upload` to override the path for
one invocation.

## Tear down

```sh
make tf/destroy
tctl rm workload_identity/azure-app-registration
tctl rm role/azure-app-registration-issuer
```

Before removing the role, remove it from the local user or SSO connector role
mapping.
