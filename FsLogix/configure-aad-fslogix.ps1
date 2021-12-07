$resourceGroupName = "RG_BPS_WE_STORAGE_MU"
$location = "WestEurope"
$rgParameters = @{
    resourceGroupName = $resourceGroupName
    location          = $location 
}
$resourceGroup = New-AzResourceGroup @rgParameters

$storageAccountParameters = @{
    Name    = "fslogix$(Get-Random -max 10000)"
    SkuName = "Premium_LRS"
    Kind    = "FileStorage"
}
$storageAccount = $resourceGroup | New-AzStorageAccount @storageAccountParameters
$storageAccount 

$saShareParameters = @{
    Name       = "profiles"
    AccessTier = "Premium"
    QuotaGiB   = 1024
}
$saShare = $storageAccount | New-AzRmStorageShare @saShareParameters
$saShare

$script:AzureUrl = "https://management.azure.com/"
# Add contributor role at subscription level
$script:token = GetAuthToken -resource $script:AzureUrl
$guid = (new-guid).guid
$smbShareContributorRoleId = "0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"
$roleDefinitionId = "/subscriptions/" + $(get-azcontext).Subscription.id + "/providers/Microsoft.Authorization/roleDefinitions/" + $smbShareContributorRoleId
$url = $script:AzureUrl + $storageAccount.id + "/providers/Microsoft.Authorization/roleAssignments/$($guid)?api-version=2018-07-01"
$body = @{
    properties = @{
        roleDefinitionId = $roleDefinitionId
        principalId      = "924f209a-744c-4470-99d4-02d90f698438" # AD Group ID
        scope            = $storageAccount.id
    }
}
$jsonBody = $body | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri $url -Method PUT -Body $jsonBody -headers $script:token

# Kerberos enable
$Uri = $script:AzureUrl + $storageAccount.id + "?api-version=2021-04-01"
$json = 
@{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            directoryServiceOptions = "AADKERB"
        }
    }
}
$json = $json | ConvertTo-Json -Depth 99
$token = $(Get-AzAccessToken).Token
$headers = @{ Authorization = "Bearer $token" }
try {
    Invoke-RestMethod -Uri $Uri -ContentType 'application/json' -Method PATCH -Headers $Headers -Body $json;
}
catch {
    Write-Host $_.Exception.ToString()
    Write-Error -Message "Caught exception setting Storage Account directoryServiceOptions=AADKERB: $_" -ErrorAction Stop
} 

# Create app registration
$servicePrincipalNames = [System.Collections.Arraylist]::New()
$servicePrincipalNames.Add('HTTP/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null
$servicePrincipalNames.Add('CIFS/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null
$servicePrincipalNames.Add('HOST/{0}.file.core.windows.net' -f $storageAccount.StorageAccountName) | Out-Null

$script:graphWindowsUrl = "https://graph.windows.net"
$script:graphWindowsToken = GetAuthToken -resource $script:graphWindowsUrl

$url = $script:graphWindowsUrl + "/761bd9eb-2b5e-4a6c-8608-73ae0195169e/applications?api-version=1.6"
$body = @{
    displayName           = $storageAccount.StorageAccountName
    identifierUris        = @($servicePrincipalNames)
    GroupMembershipClaims = "All"
}
$postBody = $body | ConvertTo-Json -Depth 4
$application = Invoke-RestMethod -Uri $url -Method POST -Body $postBody -Headers $script:graphWindowsToken -UseBasicParsing

# assign permissions
$permissions = @{
    resourceAppId  = "00000003-0000-0000-c000-000000000000"
    resourceAccess = @(
        @{
            id   = "37f7f235-527c-4136-accd-4a02d197296e" #open.id
            type = "Scope"
        },
        @{
            id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" #user.read
            type = "Scope"
        }
    )
}
$script:token = GetAuthToken -resource "https://graph.microsoft.com"
Add-ApplicationPermissions -AppId $application.ObjectId -permissions $permissions 

# Create SP
$newSp = New-SPFromApp -AppId $application.AppId  -ServicePrincipalType "Application"
### 059f3e1f-c67d-4d58-a1f9-d58cfe8a49e3 is per tenant verschillend (kan)
Consent-ApplicationPermissions -ServicePrincipalId $newSp.id  -ResourceId "059f3e1f-c67d-4d58-a1f9-d58cfe8a49e3" -Scope "open.id user.read"

#$storageAccount = get-azstorageaccount -ResourceGroupName "RG_BPS_WE_STORAGE_MU" -name fslogix4743
# Assign password
$kerbKey1 =  $storageAccount | Get-AzStorageAccountKey -ListKerbKey | Where-Object { $_.KeyName -like "kerb1" }
$aadPasswordBuffer = [System.Linq.Enumerable]::Take([System.Convert]::FromBase64String($kerbKey1.Value), 32);
$password = "kk:" + [System.Convert]::ToBase64String($aadPasswordBuffer);
$url = "https://graph.windows.net/" + $(get-azcontext).Tenant.id + "/servicePrincipals/" + $newSp.id + "?api-version=1.6"
$body = @{
    passwordCredentials = @(
        @{
            customKeyIdentifier = $null
            startDate           = [DateTime]::UtcNow.ToString("s")
            endDate             = [DateTime]::UtcNow.AddDays(365).ToString("s")
            value               = $password
        }
    )
}
$postBody = $body | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri $url -Method PATCH -Body $postBody -Headers $script:graphWindowsToken


$vm = Get-AzVM -name "BPS-ADC-01" -ResourceGroupName "RG_BPS_WE_P_ActiveDirectory"
$output = $vm | invoke-azvmruncommand -CommandId 'RunPowerShellScript' -ScriptPath 'local-domaininfo.ps1'
$domainGuid = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainGuid
$domainName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainName
$domainSid = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).domainSid
$forestName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).forestName
$netBiosDomainName = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).netBiosDomainName
$azureStorageSid = ($output.Value[0].Message -replace '(?<!:.*):', '=' | ConvertFrom-StringData).azureStorageSid

$body = @{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            directoryServiceOptions   = "AADKERB";
            activeDirectoryProperties = @{
                domainName        = $domainName
                netBiosDomainName = $netBiosDomainName
                forestName        = $forestName
                domainGuid        = $domainGuid
                domainSid         = $domainSid
                azureStorageSid   = $azureStorageSid
            }
        }
    }
}
$Uri = $script:AzureUrl + $storageAccount.Id + "?api-version=2021-04-01"
$script:token = GetAuthToken -resource $script:AzureUrl
$jsonBody = $body | ConvertTo-Json -Depth 99
Invoke-RestMethod -Uri $Uri -ContentType 'application/json' -Method PATCH -Headers $script:token -Body $jsonBody



# Testing
$generalParameters = @{
    ResourceGroupName = "RG_BPS_WE_AVD_MU"
    vmName            = "AAD-VM-0"
    Name              = "FSLogixTest"
}
$extensionParameters = @{
    Location   = 'westeurope'
    FileUri    = "https://raw.githubusercontent.com/srozemuller/AVD/main/FsLogix/test-fslogix-deployment.ps1"
    Run = 'test-fslogix-deployment.ps1'
    ForceReRun = $true
}
Set-AzVMCustomScriptExtension @generalParameters @extensionParameters

Get-AzVMExtension @generalParameters | Remove-AzVMExtension -Force