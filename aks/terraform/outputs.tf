output "resource_group_name" {
  description = "Resource group containing the AKS workload identity repro resources."
  value       = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster running the Teleport Application Service."
  value       = azurerm_kubernetes_cluster.this.name
}

output "aks_get_credentials_command" {
  description = "Command to configure kubectl for the AKS cluster."
  value       = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}

output "kubectl_pods_command" {
  description = "Command to inspect the Teleport app_service pod."
  value       = "kubectl -n teleport get pods"
}

output "kubectl_logs_command" {
  description = "Command to inspect Teleport app_service logs."
  value       = "kubectl -n teleport logs deploy/teleport-app-service"
}

# The full URI of the managed identity. This is the value to pass to
#   tctl users update <user> --set-azure-identities <uri>
# and to reference in the `azure_identities` field of a Teleport role.
output "managed_identity_id" {
  description = "Resource ID (URI) of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.teleport.id
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.teleport.client_id
}

output "managed_identity_principal_id" {
  description = "Principal (object) ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.teleport.principal_id
}

output "storage_account_name" {
  description = "Test storage account for verifying tsh az storage commands."
  value       = azurerm_storage_account.test.name
}

output "storage_container_name" {
  description = "Test blob container inside the test storage account."
  value       = azurerm_storage_container.test.name
}

output "teleport_binary_blob_url" {
  description = "Blob URL for the uploaded instrumented Teleport binary."
  value       = azurerm_storage_blob.teleport_binary.url
}

output "key_vault_name" {
  description = "Test Key Vault for verifying tsh az keyvault commands."
  value       = azurerm_key_vault.test.name
}

output "key_vault_secret_names" {
  description = "Dummy Key Vault secrets for verifying tsh az keyvault secret commands."
  value       = sort(keys(azurerm_key_vault_secret.dummy))
}

output "tsh_apps_login_command" {
  description = "Command to log into the AKS-hosted Azure CLI app through Teleport."
  value       = "tsh apps login ${var.teleport_app_name} --azure-identity ${azurerm_user_assigned_identity.teleport.id}"
}

output "az_keyvault_secret_show_commands" {
  description = "Azure CLI commands for showing the dummy secrets from the test Key Vault."
  value = {
    for name in sort(keys(azurerm_key_vault_secret.dummy)) :
    name => "tsh az keyvault secret show --vault-name ${azurerm_key_vault.test.name} --name ${name}"
  }
}
