param 
( 
[Parameter(Mandatory=$true, HelpMessage="The resource group where the Gateway is contained.")] [String]$gwResourceGroup,
[Parameter(Mandatory=$true, HelpMessage="The gateway type is either 'shared' or 'prod'.")][ValidateSet('shared','prod')][String]$gwType,
[Parameter(Mandatory=$true, HelpMessage="The resource group name where the vnet, apim and web applications for example are kept.")] [String]$envResourceGroup
) 

##################################################################################################################
###  This script deploys all the relevant gateway settings for an existing environment deployed into azure, 
###  for example the ci environment.
###
###  Its designed to be called from a devops pipeline using the azure cli task with multi configuration in mind.
###
###  Along with setting up the application gateway for an environment it will also create the vnet peering.
###
###  The script uses the new Azure CLI command which makes automating deployments easier.
##################################################################################################################

# credentials info for logging into azure, in a pipe line these are retrieved automatically and use the principle id in devops.
$USER = $env:servicePrincipalId 
$PASSWORD = $env:servicePrincipalKey 
$TENANT = $env:tenantId 

# login to the azure subscription using service principle.
$output = az login --service-principal --username $USER  --password $PASSWORD  --tenant $TENANT

##################################################################################################################
### SET VARIABLES ###
##################################################################################################################

# Get the specific VMname by getting the vm by its name which contains a string
$VMNAME = az vm list -g $envResourceGroup --query "[?contains(name, 'vmnamestring')].[name]" -o tsv

# The resource group where the Application Gateway we are creating will be contained.
$GATEWAYRESOURCEGROUP = $gwResourceGroup

# The gateway type is either 'shared' or 'prod'.
$GATEWAYTYPE = $gwType

# The resource group name where the vnet and apim are contained.
$AZENVRESOURCEGROUP = $envResourceGroup

Write-Host('Starting script for environment ' + $RULESUFFIX) -ForegroundColor White

##################################################################################################################
### AZURE RESOURCE NAMES ###
##################################################################################################################

$GATEWAYVNETNAME = 'midwolf-' + $GATEWAYTYPE + '-gateways-uksouth-vnet'

$APPGATEWAYNAME = 'midwolf-' + $GATEWAYTYPE + '-gateway-uksouth'



