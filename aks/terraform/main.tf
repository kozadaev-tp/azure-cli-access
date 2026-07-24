data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name_suffix             = random_string.suffix.result
  rg_name                 = "${var.prefix}-rg-${local.name_suffix}"
  teleport_namespace      = "teleport"
  teleport_serviceaccount = "teleport-app-service"

  teleport_config = <<-YAML
    version: v3
    teleport:
      log:
        output: stderr
        severity: DEBUG
      proxy_server: "${var.teleport_proxy_address}"
      join_params:
        method: token
        token_name: "${local.teleport_join_token}"
    auth_service:
      enabled: false
    proxy_service:
      enabled: false
    ssh_service:
      enabled: false
    app_service:
      enabled: true
      apps:
        - name: ${var.teleport_app_name}
          cloud: Azure
  YAML
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
}

# User-assigned identity used by the AKS Teleport Application Service via Azure
# Workload Identity. This is the identity selected with `tsh apps login`.
resource "azurerm_user_assigned_identity" "teleport" {
  name                = var.prefix
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Reader role on the resource group so the identity can list/inspect resources.
resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

# Storage Blob Data Contributor lets the identity read/write blob data via AAD.
resource "azurerm_role_assignment" "blob_data_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

# Storage Account Contributor lets the identity manage accounts and fetch keys.
resource "azurerm_role_assignment" "storage_account_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

# Storage Blob Data Reader lets the identity read blob data via AAD.
resource "azurerm_role_assignment" "storage_account_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

# Key Vault Reader lets the identity inspect Key Vault metadata and list vaults.
resource "azurerm_role_assignment" "key_vault_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

# Key Vault Secrets User lets the identity read secrets in Key Vaults.
resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.teleport.principal_id
}

resource "azurerm_key_vault" "test" {
  name                       = "kv-${substr(lower(replace(var.prefix, "-", "")), 0, 15)}-${local.name_suffix}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "current_key_vault_administrator" {
  scope                = azurerm_key_vault.test.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "dummy" {
  for_each = {
    dummy-api-token = "dummy-api-token-value"
    dummy-password  = "dummy-password-value"
  }

  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.test.id
  content_type = "text/plain"

  depends_on = [azurerm_role_assignment.current_key_vault_administrator]
}

# Test storage account + container used to verify Teleport Azure CLI behavior.
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

resource "azurerm_storage_container" "teleport_binary" {
  name                  = "teleport-binary"
  storage_account_name  = azurerm_storage_account.test.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "teleport_binary" {
  name                   = var.teleport_binary_blob_name
  storage_account_name   = azurerm_storage_account.test.name
  storage_container_name = azurerm_storage_container.teleport_binary.name
  type                   = "Block"
  source                 = pathexpand(var.teleport_binary_path)
}

resource "azurerm_kubernetes_cluster" "this" {
  name                      = "${var.prefix}-aks-${local.name_suffix}"
  location                  = azurerm_resource_group.this.location
  resource_group_name       = azurerm_resource_group.this.name
  dns_prefix                = "${var.prefix}-${local.name_suffix}"
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name       = "system"
    node_count = var.aks_node_count
    vm_size    = var.aks_vm_size
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_federated_identity_credential" "teleport" {
  name                = "${var.prefix}-aks-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.teleport.id
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:${local.teleport_namespace}:${local.teleport_serviceaccount}"
  audience            = ["api://AzureADTokenExchange"]
}

resource "kubernetes_namespace_v1" "teleport" {
  metadata {
    name = local.teleport_namespace
  }
}

resource "kubernetes_service_account_v1" "teleport" {
  metadata {
    name      = local.teleport_serviceaccount
    namespace = kubernetes_namespace_v1.teleport.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.teleport.client_id
      "azure.workload.identity/tenant-id" = data.azurerm_client_config.current.tenant_id
    }
  }
}

resource "kubernetes_secret_v1" "teleport_config" {
  metadata {
    name      = "teleport-config"
    namespace = kubernetes_namespace_v1.teleport.metadata[0].name
  }

  data = {
    "teleport.yaml" = local.teleport_config
  }
}

resource "kubernetes_deployment_v1" "teleport" {
  wait_for_rollout = false

  metadata {
    name      = "teleport-app-service"
    namespace = kubernetes_namespace_v1.teleport.metadata[0].name
    labels = {
      app = "teleport-app-service"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "teleport-app-service"
      }
    }

    template {
      metadata {
        annotations = {
          "teleport.dev/config-hash" = sha256(local.teleport_config)
        }

        labels = {
          app                           = "teleport-app-service"
          "azure.workload.identity/use" = "true"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.teleport.metadata[0].name

        init_container {
          name    = "check-teleport-proxy"
          image   = var.azure_cli_image
          command = ["/bin/sh", "-c"]
          args = [<<-SH
            set -eu
            i=1
            while [ "$i" -le 30 ]; do
              if curl -fsS --connect-timeout 10 "https://${var.teleport_proxy_address}/webapi/ping" >/dev/null; then
                exit 0
              fi
              echo "waiting for Teleport proxy at ${var.teleport_proxy_address} ($i/30)"
              sleep 10
              i=$((i + 1))
            done
            echo "Teleport proxy is not reachable from AKS: ${var.teleport_proxy_address}" >&2
            exit 1
          SH
          ]
        }

        init_container {
          name    = "download-teleport"
          image   = var.azure_cli_image
          command = ["/bin/sh", "-c"]
          args = [<<-SH
            set -eu
            az login \
              --service-principal \
              --username "$AZURE_CLIENT_ID" \
              --tenant "$AZURE_TENANT_ID" \
              --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" \
              --allow-no-subscriptions
            az storage blob download \
              --account-name "${azurerm_storage_account.test.name}" \
              --container-name "${azurerm_storage_container.teleport_binary.name}" \
              --name "${azurerm_storage_blob.teleport_binary.name}" \
              --file /opt/teleport/teleport \
              --auth-mode login \
              --overwrite
            chmod 0755 /opt/teleport/teleport
          SH
          ]

          env {
            name  = "AZURE_CLIENT_ID"
            value = azurerm_user_assigned_identity.teleport.client_id
          }

          env {
            name  = "AZURE_TENANT_ID"
            value = data.azurerm_client_config.current.tenant_id
          }

          volume_mount {
            name       = "teleport-bin"
            mount_path = "/opt/teleport"
          }
        }

        container {
          name    = "teleport"
          image   = var.teleport_image
          command = ["/opt/teleport/teleport"]
          args    = ["start", "-c", "/etc/teleport/teleport.yaml"]

          env {
            name  = "AZURE_CLIENT_ID"
            value = azurerm_user_assigned_identity.teleport.client_id
          }

          env {
            name  = "AZURE_TENANT_ID"
            value = data.azurerm_client_config.current.tenant_id
          }

          volume_mount {
            name       = "teleport-bin"
            mount_path = "/opt/teleport"
            read_only  = true
          }

          volume_mount {
            name       = "teleport-config"
            mount_path = "/etc/teleport"
            read_only  = true
          }
        }

        volume {
          name = "teleport-bin"
          empty_dir {}
        }

        volume {
          name = "teleport-config"
          secret {
            secret_name = kubernetes_secret_v1.teleport_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    azurerm_federated_identity_credential.teleport,
    azurerm_role_assignment.blob_data_contributor,
    azurerm_storage_blob.teleport_binary,
  ]
}
