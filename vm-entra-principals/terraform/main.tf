data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

moved {
  from = azurerm_role_assignment.reader
  to   = azurerm_role_assignment.tbot_vm_reader
}

moved {
  from = azurerm_storage_container.teleport_binary
  to   = azurerm_storage_container.tbot_binary
}

moved {
  from = azurerm_storage_blob.teleport_binary
  to   = azurerm_storage_blob.tbot_binary
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name_suffix               = random_string.suffix.result
  rg_name                   = "${var.prefix}-rg-${local.name_suffix}"
  bot_name                  = "azure-app-registration"
  bot_role_name             = "azure-app-registration-issuer"
  bot_token_name            = "azure-app-registration-bot"
  workload_identity_name    = "azure-app-registration"
  workload_identity_path    = "/svc/azure-app-registration"
  workload_identity_issuer  = "https://${trimsuffix(var.teleport_proxy_address, ":443")}/workload-identity"
  workload_identity_subject = "spiffe://${var.teleport_cluster_name}${local.workload_identity_path}"
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
}

# This UAMI authenticates the VM to Teleport's Azure delegated join method and
# downloads tbot. It is not the identity used by the test workload.
resource "azurerm_user_assigned_identity" "teleport" {
  name                = var.prefix
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Azure delegated joining requires permission to inspect the VM.
resource "azurerm_role_assignment" "tbot_vm_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

resource "azuread_application" "workload" {
  display_name     = "${var.prefix}-workload"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "workload" {
  client_id = azuread_application.workload.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "teleport" {
  application_id = azuread_application.workload.id
  display_name   = "teleport-workload-identity"
  description    = "Trusts the Teleport JWT SVID issued for the PoC workload."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.workload_identity_issuer
  subject        = local.workload_identity_subject
}

resource "azurerm_storage_account" "test" {
  name                            = "tpaz${local.name_suffix}${substr(replace(var.prefix, "-", ""), 0, 10)}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
}

resource "azurerm_storage_container" "test" {
  name                  = "teleport-test"
  storage_account_name  = azurerm_storage_account.test.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "tbot_binary" {
  name                  = "teleport-binary"
  storage_account_name  = azurerm_storage_account.test.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "tbot_binary" {
  name                   = var.tbot_binary_blob_name
  storage_account_name   = azurerm_storage_account.test.name
  storage_container_name = azurerm_storage_container.tbot_binary.name
  type                   = "Block"
  source                 = pathexpand(var.tbot_binary_path)
}

# Bootstrap can read the binary, but it cannot access the workload test data.
resource "azurerm_role_assignment" "tbot_binary_reader" {
  scope                            = azurerm_storage_account.test.id
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_user_assigned_identity.teleport.principal_id
  skip_service_principal_aad_check = true
}

# Only the App Registration service principal can modify the test container.
resource "azurerm_role_assignment" "workload_blob_contributor" {
  scope                            = azurerm_storage_account.test.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azuread_service_principal.workload.object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "this" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_public_ip" "this" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "this" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

locals {
  cloud_init = <<-CLOUDINIT
    #cloud-config
    write_files:
      - path: /etc/tbot.yaml
        permissions: '0600'
        content: |
          version: v2
          proxy_server: ${var.teleport_proxy_address}
          onboarding:
            join_method: azure
            token: ${local.bot_token_name}
            azure:
              client_id: ${azurerm_user_assigned_identity.teleport.client_id}
          storage:
            type: memory
          services:
            - type: workload-identity-jwt
              destination:
                type: directory
                path: /opt/workload-identity
              selector:
                name: ${local.workload_identity_name}
              audiences:
                - api://AzureADTokenExchange
      - path: /etc/systemd/system/tbot.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Teleport Machine and Workload Identity
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          Restart=on-failure
          RestartSec=5
          ExecStart=/usr/local/bin/tbot start -c /etc/tbot.yaml
          ExecReload=/bin/kill -HUP $MAINPID
          LimitNOFILE=8192

          [Install]
          WantedBy=multi-user.target
      - path: /usr/local/bin/test-workload-identity
        permissions: '0755'
        content: |
          #!/usr/bin/env bash
          set -euo pipefail

          jwt_path=/opt/workload-identity/jwt_svid
          for attempt in $(seq 1 60); do
            test -s "$jwt_path" && break
            echo "waiting for JWT SVID ($attempt/60)"
            sleep 2
          done
          test -s "$jwt_path"

          python3 - "$jwt_path" "${local.workload_identity_issuer}" "${local.workload_identity_subject}" <<'PY'
          import base64
          import json
          import sys

          token = open(sys.argv[1], encoding="utf-8").read().strip()
          payload = token.split(".")[1]
          payload += "=" * (-len(payload) % 4)
          claims = json.loads(base64.urlsafe_b64decode(payload))
          assert claims["iss"] == sys.argv[2], claims
          assert claims["sub"] == sys.argv[3], claims
          audience = claims["aud"]
          assert audience == "api://AzureADTokenExchange" or "api://AzureADTokenExchange" in audience, claims
          print(json.dumps({key: claims[key] for key in ("iss", "sub", "aud", "exp")}, indent=2))
          PY

          export AZURE_CONFIG_DIR=/tmp/azure-app-registration-poc
          rm -rf "$AZURE_CONFIG_DIR"
          token=$(cat "$jwt_path")
          az login \
            --service-principal \
            --username "${azuread_application.workload.client_id}" \
            --tenant "${data.azurerm_client_config.current.tenant_id}" \
            --federated-token "$token" \
            --allow-no-subscriptions \
            --output none

          az account show --query '{name:name,user:user}' --output json

          blob_name="tbot-poc-$(date +%s).txt"
          source_file=$(mktemp)
          downloaded_file=$(mktemp)
          trap 'rm -f "$source_file" "$downloaded_file"' EXIT
          printf 'authenticated as App Registration %s\n' "${azuread_application.workload.client_id}" > "$source_file"

          az storage blob upload \
            --account-name "${azurerm_storage_account.test.name}" \
            --container-name "${azurerm_storage_container.test.name}" \
            --name "$blob_name" \
            --file "$source_file" \
            --auth-mode login \
            --overwrite \
            --output none
          az storage blob download \
            --account-name "${azurerm_storage_account.test.name}" \
            --container-name "${azurerm_storage_container.test.name}" \
            --name "$blob_name" \
            --file "$downloaded_file" \
            --auth-mode login \
            --overwrite \
            --output none
          cmp "$source_file" "$downloaded_file"
          az storage blob delete \
            --account-name "${azurerm_storage_account.test.name}" \
            --container-name "${azurerm_storage_container.test.name}" \
            --name "$blob_name" \
            --auth-mode login \
            --output none

          echo "App Registration workload identity exchange succeeded."
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      - az login --identity --client-id "${azurerm_user_assigned_identity.teleport.client_id}" --allow-no-subscriptions
      - |
        set -eu
        i=1
        while [ "$i" -le 30 ]; do
          az storage blob download \
            --account-name "${azurerm_storage_account.test.name}" \
            --container-name "${azurerm_storage_container.tbot_binary.name}" \
            --name "${azurerm_storage_blob.tbot_binary.name}" \
            --file /usr/local/bin/tbot \
            --auth-mode login \
            --overwrite && \
          chmod 0755 /usr/local/bin/tbot && \
          break

          echo "waiting for tbot binary blob ($i/30)"
          sleep 10
          i=$((i + 1))
        done

        test -x /usr/local/bin/tbot
      - systemctl daemon-reload
      - systemctl enable tbot
      - systemctl restart tbot
  CLOUDINIT
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "${var.prefix}-vm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.admin_ssh_public_key_path))
  }

  network_interface_ids = [azurerm_network_interface.this.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.teleport.id]
  }

  custom_data = base64encode(local.cloud_init)

  depends_on = [
    azurerm_role_assignment.tbot_vm_reader,
    azurerm_role_assignment.tbot_binary_reader,
    azurerm_storage_blob.tbot_binary,
  ]
}
