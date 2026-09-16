data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name_suffix               = random_string.suffix.result
  rg_name                   = "${var.prefix}-rg-${local.name_suffix}"
  workload_identity_name    = "azure-app-registration"
  workload_identity_path    = "/svc/azure-app-registration"
  workload_identity_issuer  = "https://${trimsuffix(var.teleport_proxy_address, ":443")}/workload-identity"
  workload_identity_subject = "spiffe://${var.teleport_cluster_name}${local.workload_identity_path}"
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
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
      - path: /usr/local/bin/test-workload-identity
        permissions: '0755'
        content: |
          #!/usr/bin/env bash
          set -euo pipefail

          jwt_dir=$(mktemp -d)
          export AZURE_CONFIG_DIR
          AZURE_CONFIG_DIR=$(mktemp -d)
          source_file=$(mktemp)
          downloaded_file=$(mktemp)
          trap 'rm -rf "$jwt_dir" "$AZURE_CONFIG_DIR"; rm -f "$source_file" "$downloaded_file"' EXIT

          tsh \
            --proxy="${var.teleport_proxy_address}" \
            --user="${var.teleport_user}" \
            --headless \
            workload-identity issue-jwt \
            --name-selector="${local.workload_identity_name}" \
            --audience=api://AzureADTokenExchange \
            --credential-ttl=5m \
            --output="$jwt_dir"

          jwt_path="$jwt_dir/jwt_svid"
          test -s "$jwt_path"

          token=$(cat "$jwt_path")
          az login \
            --service-principal \
            --username "${azuread_application.workload.client_id}" \
            --tenant "${data.azurerm_client_config.current.tenant_id}" \
            --federated-token "$token" \
            --allow-no-subscriptions \
            --output none

          az account show --query '{name:name,user:user}' --output json

          blob_name="tsh-poc-$(date +%s).txt"
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

  custom_data = base64encode(local.cloud_init)
}
