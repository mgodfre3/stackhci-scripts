<#
.SYNOPSIS 
    Deploys and configures a 2 node Lenovo SE350 Azure Stack HCI Cluster for a Proof of Concept.
.EXAMPLE
    .\Deploy_AZSHCI.ps1

.NOTES
    Prerequisites:
    *This script should be run from a Jump Workstation, with network communication to the ASHCI Physical Nodes that will be configured"
     
    * You will be asked to login to your Azure Subscription, as this will allow credentials from Azure Key Vault to be utilized.
    
    *The AD Group "Fabric Admins" needs to be made local admin on the Hosts.       
#>

#########################SET ALL VARIABLES########################### 
#Set Name of Node01
$Node01 = "gblrhshci01"

#Set Name of Node02
$Node02 = "gblrhshci02"

#Set IP for MGMT Node1 Nic
$node01_MgmtIP="192.168.0.110"

#Set IP for MGMT Node2 Nic
$node02_MgmtIP="192.168.0.111"

#Set Default GW IP
$GWIP = "192.168.0.1"

#Set IP of AD DNS Server
$DNSIP = "172.16.100.20"

#Set Server List 
$ServerList = $Node01, $Node02

#Set Cluster Name and Cluster IP
$ClusterName = "mcdhcicl"
$ClusterIP = "192.168.0.115"

#Set StoragePool Name
$StoragePoolName= "ASHCI Storage Pool 1"

#Set First Cluster Shared Volume Friendly Info
$CSVFriendlyname="Volume01-Thin"
$CSVSize=5GB

#Set name of AD Domain
$ADDomain = "mcd.local"

#########################SET ALL  Azure VARIABLES########################### 

$AzureSubID = "0c6c3a0d-0866-4e68-939d-ef81ca6f802e"

Login-AzAccount
Select-AzSubscription -Subscription $AzureSubID

#Set AD Domain Cred
$AzDJoin = Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "DomainJoinerSecret"
$ADcred = [pscredential]::new("mcd\djoiner",$AZDJoin.SecretValue)
#$ADpassword = ConvertTo-SecureString "" -AsPlainText -Force
#$ADCred = New-Object System.Management.Automation.PSCredential ("mcd\djoiner", $ADpassword)

#Set Cred for AAD tenant and subscription
$AADAccount = "azstackadmin@azurestackdemo1.onmicrosoft.com"
$AADAdmin=Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "AADAdmin"
$AADCred = [pscredential]::new("azstackadmin@azurestackdemo1.onmicrosoft.com",$AADAdmin.SecretValue)

###############################################################################################################################

Write-Host -ForegroundColor Green -Object "Configuring Managment Workstation"

#Set WinRM for remote management of nodes
winrm quickconfig
Enable-WSManCredSSP -Role Client -DelegateComputer * -Force

###############################################################################################################################
Write-Host -ForegroundColor Green -Object "Installing Required Features on Management Workstation"

#Install some PS modules if not already installed
Install-WindowsFeature -Name RSAT-Clustering,RSAT-Clustering-Mgmt,RSAT-Clustering-PowerShell,RSAT-Hyper-V-Tools

##########################################Configure Nodes####################################################################

Write-Host -ForegroundColor Green "Configuring Nodes"

#Add features, add PS modules, rename, join domain, reboot
Invoke-Command -ComputerName $ServerList -Credential $ADCred -ScriptBlock {
    Install-WindowsFeature -Name "BitLocker", "Data-Center-Bridging", "Failover-Clustering", "FS-FileServer", "FS-Data-Deduplication", "Hyper-V", "Hyper-V-PowerShell", "RSAT-AD-Powershell", "RSAT-Clustering-Powershell","FS-Data-Deduplication", "Storage-Replica", "NetworkATC" -IncludeAllSubFeature -IncludeManagementTools
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module -Name Az.StackHCI -Force -All
    Enable-WSManCredSSP -Role Server -Force
}

               
Restart-Computer -ComputerName $ServerList -Protocol WSMan -Wait -For PowerShell -Force

#Pause for a bit - let changes apply before moving on...
sleep 180

###############################################################################################################################

##################################################Configure Node01#############################################################
Write-Host -ForegroundColor Green -Object "Configure Node 01"

Invoke-Command -ComputerName $Node01 -Credential $ADCred -ScriptBlock {

# Configure IP and subnet mask, no default gateway for Storage interfaces
    #MGMT
    New-NetIPAddress -InterfaceAlias "LOM2 Port3" -IPAddress $using:node01_MgmtIP -PrefixLength 24 -DefaultGateway $using:GWIP  | Set-DnsClientServerAddress -ServerAddresses $using:DNSIP
    #Storage 
    New-NetIPAddress -InterfaceAlias "LOM1 Port1" -IPAddress 172.16.0.1 -PrefixLength 24
    New-NetIPAddress -InterfaceAlias "LOM1 Port2" -IPAddress 172.16.1.1 -PrefixLength 24

 

}


