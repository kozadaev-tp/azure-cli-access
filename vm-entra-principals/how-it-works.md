**Documenting Entra OIDC endpoint and role details**

**Architecture**

The PoC now separates three responsibilities:

| Component | Responsibility |
|---|---|
| `tctl` on the workstation | Configures Teleport RBAC and the Workload Identity |
| `tsh` on the VM | Authenticates the human and requests a JWT SVID |
| Terraform/Azure | Creates the App Registration, federation trust, RBAC, VM, and Blob resources |

There is no `tbot`, Bot resource, Azure join token, VM managed identity, or continuously renewed JWT.

```text
Workstation admin
    |
    | tctl create
    v
Teleport role + Workload Identity

Workstation admin                  Azure VM
    |                                |
    | approve headless request       | tsh issue-jwt
    +------------------------------->|
                                     |
                                     v
                              Teleport Auth Service
                                     |
                                     | signed JWT SVID
                                     v
                              Microsoft Entra token exchange
                                     |
                                     | Azure access token
                                     v
                              Azure Blob Storage
```

## 1. Teleport Configuration

`teleport-resources.yaml` defines two resources.

The Workload Identity describes the identity Teleport will issue:

```yaml
kind: workload_identity
version: v1
metadata:
  name: azure-app-registration
  labels:
    purpose: azure-app-registration-poc
spec:
  spiffe:
    id: /svc/azure-app-registration
```

Given a Teleport cluster name of `snobb.co.uk`, its complete SPIFFE ID becomes:

```text
spiffe://snobb.co.uk/svc/azure-app-registration
```

The role permits issuance of Workload Identities carrying the matching label:

```yaml
kind: role
version: v7
metadata:
  name: azure-app-registration-issuer
spec:
  allow:
    workload_identity_labels:
      purpose:
        - azure-app-registration-poc
    rules:
      - resources:
          - workload_identity
        verbs:
          - list
          - read
```

The resources are applied with:

```sh
make cluster/apply
```

That ultimately runs:

```sh
tctl create -f teleport-resources.yaml
```

## 2. User Authorization

The requesting Teleport user must possess `azure-app-registration-issuer`.

The configured user is:

```hcl
teleport_user = "admin"
```

The `admin` user now has:

```text
access
editor
aws-teleport-access
gcp-teleport-access
azure-app-registration-issuer
```

This assignment is important because headless approval only proves that the remote request belongs to `admin`. It does not transfer roles from the approving certificate or grant temporary authorization.

When Teleport completes the headless login, it reads the current server-side `admin` resource and issues a new short-lived certificate containing its current roles.

## 3. Azure Infrastructure

Terraform creates the following Azure resources:

1. A Microsoft Entra App Registration.
2. The service principal associated with that App Registration.
3. A federated identity credential on the application.
4. An Azure Storage account and private Blob container.
5. A `Storage Blob Data Contributor` assignment for the service principal.
6. A Linux VM used to run `tsh` and the test.
7. Supporting network, subnet, public IP, and SSH resources.

The VM does not have a managed identity. It has no Azure permissions before the JWT exchange.

## 4. Federated Credential

The federated identity credential binds three JWT claims:

```text
issuer:   https://snobb.co.uk/workload-identity
subject:  spiffe://snobb.co.uk/svc/azure-app-registration
audience: api://AzureADTokenExchange
```

Terraform configures those values here:

```hcl
resource "azuread_application_federated_identity_credential" "teleport" {
  application_id = azuread_application.workload.id
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.workload_identity_issuer
  subject        = local.workload_identity_subject
}
```

Microsoft Entra will reject a JWT if any of the issuer, subject, or audience values differ.

## 5. OIDC Trust

Teleport publishes two public endpoints:

```text
https://snobb.co.uk/workload-identity/.well-known/openid-configuration
https://snobb.co.uk/workload-identity/jwt-jwks.json
```

The discovery document tells Entra:

- The expected issuer.
- The JWKS endpoint.
- The supported signing algorithm.

The JWKS endpoint publishes the public keys corresponding to Teleport’s Workload Identity signing key.

These endpoints do not issue JWTs. They only allow Entra to validate JWTs signed by Teleport. They must be publicly and reliably reachable through the Cloudflare tunnel.

## 6. VM Provisioning

Cloud-init performs only two tasks:

1. Installs Azure CLI.
2. Writes `/usr/local/bin/test-workload-identity`.

The local Linux AMD64 `tsh` binary is not placed in Terraform state or Blob Storage. The Makefile uploads it directly over SSH:

```sh
make tsh/upload
```

The target:

1. Validates that the binary is an x86-64 Linux ELF executable.
2. Waits for SSH connectivity.
3. Copies it to `/tmp/tsh`.
4. Installs it as `/usr/local/bin/tsh` with mode `0755`.

`make vm/create` performs:

```text
cluster/apply
terraform init
terraform apply
tsh/upload
```

## 7. Starting The Test

The test is started with:

```sh
make vm/test
```

Terraform generates an SSH command equivalent to:

```sh
ssh -tt \
  -i id_rsa_azure \
  azureuser@<vm-ip> \
  /usr/local/bin/test-workload-identity
```

The `-tt` option is necessary because headless authentication is an interactive ceremony and its output must remain attached to the terminal.

The script runs as `azureuser`, not as root.

## 8. Temporary Storage

At the beginning of the test, the script creates temporary locations for:

- The JWT SVID.
- Azure CLI’s token cache.
- The upload source file.
- The downloaded comparison file.

Conceptually:

```sh
jwt_dir=$(mktemp -d)
AZURE_CONFIG_DIR=$(mktemp -d)
source_file=$(mktemp)
downloaded_file=$(mktemp)
```

