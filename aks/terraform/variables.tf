variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "prefix" {
  description = "Prefix used to name all resources."
  type        = string
  default     = "teleport-azure"
}

variable "aks_node_count" {
  description = "Number of nodes in the AKS system node pool."
  type        = number
  default     = 1
}

variable "aks_vm_size" {
  description = "Azure VM SKU for AKS nodes."
  type        = string
  default     = "Standard_B2s"
}

variable "teleport_proxy_address" {
  description = "Teleport proxy address, e.g. teleport.example.com:443."
  type        = string
}

variable "teleport_app_name" {
  description = "Name of the Azure CLI application registered in Teleport."
  type        = string
  default     = "azure-cli"
}

variable "teleport_join_token_file" {
  description = "Path to a file containing the static Teleport app join token used by the AKS app_service pod. Relative paths are resolved from the terraform directory."
  type        = string
  default     = ".join-token"
}

locals {
  teleport_join_token_path = startswith(pathexpand(var.teleport_join_token_file), "/") ? pathexpand(var.teleport_join_token_file) : "${path.module}/${var.teleport_join_token_file}"
  teleport_join_token      = trimspace(file(local.teleport_join_token_path))
}

variable "teleport_binary_path" {
  description = "Local path to the Linux Teleport binary uploaded to Blob Storage and run in AKS."
  type        = string
}

variable "teleport_binary_blob_name" {
  description = "Blob name used for the uploaded Teleport binary."
  type        = string
  default     = "teleport"
}

variable "teleport_image" {
  description = "Base image for the Teleport container. The downloaded binary is executed instead of the image binary."
  type        = string
  default     = "public.ecr.aws/gravitational/teleport-distroless:17"
}

variable "azure_cli_image" {
  description = "Image used by the init container that downloads the Teleport binary from Blob Storage."
  type        = string
  default     = "mcr.microsoft.com/azure-cli:latest"
}