############################################################Configure Node02#############################################################
Write-Host -ForegroundColor Green -Object "Configure Node02"

Invoke-Command -ComputerName $Node02 -Credential $ADCred -ScriptBlock {
    # Configure IP and subnet mask, no default gateway for Storage interfaces
    #MGMT
    New-NetIPAddress -InterfaceAlias "LOM2 Port3" -IPAddress $using:node02_MgmtIP -PrefixLength 24 -DefaultGateway $using:GWIP| Set-DnsClientServerAddress -ServerAddresses $using:DNSIP
    #Storage 
    New-NetIPAddress -InterfaceAlias "LOM1 Port1" -IPAddress 172.16.0.2 -PrefixLength 24
    New-NetIPAddress -InterfaceAlias "LOM1 Port2" -IPAddress 172.16.1.2 -PrefixLength 24

    

}
#########################################################################################################################################


#########################################################Configure HCI Cluster##########################################################

Write-Host -ForegroundColor Green -Object "Prepare Storage"

#Clear Storage
Invoke-Command ($ServerList) {
    Update-StorageProviderCache
    Get-StoragePool | ? IsPrimordial -eq $false | Set-StoragePool -IsReadOnly:$false -ErrorAction SilentlyContinue
    Get-StoragePool | ? IsPrimordial -eq $false | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
    Get-StoragePool | ? IsPrimordial -eq $false | Remove-StoragePool -Confirm:$false -ErrorAction SilentlyContinue
    Get-PhysicalDisk | Reset-PhysicalDisk -ErrorAction SilentlyContinue
    Get-Disk | ? Number -ne $null | ? IsBoot -ne $true | ? IsSystem -ne $true | ? PartitionStyle -ne RAW | % {
        $_ | Set-Disk -isoffline:$false
        $_ | Set-Disk -isreadonly:$false
        $_ | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
        $_ | Set-Disk -isreadonly:$true
        $_ | Set-Disk -isoffline:$true
    }
    Get-Disk | Where Number -Ne $Null | Where IsBoot -Ne $True | Where IsSystem -Ne $True | Where PartitionStyle -Eq RAW | Group -NoElement -Property FriendlyName
} | Sort -Property PsComputerName, Count

#########################################################################################################################################
Write-Host -ForegroundColor Green -Object "Creating the Cluster"

#Create the Cluster
Test-Cluster –Node $Node01, $Node02 –Include "Storage Spaces Direct", "Inventory", "Network", "System Configuration"
New-Cluster -Name $ClusterName -Node $Node01, $Node02 -StaticAddress $ClusterIP -NoStorage

#Pause for a bit then clear DNS cache.
sleep 30
Clear-DnsClientCache

# Update the cluster network names that were created by default.  First, look at what's there
Get-ClusterNetwork -Cluster $ClusterName  | ft Name, Role, Address

# Change the cluster network names so they are consistent with the individual nodes
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 2").Name = "Storage1"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 1").Name = "Storage2"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 4").Name = "OOB"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 3").Name = "MGMT"

# Check to make sure the cluster network names were changed correctly
Get-ClusterNetwork -Cluster $ClusterName | ft Name, Role, Address

#########################################################################################################################################
Write-Host -ForegroundColor Green -Object "Set Cluster Live Migration Settings"

#Set Cluster Live Migration Settings 
Enable-VMMigration -ComputerName $ServerList
Add-VMMigrationNetwork -computername $ServerList -Subnet 172.16.0.0/24 -Priority 1 
Add-VMMigrationNetwork -computername $ServerList -Subnet 172.16.1.0/24 -Priority 2 
Set-VMHost -ComputerName $ServerList -MaximumStorageMigrations 2 -MaximumVirtualMachineMigrations 2 -VirtualMachineMigrationPerformanceOption SMB -UseAnyNetworkForMigration $false 

#########################################################################################################################################
Write-Host -ForegroundColor Green -Object "Enable Storage Spaces Direct"

#Enable S2D
Enable-ClusterStorageSpacesDirect  -CimSession $ClusterName -PoolFriendlyName $StoragePoolName -Confirm:0 

#########################################################################################################################################

#Update Cluster Function Level

$cfl=Get-Cluster -Name $ClusterName 
if ($cfl.ClusterFunctionalLevel -lt "12") {
write-host -ForegroundColor yellow -Object "Cluster Functional Level needs to be upgraded"  

Update-ClusterFunctionalLevel -Cluster $ClusterName -Verbose -Force
}

else {
write-host -ForegroundColor Green -Object "Cluster Functional Level is good"


}

#storage Pool Level check and upgrade

$spl=Get-StoragePool -CimSession $ClusterName -FriendlyName $StoragePoolName
 
