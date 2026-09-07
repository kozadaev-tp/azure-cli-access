kind: role
version: v7
metadata:
  name: azure-cli-access
spec:
  allow:
    request:
      roles:
        - azure-cli-access
      search_as_roles:
        - azure-cli-access
    app_labels:
      '*': '*'
    azure_identities:
      - ${MANAGED_IDENTITY_ID}
