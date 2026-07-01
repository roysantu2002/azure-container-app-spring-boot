  az postgres flexible-server firewall-rule create --resource-group rg-orders-dev --server-name pg-orders-dev --name "ClientIP-2026-06-26"                
   --start-ip-address 122.168.92.211 --end-ip-address 122.168.92.211 -o table 2>&1   


    az login --tenant "f5666466-d48d-4b60-a921-7ebad0f1d5fc" --scope "api://54e02b56-2529-4495-b046-f86a9e31ed3f/.default"                                                                   
                                                                                                                                                                                           
  Then:                                                                                                                                                                                    
                                                                                                                                                                                           
  TOKEN=$(az account get-access-token --scope api://54e02b56-2529-4495-b046-f86a9e31ed3f/.default --query accessToken -o tsv)                                                              
                                                                                                                                                                                           
  curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/v1/orders      