if ($spl.version -ne "Windows Server 2022") {
write-host -ForegroundColor yellow -Object "Storage Pool Level needs to be upgraded"

Update-StoragePool -FriendlyName $StoragePoolName -Confirm:0 -CimSession $Node01
}
else {
write-host -ForegroundColor Green -Object "Storage Pool level is set to Windows Server 2022"
}

#########################################################################################################################################
write-host -ForegroundColor Green -Object "Creating Cluster Shared Volume"

#Create S2D Tier and Volumes

Invoke-Command ($Node01) {
    #Create Storage Tier for Nested Resiliancy
New-StorageTier -StoragePoolFriendlyName $using:StoragePoolName -FriendlyName NestedMirror -ResiliencySettingName Mirror -MediaType SSD -NumberOfDataCopies 4 -ProvisioningType Thin

#Create Nested Mirror Volume
New-Volume -StoragePoolFriendlyName $using:StoragePoolName -FriendlyName $using:CSVFriendlyname -StorageTierFriendlyNames NestedMirror -StorageTierSizes $using:CSVSize -ProvisioningType Thin | Enable-DedupVolume -UsageType HyperV 

}



############################################################Set Net-Intent########################################################
write-host -ForegroundColor Green -Object "Setting NetworkATC Configuration"

Invoke-Command -ComputerName $Node01 -Credential $ADcred -Authentication Credssp {

#North-South Net-Intents
Add-NetIntent -ClusterName $using:ClusterName -AdapterName "LOM2 Port3", "LOM2 Port4" -Name HCI -Compute -Management  

#Storage NetIntent
Add-NetIntent -ClusterName $using:ClusterName -AdapterName "LOM1 Port1", "LOM1 Port2"  -Name SMB -Storage
}

$tnc_clip=Test-NetConnection $ClusterIP
if ($tnc_clip.pingsucceded -eq "true") {
    write-host -ForegroundColor Green -Object "Cluster in online, NetworkATC was successful"
}
else  {
    Write-Host -ForegroundColor Red -Object "Please ensure Cluster Resources are online and Network configration is correct on nodes";
    Start-Sleep 180
}

#########################################################################################################################################

<#
#Configure for 21H2 Preview Channel
Invoke-Command ($ServerList) {
    Set-WSManQuickConfig -Force
    Enable-PSRemoting
    Set-NetFirewallRule -Group "@firewallapi.dll,-36751" -Profile Domain -Enabled true
    Set-PreviewChannel
}

Restart-Computer -ComputerName $ServerList -Protocol WSMan -Wait -For PowerShell -Force
#Pause for a bit - let changes apply before moving on...
sleep 180


#Enable CAU and update to latest 21H2 bits...
$CAURoleName="ASHCICL-CAU"
Add-CauClusterRole -ClusterName $ClusterName -MaxFailedNodes 0 -RequireAllNodesOnline -EnableFirewallRules -VirtualComputerObjectName $CAURoleName -Force -CauPluginName Microsoft.WindowsUpdatePlugin -MaxRetriesPerNode 3 -CauPluginArguments @{ 'IncludeRecommendedUpdates' = 'False' } -StartDate "3/2/2017 3:00:00 AM" -DaysOfWeek 4 -WeeksOfMonth @(3) -verbose
#Invoke-CauScan -ClusterName GBLRHSHCICLUS -CauPluginName "Microsoft.RollingUpgradePlugin" -CauPluginArguments @{'WuConnected'='true';} -Verbose | fl *
Invoke-CauRun -ClusterName $ClusterName -CauPluginName "Microsoft.RollingUpgradePlugin" -CauPluginArguments @{'WuConnected'='true';} -Verbose -EnableFirewallRules -Force
#>

#########################################################################################################################################
write-host -ForegroundColor Green -Object "Set Cloud Witness"

#Set Cloud Witness
Set-ClusterQuorum -Cluster $ClusterName -Credential $AADCred -CloudWitness -AccountName hciwitnessmcd  -AccessKey "lj7LGQrmkyDoMH2AnHXQjp8EI+gWMPsKDYmMBv1mL7Ldo0cwz+aYIoDA8fO3hJoSyY/fUksiOWlZ/8Heme1XGw=="

#########################################################################################################################################
write-host -ForegroundColor Green -Object "Register the Cluster to Azure Subscription"

#Register Cluster with Azure
Invoke-Command -ComputerName $Node01 {
    Connect-AzAccount -Credential $using:AADCred
    $armtoken = Get-AzAccessToken
    $graphtoken = Get-AzAccessToken -ResourceTypeName AadGraph
    Register-AzStackHCI -SubscriptionId $using:AzureSubID -ComputerName $using:Node01 -AccountId $using:AADAccount -ArmAccessToken $armtoken.Token -GraphAccessToken $graphtoken.Token -EnableAzureArcServer -Credential $using:ADCred 
}
############################################################################################################################################


write-host -ForegroundColor Green -Object "Cluster is Deployed; Enjoy!"