##################################################################################################################
### BACKEND POOLS ###
##################################################################################################################
Write-Host('Creating backend pool...') -ForegroundColor White

    if ($VMNAME) 
    { 
        Write-Host "Found VM for this environment... backend pool is being added..." -ForegroundColor White
        
        # given an vm name i can get the internal IP address for it.
        $privateIp = az vm list-ip-addresses -g $AZENVRESOURCEGROUP -n $VMNAME --query "[].virtualMachine.network.privateIpAddresses[0]" -o tsv

        # add backend for vm
        $output = az network application-gateway address-pool create -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME `
            -n midwolf-$RULESUFFIX-vm-pool --servers $privateIp
        
        Write-Host "vm backend pool is complete..." -ForegroundColor Green
    }

Write-Host('Finished creating backend pool.') -ForegroundColor Green


##################################################################################################################
### HTTP SETTINGS
##################################################################################################################
Write-Host('Creating http setting...') -ForegroundColor White

    if ($VMNAME) 
    { 
        Write-Host "vm httpsetting are being added..." -ForegroundColor White
        ## vm settings
        $output = az network application-gateway http-settings create -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME `
            -n midwolf-$RULESUFFIX-vm-settings --port 80 --protocol Http --cookie-based-affinity Enabled --timeout 30 `
            --affinity-cookie-name midwolf --host-name-from-backend-pool false
        
        Write-Host "vm httpsetting are complete." -ForegroundColor Green
    }

Write-Host('Finished creating http setting.') -ForegroundColor Green



##################################################################################################################
### LISTENERS
##################################################################################################################

Write-Host('Creating listener...') -ForegroundColor White

    if ($VMNAME) 
    {
        Write-Host "VM listener is being added..." -ForegroundColor White

        # VM listener
        $output = az network application-gateway http-listener create -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME `
            --host-name 'vm.midwolf.co.uk' --frontend-port port_80 `
            -n midwolf-$RULESUFFIX-vm-listener --frontend-ip appGwPublicFrontendIp
        
        Write-Host "VM listener is complete." -ForegroundColor Green
    }


Write-Host('Finished creating listener.') -ForegroundColor Green


##################################################################################################################
### RULES
##################################################################################################################

Write-Host('Creating rule...') -ForegroundColor White

    if ($VMNAME) 
    {
        Write-Host "VM rule is being added..." -ForegroundColor Blue

        # add rule for vm
        $output = az network application-gateway rule create -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME `
            -n midwolf-$RULESUFFIX-vm-routing-rule --http-listener midwolf-$RULESUFFIX-vm-listener --rule-type Basic `
            --address-pool midwolf-$RULESUFFIX-vm-pool --http-settings midwolf-$RULESUFFIX-vm-settings

        Write-Host "VM rule is complete." -ForegroundColor Green
    }    

Write-Host('Finished creating rule.') -ForegroundColor Green


##################################################################################################################
### Remove shared entries from app gateway, remove the barebones listener settings etc.
##################################################################################################################

if ($GATEWAYTYPE -eq 'shared')
{
    $CHECKEXIST = az network application-gateway rule list -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME `
        --query "[?name == 'midwolf-$GATEWAYTYPE-umbraco-routing-rule'].[name]" -o tsv

    if($CHECKEXIST)
    {
        Write-Host('Removing any base entries from the shared gateway...') -ForegroundColor White

        ## clean up base rules if in shared mode, these are not required.
        $output = az network application-gateway rule delete -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME -n midwolf-$GATEWAYTYPE-umbraco-routing-rule
        $output = az network application-gateway address-pool delete -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME -n midwolf-$GATEWAYTYPE-umbraco-pool
        $output = az network application-gateway http-settings delete -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME -n midwolf-$GATEWAYTYPE-umbraco-settings
        $output = az network application-gateway http-listener delete -g $GATEWAYRESOURCEGROUP --gateway-name $APPGATEWAYNAME -n midwolf-$GATEWAYTYPE-umbraco-listener

        Write-Host('Finished cleaning the shared application gateway.') -ForegroundColor Green
    }
} 



##################################################################################################################
### VNET PEERING FROM THE APP GATEWAY VNET TO THE ENVIRONMENT VNET
##################################################################################################################

# Before adding the vnet peer, check one doesnt already exist for this environment
$peerExistsCheck = az network vnet peering list -g $GATEWAYRESOURCEGROUP --vnet-name $GATEWAYVNETNAME `
    --query "[?contains(remoteVirtualNetwork.resourceGroup, '$AZENVRESOURCEGROUP')].[name]" -o tsv

if(!$peerExistsCheck)
{
    Write-Host('Adding Vnet peerings from the  application gateway vnet to the environment...') -ForegroundColor White

        # The Vnet name used when creating the peer network, the vnet main tag indicates the main vnet used for hosting an environment.
        $environmentVnetName = az network vnet list -g $envResourceGroup --query "[?tags.vnet == 'main'].name" -o tsv

        $remoteVnetId = az network vnet show --resource-group $AZENVRESOURCEGROUP --name $environmentVnetName --query id --out tsv
        $appGatewayVnetId = az network vnet show --resource-group $GATEWAYRESOURCEGROUP --name $GATEWAYVNETNAME --query id --out tsv

        ## peering on gateway vnet
        $output = az network vnet peering create -g $GATEWAYRESOURCEGROUP -n midwolf-$GATEWAYTYPE-gateway-$RULESUFFIX-uksouth-vnetpeer `
            --vnet-name $GATEWAYVNETNAME --remote-vnet $remoteVnetId --allow-vnet-access

        ## peering on environment vnet
        $output = az network vnet peering create -g $AZENVRESOURCEGROUP -n midwolf-$RULESUFFIX-$GATEWAYTYPE-gateway-uksouth-vnetpeer `
            --vnet-name $environmentVnetName --remote-vnet $appGatewayVnetId --allow-vnet-access

    Write-Host('Finshed adding Vnet peerings from the application gateway vnet to the environment.') -ForegroundColor Green
}
else
{
    Write-Host("Vnet peer already exists for '" + $AZENVRESOURCEGROUP + "' skipping...") -ForegroundColor Blue
}

Write-Host('Script complete for environment ' + $RULESUFFIX) -ForegroundColor Green