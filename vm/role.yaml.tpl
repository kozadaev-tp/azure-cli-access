kind: role
version: v7
metadata:
  name: azure-cli-access
spec:
  allow:
    app_labels:
      '*': '*'
    azure_identities:
      - ${MANAGED_IDENTITY_ID}
