#!/bin/bash
SUFFIX=$RANDOM

export RESOURCE_GROUP="honeycomb-collector$SUFFIX"
export REGISTRY_NAME="collectorreg$SUFFIX"
export LOCATION=uksouth
export STORAGE_ACCOUNT_NAME="collectorappstorage$SUFFIX"
export STORAGE_SHARE_NAME="collector-config"
export STORAGE_MOUNT_NAME="configmount"
export CONTAINER_APP_NAME="collector"
export COLLECTOR_IMAGE=otel/opentelemetry-collector
export HONEYCOMB_API_KEY=$1
export VNET_NAME=$2
export SUBNET_NAME=$3

echo "Creating a Otel Collector in an Azure Container App"
echo "Honeycomb API Key is ${HONEYCOMB_API_KEY:0:5}****"

# Create Resource Group
echo "Creating Resource Group called $RESOURCE_GROUP in $LOCATION"
az group create --name $RESOURCE_GROUP --location $LOCATION --output none

echo "Creating ACR"
az acr create \
  --name $REGISTRY_NAME \
  --resource-group $RESOURCE_GROUP \
  --sku Basic \
  --admin-enabled true \
  --output none > /dev/null

echo "Pushing Image"
docker build -t collector:local-$SUFFIX collector-config --no-cache
docker tag collector:local-$SUFFIX $REGISTRY_NAME.azurecr.io/collector:$SUFFIX

PASSWORD=`az acr credential show --name $REGISTRY_NAME --resource-group $RESOURCE_GROUP -o tsv --query "passwords[0].value" `

docker login $REGISTRY_NAME.azurecr.io --username $REGISTRY_NAME --password $PASSWORD
docker push $REGISTRY_NAME.azurecr.io/collector:$SUFFIX


# Create Storage Account
echo "Creating a Storage account called $STORAGE_ACCOUNT_NAME"
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT_NAME \
  --location "$LOCATION" \
  --kind StorageV2 \
  --sku Standard_LRS \
  --enable-large-file-share \
  --output none

# Create Azure File Share
echo "Creating a File Share called $STORAGE_SHARE_NAME"
az storage share-rm create \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $STORAGE_SHARE_NAME \
  --quota 1024 \
  --enabled-protocols SMB \
  --output none

STORAGE_ACCOUNT_KEY=`az storage account keys list -n $STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv`

echo "Uploading the config file to the file share"
az storage file upload -s $STORAGE_SHARE_NAME \
  --source config.yaml \
  --account-key $STORAGE_ACCOUNT_KEY \
  --account-name $STORAGE_ACCOUNT_NAME > /dev/null

echo "Creating AppService Plan"
az appservice plan create \
  --name $REGISTRY_NAME \
  --resource-group $RESOURCE_GROUP \
  --is-linux \
  --output none > /dev/null

echo "Creating AppService"
az webapp create --resource-group $RESOURCE_GROUP \
  --plan $REGISTRY_NAME \
  --name $REGISTRY_NAME \
  --deployment-container-image-name $REGISTRY_NAME.azurecr.io/collector:$SUFFIX \
  --output none > /dev/null

sleep 20 

echo "Adding Settings"
az webapp config appsettings set \
  --resource-group $RESOURCE_GROUP \
  --name $REGISTRY_NAME \
  --settings WEBSITES_PORT=4318 \
  --output none > /dev/null

sleep 20

echo "Adding Storage Config"
az webapp config storage-account add \
  --resource-group $RESOURCE_GROUP \
  --name $REGISTRY_NAME \
  --custom-id $SUFFIX \
  --storage-type AzureFiles \
  --share-name $STORAGE_SHARE_NAME \
  --account-name $STORAGE_ACCOUNT_NAME \
  --access-key $STORAGE_ACCOUNT_KEY \
  --mount-path /etc/otelcol \
  --output none > /dev/null

sleep 20

echo "Setting up ACR permissions"
PRINCIPAL_ID=`az webapp identity assign --resource-group $RESOURCE_GROUP --name $REGISTRY_NAME --query principalId --output tsv`
SUBSCRIPTION_ID=`az account show --query id --output tsv`

# this is to allow for the principal to propogate
# if you see this error, maybe extend it.
# Cannot find user or service principal in graph database for '<guid>'
sleep 20

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$REGISTRY_NAME --role "AcrPull"

az resource update \
  --ids /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$REGISTRY_NAME/config/web \
  --set properties.acrUseManagedIdentityCreds=True \
  --output none

sleep 20

echo "Deploy the image"
az webapp config container set \
  --name $REGISTRY_NAME \
  --resource-group $RESOURCE_GROUP \
  --docker-custom-image-name $REGISTRY_NAME.azurecr.io/collector:$SUFFIX \
  --docker-registry-server-url https://$REGISTRY_NAME.azurecr.io \
  --enable-app-service-storage true \
  --output none > /dev/null

echo ""
echo "HAPPY TRACING!!!!"
echo "Tail the logs from the collector with:"
echo "az webapp log tail --name $REGISTRY_NAME --resource-group $RESOURCE_GROUP"
echo "Done"