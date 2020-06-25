param  
( 
[Parameter(Mandatory=$true, HelpMessage="The resource group where the Gateway should be contained.")] [String]$resourceGroup,
[Parameter(Mandatory=$true, HelpMessage="The gateway type is either 'shared' or 'prod'.")][ValidateSet('shared','prod')][String]$gwType
) 

##################################################################################################################
#
#  This script deploys the  application gateway into a Vnet.
#
##################################################################################################################

# See the parameter help text for an explanation on the variables.
$GATEWAYRESOURCEGROUP = $resourceGroup
$GATEWAYTYPE = $gwType
$PARAMETERFILETYPE = 'shared'

# set the correct parameter file type according to gateway type.
if ($GATEWAYTYPE -eq 'prod')
{
    $PARAMETERFILETYPE = 'production'
}

# credentials info for logging into azure, in a pipe line these are retrieved automatically and use the principle id in devops.
$USER = $env:servicePrincipalId 
$PASSWORD = $env:servicePrincipalKey 
$TENANT = $env:tenantId 

Write-Host('Logging into Azure...') -ForegroundColor White

    # login to the azure subscription using service principle.
    $output = az login --service-principal --username $USER  --password $PASSWORD  --tenant $TENANT

Write-Host("Deploying resources into '$GATEWAYRESOURCEGROUP' ...") -ForegroundColor White

##################################################################################################################
### AZURE RESOURCE NAMES ###
##################################################################################################################

$VNETNAME = 'midwolf-' + $GATEWAYTYPE + '-gateways-uksouth-vnet'
$SUBNETNAME = 'midwolf-' + $GATEWAYTYPE + '-gateway-uksouth-snet'
$NSGNAME = 'midwolf-' + $GATEWAYTYPE + '-gateway-uksouth-nsg'



##################################################################################################################
### NSG ###
##################################################################################################################
Write-Host('Deploying the NSG for ''' + $GATEWAYTYPE + ''' environment...') -ForegroundColor White

Write-Host "Using parameters file '/parameters/nsg.$PARAMETERFILETYPE.params.json'" -ForegroundColor Blue
    
    # Deploy nsg using arm template
    $output = az deployment group create --name deployIntAppGatewayNsg --resource-group $GATEWAYRESOURCEGROUP  `
        --template-file templates/nsg.json --parameters @parameters/nsg.$PARAMETERFILETYPE.params.json

    $LastExitCode
    
    if ($LastExitCode -gt 0) {
        Write-Host "Error creating NSG"
        return
    }

Write-Host('NSG for '''+ $GATEWAYTYPE +''' environment has been created.') -ForegroundColor Green




##################################################################################################################
### Vnet and subnet ###
##################################################################################################################
Write-Host('Deploying the Vnet and subnet for ''' + $GATEWAYTYPE + ''' environment...') -ForegroundColor White

Write-Host "Using parameters file '/parameters/vnet.$PARAMETERFILETYPE.params.json'" -ForegroundColor Blue

    # Check if vnet exists
    $vnetCheck = az network vnet list -g $GATEWAYRESOURCEGROUP --query "[?tags.vnet == 'gateways' && name == '$VNETNAME'].[name]" -o tsv
    
    if(!$vnetCheck)
    {
        # Deploy vnet
        $output = az deployment group create --name deployIntAppGatewayVnet --resource-group $GATEWAYRESOURCEGROUP  `
            --template-file templates/vnet.json --parameters @parameters/vnet.$PARAMETERFILETYPE.params.json

        $LastExitCode
    
        if ($LastExitCode -gt 0) {
            Write-Host "Error creating Vnet" -ForegroundColor Red
            return
        }
    }
    else
    {
        Write-Host "Vnet already exists skipping..." -ForegroundColor Blue
    }
    
    # get the ip address space for the vnet and set subnet range
    $VnetAddressSpace = az network vnet list -g $GATEWAYRESOURCEGROUP --query "[?tags.vnet == 'gateways' && name == '$VNETNAME'].addressSpace.addressPrefixes[0]" -o tsv

    if(!$VNETADDRESSSPACE)
    {
        Write-Host "Error finding address space from the gateways vnet." -ForegroundColor Red
        return
    }
    else
    {
        Write-Host "Creating subnet..." -ForegroundColor Blue
    }

    $vNetAddressArray = $VnetAddressSpace.Split('.')
    $subnetAddress = $vNetAddressArray[0] + '.' + $vNetAddressArray[1] + '.1.0/24'

    # create subnet for the app gateway.
    $output = az network vnet subnet create -g $GATEWAYRESOURCEGROUP --vnet-name $VNETNAME `
        -n $SUBNETNAME --address-prefixes $subnetAddress --network-security-group $NSGNAME `
        --service-endpoints Microsoft.KeyVault

        $LastExitCode
        
        if ($LastExitCode -gt 0) {
            Write-Host "Error creating Vnet and subnet" -ForegroundColor Red
            return
        }

Write-Host('Vnet and subnet for '''+ $GATEWAYTYPE +''' environment has been created.') -ForegroundColor Green




##################################################################################################################
###  Application Gateway ###
##################################################################################################################

Write-Host('Deploying the  App gateway barebones for ''' + $GATEWAYTYPE + ''' environment.') -ForegroundColor White

Write-Host "Using parameters file '/parameters/gateway.$PARAMETERFILETYPE.params.json'" -ForegroundColor Blue

    # Deploy the barebones app gateway into the vnet with umbraco based listener set up for the environment.
    $output = az deployment group create --name deployIntAppGateway --resource-group $GATEWAYRESOURCEGROUP  `
        --template-file templates/gateway.json --parameters @parameters/gateway.$PARAMETERFILETYPE.params.json

        $LastExitCode
        if ($LastExitCode -gt 0) {
            Write-Host "Error creating the application gateway"
            return
        }

Write-Host(' App Gateway barebones for ''' + $GATEWAYTYPE + ''' environment has been created.') -ForegroundColor Green