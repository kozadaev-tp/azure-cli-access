output "resource_group_name" {
  description = "Resource group containing the Teleport app VM and managed identity."
  value       = azurerm_resource_group.this.name
}

output "vm_name" {
  description = "Name of the Linux VM running the Teleport Application Service."
  value       = azurerm_linux_virtual_machine.this.name
}

output "vm_public_ip" {
  description = "Public IP of the VM (no inbound ports opened by default; access via tsh ssh)."
  value       = azurerm_public_ip.this.ip_address
}

output "tsh_ssh_command" {
  description = "Convenience tsh ssh command (use once the node has joined the Teleport cluster)."
  value       = "tsh ssh ${var.admin_username}@${azurerm_linux_virtual_machine.this.name}"
}

output "ssh_command" {
  description = "Convenience tsh ssh command (use once the node has joined the Teleport cluster)."
  value       = "ssh -i ../id_rsa_azure ${var.admin_username}@${azurerm_public_ip.this.ip_address}"
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
  description = "Blob URL for the uploaded Teleport binary."
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

output "az_keyvault_secret_show_commands" {
  description = "Azure CLI commands for showing the dummy secrets from the test Key Vault."
  value = {
    for name in sort(keys(azurerm_key_vault_secret.dummy)) :
    name => "az keyvault secret show --vault-name ${azurerm_key_vault.test.name} --name ${name}"
  }
}
