﻿<#
    purpose: This will configure Azure files in your subscription for AD auth.
    run this on: domain member server
    by bfrank
    reference: https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-active-directory-enable
#>

#Login with an Azure AD credential that has either storage account owner or contributer RBAC assignment
Connect-AzAccount

#Select the target subscription for the current session
$subscription = Get-AzSubscription | Out-GridView -Title "Select the right subscription" -OutputMode Single | Select-AzSubscription

#Create Azure File share on a premium storage account as FSLogix profile path
$resourceGroup = Get-AzResourceGroup | Out-GridView -Title 'Select the target resource group for the profiles storage account' -OutputMode Single 
$storageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroup.ResourceGroupName `
 -Name "wvdprofiles$(Get-Random -Minimum 1000 -Maximum 9999)" `
 -SkuName "Premium_LRS" `
 -Location $resourceGroup.Location `
 -Kind "FileStorage"

$fileShareName = "wvdprofiles"
#create share and set quota
$share = New-AzStorageShare -Name $fileShareName -Context $storageAccount.Context 
#Set-AzStorageShareQuota -ShareName $($share.Name) -Quota 100 -Context $share.Context

(Get-AzStorageShare -Name $share.Name -Context $share.Context).ShareProperties

#Define parameters
$SubscriptionId = $subscription.Subscription.Id
#$storageAccount = Get-AzResource -ResourceType 'Microsoft.Storage/storageAccounts' |  Out-GridView -Title "Select the right storage account" -OutputMode Single
$ResourceGroupName = $storageAccount.ResourceGroupName
$StorageAccountName = $storageAccount.StorageAccountName
$OUName = "WVD"
$DomainName = $env:USERDNSDOMAIN
#$ExternalDomainName = "wvdsandbox.net"


# Register the target storage account with your active directory environment under the target OU (for example: specify the OU with Name as "UserAccounts" or DistinguishedName as "OU=UserAccounts,DC=CONTOSO,DC=COM"). 
# You can use to this PowerShell cmdlet: Get-ADOrganizationalUnit to find the Name and DistinguishedName of your target OU. If you are using the OU Name, specify it with -OrganizationalUnitName as shown below. If you are using the OU DistinguishedName, you can set it with -OrganizationalUnitDistinguishedName. You can choose to provide one of the two names to specify the target OU.
# You can choose to create the identity that represents the storage account as either a Service Logon Account or Computer Account (default parameter value), depends on the AD permission you have and preference. 
# Run Get-Help Join-AzStorageAccountForAuth for more details on this cmdlet.

#Import AzFilesHybrid module
Import-Module -Name AzFilesHybrid -Force

#use service account -> will create an account in AD
#BTW (computer account ist not recommended) 
Join-AzStorageAccountForAuth -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -DomainAccountType ComputerAccount -OrganizationalUnitName $OUName -Domain $DomainName -OverwriteExistingADObject

#check
$storageaccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
# List the directory service that the storage account is selected to use for Authentication
$storageaccount.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
#Expected result = "AD"

# List the directory domain information if the storage account is enabled for AD authentication for Files
$storageaccount.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties
#Expected result "<your domain name>"

<#
# Set the feature flag on the target storage account and provide the required AD domain information
Set-AzStorageAccount -ResourceGroupName "$ResourceGroupName"  `
-Name "$StorageAccountName " `
-EnableActiveDirectoryDomainServicesForFile $true `
-ActiveDirectoryDomainName $ExternalDomainName `
-ActiveDirectoryNetBiosDomainName $ExternalDomainName `
-ActiveDirectoryForestName $ExternalDomainName `
-ActiveDirectoryDomainGuid "............" `
-ActiveDirectoryDomainSid "............." `
-ActiveDirectoryAzureStorageSid ".........." 

#You can run the Debug-AzStorageAccountAuth cmdlet to conduct a set of basic checks on your AD configuration with the logged on AD user. This cmdlet is supported on AzFilesHybrid v0.1.2+ version. For more details on the checks performed in this cmdlet, see Azure Files Windows troubleshooting guide.
Debug-AzStorageAccountAuth -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName -Verbose
#>


#Now we will set the AD permissions on the storage account
# sort of equivalent as the 'Share permissions' in old onpremise times.
$FileShareContributorRole = Get-AzRoleDefinition "Storage File Data SMB Share Contributor" 
#Use one of the built-in roles: Storage File Data SMB Share Reader, Storage File Data SMB Share Contributor, Storage File Data SMB Share Elevated Contributor
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/fileshares/$fileShareName"

$wvdusers = Get-AzADGroup -DisplayName "WVD Users"
New-AzRoleAssignment -ObjectId $wvdusers.Id -RoleDefinitionName $FileShareContributorRole.Name -Scope $scope

#mount the drive using the storage account key. then apply NTFS permissions 
$ackey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value 

$azurefilesURI = "$StorageAccountName.file.core.windows.net"
$connectTestResult = Test-NetConnection -ComputerName $azurefilesURI -Port 445
if ($connectTestResult.TcpTestSucceeded) {
    # Save the password so the drive will persist on reboot
    cmd.exe /C "cmdkey /add:""$StorageAccountName.file.core.windows.net"" /user:""Azure\$StorageAccountName"" /pass:""$ackey"""

    # Mount the drive
    New-PSDrive -Name Z -PSProvider FileSystem -Root "\\$azurefilesURI\$fileShareName" -Persist
}
else {
    Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
}


#1st remove all exiting permissions.
$acl = Get-Acl z:\
$acl.Access | % { $acl.RemoveAccessRule($_) }
$acl.SetAccessRuleProtection($true, $false)
$acl | Set-Acl
#add full control for 'the usual suspects'
$users = @("$DomainName\Domain Admins", "System", "Administrators", "Creator Owner" )
foreach ($user in $users) {
    $new = $user, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    $accessRule = new-object System.Security.AccessControl.FileSystemAccessRule $new
    $acl.AddAccessRule($accessRule)
    $acl | Set-Acl 
}

#add read & write on parent folder ->required for FSLogix - no inheritence
$allowWVD = "WVD Users", "ReadData, AppendData, ExecuteFile, ReadAttributes, Synchronize", "None", "None", "Allow"
$accessRule = new-object System.Security.AccessControl.FileSystemAccessRule $allowWVD
$acl.AddAccessRule($accessRule)
$acl | Set-Acl 

