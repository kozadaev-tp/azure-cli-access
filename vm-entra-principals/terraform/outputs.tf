output "resource_group_name" {
  description = "Resource group containing the tsh VM and test resources."
  value       = azurerm_resource_group.this.name
}

output "vm_name" {
  description = "Name of the Linux VM used for the tsh test."
  value       = azurerm_linux_virtual_machine.this.name
}

output "vm_public_ip" {
  description = "Public IP of the tsh VM."
  value       = azurerm_public_ip.this.ip_address
}

output "ssh_command" {
  description = "SSH command for connecting to the tsh VM from the project directory."
  value       = "ssh -i id_rsa_azure ${var.admin_username}@${azurerm_public_ip.this.ip_address}"
}

output "vm_admin_username" {
  description = "Administrative username for the tsh VM."
  value       = var.admin_username
}

output "application_client_id" {
  description = "Client ID used to exchange the Teleport JWT SVID for an Azure access token."
  value       = azuread_application.workload.client_id
}

output "application_object_id" {
  description = "Object ID of the Entra App Registration."
  value       = azuread_application.workload.object_id
}

output "service_principal_object_id" {
  description = "Object ID of the App Registration's service principal."
  value       = azuread_service_principal.workload.object_id
}

output "tenant_id" {
  description = "Entra tenant containing the App Registration."
  value       = data.azurerm_client_config.current.tenant_id
}

output "workload_identity_issuer" {
  description = "Issuer configured on the Entra federated identity credential."
  value       = local.workload_identity_issuer
}

output "workload_identity_subject" {
  description = "SPIFFE subject configured on the Entra federated identity credential."
  value       = local.workload_identity_subject
}

output "storage_account_name" {
  description = "Storage account used to verify App Registration access."
  value       = azurerm_storage_account.test.name
}

output "storage_container_name" {
  description = "Blob container used to verify App Registration access."
  value       = azurerm_storage_container.test.name
}

output "test_command" {
  description = "Interactive command that runs the workload identity exchange test on the VM."
  value       = "ssh -tt -i id_rsa_azure ${var.admin_username}@${azurerm_public_ip.this.ip_address} /usr/local/bin/test-workload-identity"
}
