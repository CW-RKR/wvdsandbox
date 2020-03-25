# Challenge 0: Setup Basics i.e. Network, AD, FS and do an AAD Sync using AD Connect

[back](../README.md)

In this challenge we will setup the basics requied for the WVD Sandbox. In order to save time we will use the Azure Cloud Shell to run some PowerShell code.  
> **Note**: With the use of Azure Cloud Shell we don't need to install something on your local box. No version conflics. And you are already authenticated at Azure ;-)

## 0. Create an Azure Cloud Shell - if you don't have one. :-)
```
[Azure Portal] -> Click the 'Cloud Shell' symbol close to your login details on the right upper corner.
```  
![Cloud Shell](CloudShell.png))  
The **'Cloud Shell' is an in-browser-accessible shell for managing Azure resources**. It already has the required SDKs and tools installed to interact with Azure. You can use either Bash or PowerShell.  
When being asked **choose PowerShell this time**.  
**The first time you use the 'Cloud Shell' you will be asked to setup a storage account** e.g. to store files you have uploaded persistently. [See](https://docs.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage)  

```
[Azure Portal] -> Click 'Show advanced settings'
```  
![Cloud Shell Storage Account Setup](CloudShell1.png)  

| Name | Value |
|---|---|
| Subscription  |  _your subscription_ |
| Cloud Shell Region  |  e.g. **West Europe** |   
| Resource Group  |  e.g. **rg-cloudshell** |   
| Storage Account  |  **_some unique value_** |   
| File Share  |  **cloudshell**|   

```
[Azure Portal] -> Create storage
```  
Once successful your shell should appear at the bottom of the page:  
![Cloud Shell in the Azure portal](CloudShell2.png)

## 1. Let's create some Resource Groups
Make sure you are using the right subscription, e.g. 
```PowerShell
Get-AzContext  
```  
Should give clarity. 
> To use a different subscription to deploy to you might try:  
>```PowerShell
>Get-AzSubscription 
>
>Set-AzContext -Subscription '%SubscriptionName%' 
>```  

Now let's **create some Resource Groups copy & paste the following code into the Cloud Shell**:  
```PowerShell
$RGPrefix = "rg-wvdsdbox-"
$RGSuffixes = @("basics","hostpool-1","hostpool-2","hostpool-3")
$RGLocation = 'westeurope'   # for alternatives try: 'Get-AzLocation | ft Location'

foreach ($RGSuffix in $RGSuffixes)
{
   New-AzResourceGroup -Name "$($RGPrefix)$($RGSuffix)" -Location $RGLocation
}
```  
As result you should get something like:  
![Some Resource Groups](SomeRGs.PNG)

## 2. Create the Network and Domain Controller.  
The following script deploys the **network** and the **domain controller** into the the 'rg-wvdsdbox-basics' resource group.  
Please **copy & paste this script into your Cloud Shell**:  

```PowerShell
New-AzResourceGroupDeployment -ResourceGroupName 'rg-wvdsdbox-basics' -Name 'NetworkSetup' -Mode Incremental -TemplateUri 'https://raw.githubusercontent.com/bfrankMS/wvdsandbox/master/BaseSetupArtefacts/01-ARM_Network.json'

# These are some parameters for the dc deployment
$templateParameterObject = @{
'vmName' =  [string] 'wvdsdbox-AD-VM1'
'adminUser'= [string] 'wvdadmin'
'adminPassword' = [securestring]$(Read-Host -AsSecureString -Prompt "Please enter a password for the vm and domain admin.")
'vmSize'=[string] 'Standard_F2s'
'DiskSku' = [string] 'StandardSSD_LRS'
'DomainName' = [string] 'contoso.local'
}
New-AzResourceGroupDeployment -ResourceGroupName 'rg-wvdsdbox-basics' -Name 'DCSetup' -Mode Incremental -TemplateUri 'https://raw.githubusercontent.com/bfrankMS/wvdsandbox/master/BaseSetupArtefacts/02-ARM_AD.json' -TemplateParameterObject $templateParameterObject

#cleanup: remove 'DCInstall' extension
Remove-AzVMCustomScriptExtension -Name 'DCInstall' -VMName $($templateParameterObject.vmName) -ResourceGroupName 'rg-wvdsdbox-basics' -Force  

#Do post AD installation steps: e.g. create OUs and some WVD Demo Users.
Set-AzVMCustomScriptExtension -Name 'PostDCActions' -VMName $($templateParameterObject.vmName) -ResourceGroupName 'rg-wvdsdbox-basics' -Location (Get-AzVM -ResourceGroupName 'rg-wvdsdbox-basics' -Name $($templateParameterObject.vmName)).Location -NoWait -Run 'CSE_AD_Post.ps1' -Argument "WVD $($templateParameterObject.adminPassword)" -FileUri 'https://raw.githubusercontent.com/bfrankMS/wvdsandbox/master/BaseSetupArtefacts/CSE_AD_Post.ps1'  
  
#Cleanup
Remove-AzVMCustomScriptExtension -Name 'PostDCActions' -VMName $($templateParameterObject.vmName) -ResourceGroupName 'rg-wvdsdbox-basics' -Force -NoWait  

```
> **Note**: The **password** used above needs to be **complex enough** - pls see [here](https://docs.microsoft.com/en-us/azure/virtual-machines/windows/faq#what-are-the-password-requirements-when-creating-a-vm) for details.

The deployment will take some time (20mins?) - please be patient. The result should look similar to this:  
![AD Deployment Result](ADDeploymentResult.png)  
  
## 3. Create the File server.  
```PowerShell
# These are some parameters for the File Server deployment
$templateParameterObject = @{
'vmName' =  [string] 'wvdsdbox-FS-VM1'
'adminUser'= [string] 'wvdadmin'
'adminPassword' = [securestring]$(Read-Host -AsSecureString -Prompt "Please enter a password for the vm and domain admin.")
'vmSize'=[string] 'Standard_F2s'
'DiskSku' = [string] 'StandardSSD_LRS'
'DomainName' = [string] 'contoso.local'
}
New-AzResourceGroupDeployment -ResourceGroupName 'rg-wvdsdbox-basics' -Name 'DCSetup' -Mode Incremental -TemplateUri 'https://raw.githubusercontent.com/bfrankMS/wvdsandbox/master/BaseSetupArtefacts/03-ARM_FS.json' -TemplateParameterObject $templateParameterObject


```