# token.yaml
kind: token
version: v2
metadata:
  name: azure-token
spec:
  roles: [App, Node]
  join_method: azure
  azure:
    allow:
      - subscription: ${SUBSCRIPTION_ID}
