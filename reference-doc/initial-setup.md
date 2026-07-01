1. Terraform Remote Backend (critical)                                                                                                                                                           
                                                                                                                                                                                                 
  Right now there's no backend configured. GitHub Actions runners are ephemeral — the state file is lost after each run. A second apply would try to recreate everything and fail. You need a      
  Storage Account for state.                                                                                                                                                                       

  One-time manual setup (run from your terminal or Cloud Shell):

  az group create --name rg-terraform-state --location "Canada Central"

  az storage account create \
    --name stordersdevtfstate \
    --resource-group rg-terraform-state \
    --location "Canada Central" \
    --sku Standard_LRS

  az storage container create \
    --name tfstate \
    --account-name stordersdevtfstate

  Then I'll add the backend config to providers.tf.

  az provider show --namespace Microsoft.Storage --query "registrationState"
# Should return "Registered"