A shell trap deletes these files and directories when the test exits, including after most failures.

This prevents the Teleport JWT and Azure access token cache from remaining on the VM.

## 9. Headless Authentication

The VM runs:

```sh
tsh \
  --proxy="snobb.co.uk:443" \
  --user="admin" \
  --headless \
  workload-identity issue-jwt \
  --name-selector="azure-app-registration" \
  --audience=api://AzureADTokenExchange \
  --credential-ttl=5m \
  --output="$jwt_dir"
```

The remote `tsh` process:

1. Generates temporary SSH and TLS keypairs.
2. Creates a pending headless authentication request for `admin`.
3. Binds the request to those public keys.
4. Displays a request ID.
5. Waits for approval.

The private keys remain on the VM and are not sent to the workstation.

## 10. Headless Approval

From another workstation terminal, `admin` approves the request:

```sh
tsh headless approve \
  --proxy=snobb.co.uk:443 \
  --user=admin \
  <request-id>
```

Teleport checks:

- The approver is the same user as the requester.
- The request is still pending.
- The request has not expired.
- The public keys have not changed.
- The user completes the required MFA ceremony.

Approval changes the request state from pending to approved.

Teleport then retrieves the current server-side `admin` resource and issues a short-lived, MFA-verified user certificate for the temporary VM keys. Headless certificates are intentionally short-lived and are valid only for the immediate command.

This is where the earlier authorization failure occurred: `admin` successfully authenticated, but the newly issued certificate did not contain `azure-app-registration-issuer`.

## 11. JWT SVID Issuance

After headless authentication succeeds, the remote `tsh` uses its temporary Teleport TLS certificate to call the Workload Identity issuance API.

It requests:

```text
Workload Identity: azure-app-registration
Audience:          api://AzureADTokenExchange
TTL:               5 minutes
```

Teleport performs these authorization checks:

1. The authenticated user has permission to read the Workload Identity.
2. The role’s `workload_identity_labels` selector matches the resource.
3. The selected resource exists.
4. The requested TTL does not exceed the resource or cluster limit.

Teleport then signs the JWT with its Workload Identity JWT signing key.

The resulting claims are similar to:

```json
{
  "iss": "https://snobb.co.uk/workload-identity",
  "sub": "spiffe://snobb.co.uk/svc/azure-app-registration",
  "aud": "api://AzureADTokenExchange",
  "iat": 1788810000,
  "exp": 1788810300,
  "jti": "..."
}
```

`tsh` writes it to:

```text
<temporary-directory>/jwt_svid
```

with owner-only permissions.

## 12. Local Claim Validation

The test decodes the JWT payload and checks:

- `iss` equals the Terraform-configured issuer.
- `sub` equals the expected SPIFFE ID.
- `aud` contains `api://AzureADTokenExchange`.
- `exp` is present.

This Python step does not cryptographically validate the signature. It is a diagnostic assertion that the intended claims were issued.

Microsoft Entra performs the actual signature validation.

## 13. Entra Token Exchange

The test runs:

```sh
az login \
  --service-principal \
  --username "<application-client-id>" \
  --tenant "<tenant-id>" \
  --federated-token "<teleport-jwt>" \
  --allow-no-subscriptions
```

Here:

- `--username` is the App Registration’s Application (client) ID.
- `--tenant` is the Directory tenant ID.
- `--federated-token` is the Teleport JWT SVID.
- No client secret or application certificate is provided.

Azure CLI sends the JWT to Microsoft Entra’s token endpoint as a client assertion.

## 14. Entra Validation

Microsoft Entra locates the federated credential associated with the App Registration and validates:

1. The JWT signature against Teleport’s published JWKS.
2. The `iss` claim against the configured issuer.
3. The `sub` claim against the configured SPIFFE ID.
4. The `aud` claim against `api://AzureADTokenExchange`.
5. The token’s issuance and expiration times.

If validation succeeds, Entra issues an Azure access token representing the App Registration’s service principal.

The JWT SVID is only used for this exchange. Azure API requests use the resulting Azure access token.

## 15. Azure Authorization

Terraform grants the service principal:

```text
Storage Blob Data Contributor
```

scoped to the test storage account.

The test verifies this authorization by:

1. Creating a temporary text file.
2. Uploading it to the private container.
3. Downloading it.
4. Comparing the downloaded content with the original.
5. Deleting the blob.

The account output should identify:

```json
{
  "user": {
    "name": "<application-client-id>",
    "type": "servicePrincipal"
  }
}
```

That proves Azure is authorizing the App Registration service principal, not the VM, SSH user, Teleport user, or a managed identity.

## 16. Cleanup

When the script exits, its trap removes:

- The Teleport JWT SVID.
- The temporary headless credential directory.
- The Azure CLI token cache.
- The source and downloaded Blob test files.

The uploaded Blob is also deleted after successful comparison.

No background identity process remains running.

## Difference From The `tbot` Workflow

| `tbot` workflow | Current `tsh` workflow |
|---|---|
| Azure delegated join | Human headless authentication |
| Bot holds Teleport identity | Temporary human certificate |
| JWT continuously renewed | JWT issued once per test |
| No human interaction after deployment | Human approval required every time |
| Suitable for unattended workloads | Suitable for testing and debugging |
| Bot and join-token resources | User, role, and Workload Identity resources |
| VM UAMI required for joining | VM has no managed identity |
| JWT file persists and rotates | JWT exists only in a temporary directory |

The key security property remains unchanged: only Teleport signs the JWT SVID, and Microsoft Entra only accepts it when its signature and exact issuer, subject, and audience match the federated credential.
