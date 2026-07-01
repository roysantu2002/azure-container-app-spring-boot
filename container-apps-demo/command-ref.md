az containerapp env delete \
  --name managedEnvironment-rgordersdev-a29a \
  --resource-group rg-orders-dev \
  --yes
Containerapp environment successfully deleted
❯ az containerapp show \
  --name app-1 \
  --resource-group rg-container-apps-demo \
  --query "properties.provisioningState"
"Failed"
❯ az containerapp delete \
  --name app-1 \
  --resource-group rg-container-apps-demo \
  --yes


  ###

  az containerapp show \
  --name app-2 \
  --resource-group rg-container-apps-demo \
  --query "{state:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn}"

  ### python request

  python3 -c "import urllib.request; print(urllib.request.urlopen('http://app-1').read().decode())"