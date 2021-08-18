#########################SET ALL VARIABLES########################### 
#Set Name of Node01
$Node01 = "MCDHCI1"

#Set Name of Node02
$Node02 = "MCDHCI2"

#Set IP for MGMT Node1 Nic
$node01_MgmtIP=""

#Set IP for MGMT Node2 Nic
$node02_MgmtIP=""

#Set Default GW IP
$GWIP = ""

#Set IP of AD DNS Server
$DNSIP = "172.16.100.20"

#Set Server List 
$ServerList = $Node01, $Node02

#Set Cluster Name and Cluster IP
$ClusterName = "mcdhcicl"
$ClusterIP = ""

#Set StoragePool Name
$StoragePoolName= "ASHCI Storage Pool 1"

#Set First Cluster Shared Volume Friendly Info
$CSVFriendlyname="Volume01-Thin"
$CSVSize=5GB

#Set name of AD Domain
$ADDomain = "mcd.local"

#Set AD Domain Cred
$AzDJoin = Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "DomainJoinerSecret"
$cred = [pscredential]::new("mcd\djoiner",$AZDJoin.SecretValue)
#$ADpassword = ConvertTo-SecureString "" -AsPlainText -Force
#$ADCred = New-Object System.Management.Automation.PSCredential ("mcd\djoiner", $ADpassword)

#Set Cred for AAD tenant and subscription
$AADAccount = "azstackadmin@azurestackdemo1.onmicrosoft.com"
$AADAdmin=Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "AADAdmin"
$AADCred = [pscredential]::new("azstackadmin@azurestackdemo1.onmicrosoft.com",$AADAdmin.SecretValue)
$AzureSubID = "0c6c3a0d-0866-4e68-939d-ef81ca6f802e"
###############################################################################################################################

#Set WinRM for remote management of nodes
winrm quickconfig

#Install some PS modules if not already installed
Install-WindowsFeature -Name RSAT-Clustering,RSAT-Clustering-Mgmt,RSAT-Clustering-PowerShell,RSAT-Hyper-V-Tools

##########################################Configure Nodes####################################################################
#Add features, add PS modules, rename, join domain, reboot
Invoke-Command -ComputerName $ServerList -Credential $ADCred -ScriptBlock {
    Install-WindowsFeature -Name "BitLocker", "Data-Center-Bridging", "Failover-Clustering", "FS-FileServer", "FS-Data-Deduplication", "Hyper-V", "Hyper-V-PowerShell", "RSAT-AD-Powershell", "RSAT-Clustering,"FS-Data-Deduplication",PowerShell", "Storage-Replica", "NetworkATC" -IncludeAllSubFeature -IncludeManagementTools
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module -Name Az.StackHCI -Force -All
}

Restart-Computer -ComputerName $ServerList -Protocol WSMan -Wait -For PowerShell -Force

#Pause for a bit - let changes apply before moving on...
sleep 180
###############################################################################################################################

##################################################Configure Node01#############################################################
Invoke-Command -ComputerName $Node01 -Credential $ADCred -ScriptBlock {

# Configure IP and subnet mask, no default gateway for Storage interfaces
    #MGMT
    New-NetIPAddress -InterfaceAlias "LOM1 Port 3" -IPAddress $using:node01_MgmtIP -PrefixLength 24 | Set-DnsClientServerAddress -ServerAddresses $DNSIP
    #Storage 
    New-NetIPAddress -InterfaceAlias "LOM1 Port 1" -IPAddress 172.16.0.1 -PrefixLength 24
    New-NetIPAddress -InterfaceAlias "LOM1 Port 2" -IPAddress 172.16.1.1 -PrefixLength 24

 

}


############################################################Configure Node02#############################################################

Invoke-Command -ComputerName $Node02 -Credential $ADCred -ScriptBlock {
    # Configure IP and subnet mask, no default gateway for Storage interfaces
    #MGMT
    New-NetIPAddress -InterfaceAlias "LOM1 Port 3" -IPAddress $using:node02_MgmtIP -PrefixLength 24 | Set-DnsClientServerAddress -ServerAddresses $DNSIP
    #Storage 
    New-NetIPAddress -InterfaceAlias "LOM Port 1" -IPAddress 172.16.0.2 -PrefixLength 24
    New-NetIPAddress -InterfaceAlias "LOM Port 2" -IPAddress 172.16.1.2 -PrefixLength 24

    

}
#########################################################################################################################################


#########################################################Configure HCI Cluster##########################################################
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

#Create the Cluster
Test-Cluster –Node $Node01, $Node02 –Include "Storage Spaces Direct", "Inventory", "Network", "System Configuration"
New-Cluster -Name $ClusterName -Node $Node01, $Node02 -StaticAddress $ClusterIP -NoStorage

#Pause for a bit then clear DNS cache.
sleep 30
Clear-DnsClientCache

# Update the cluster network names that were created by default.  First, look at what's there
Get-ClusterNetwork -Cluster $ClusterName  | ft Name, Role, Address

# Change the cluster network names so they are consistent with the individual nodes
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 3").Name = "Storage1"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 4").Name = "Storage2"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 2").Name = "OOB"
(Get-ClusterNetwork -Cluster $ClusterName -Name "Cluster Network 1").Name = "MGMT"

# Check to make sure the cluster network names were changed correctly
Get-ClusterNetwork -Cluster $ClusterName | ft Name, Role, Address

#Set Cluster Live Migration Settings 
Enable-VMMigration -ComputerName $ServerList
Add-VMMigrationNetwork -computername $ServerList -Subnet 172.16.0.0/24 -Priority 1 
Add-VMMigrationNetwork -computername $ServerList -Subnet 172.16.1.0/24 -Priority 2 
Set-VMHost -ComputerName $ServerList -MaximumStorageMigrations 2 -MaximumVirtualMachineMigrations 2 -VirtualMachineMigrationPerformanceOption SMB -UseAnyNetworkForMigration $false 


#Enable S2D
Enable-ClusterStorageSpacesDirect  -CimSession $ClusterName -PoolFriendlyName $StoragePoolName -Confirm:0 

#Update Cluster Function Level

Update-ClusterFunctionalLevel -Cluster $ClusterName -Verbose -Force
Update-StoragePool -FriendlyName $StoragePoolName -Confirm:0


#Create S2D Tier and Volumes

Invoke-Command ($Node01) {
    #Create Storage Tier for Nested Resiliancy
New-StorageTier -StoragePoolFriendlyName $using:StoragePoolName -FriendlyName NestedMirror -ResiliencySettingName Mirror -MediaType HDD -NumberOfDataCopies 4 -ProvisioningType Thin

#Create Nested Mirror Volume
New-Volume -StoragePoolFriendlyName $using:StoragePoolName -FriendlyName $using:CSVFriendlyname -StorageTierFriendlyNames NestedMirror -StorageTierSizes $using:CSVSize -ProvisioningType Thin | Enable-DedupVolume -UsageType HyperV 

}



############################################################Set Net-Intent on Node01########################################################
Invoke-Command -ComputerName $Node01 {

#North-South Net-Intents
Add-NetIntent -ClusterName $using:ClusterName -AdapterName "LOM Port 3", "LOM Port 4" -Name HCI -Compute -Management  

#Storage NetIntent
Add-NetIntent -ClusterName $using:ClusterName -AdapterName "LOM1 Port 1", "LOM1 Port 2"  -Name SMB -Storage
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
#>

#Enable CAU and update to latest 21H2 bits...
$CAURoleName="ASHCICL-CAU"
Add-CauClusterRole -ClusterName $ClusterName -MaxFailedNodes 0 -RequireAllNodesOnline -EnableFirewallRules -VirtualComputerObjectName $CAURoleName -Force -CauPluginName Microsoft.WindowsUpdatePlugin -MaxRetriesPerNode 3 -CauPluginArguments @{ 'IncludeRecommendedUpdates' = 'False' } -StartDate "3/2/2017 3:00:00 AM" -DaysOfWeek 4 -WeeksOfMonth @(3) -verbose
#Invoke-CauScan -ClusterName GBLRHSHCICLUS -CauPluginName "Microsoft.RollingUpgradePlugin" -CauPluginArguments @{'WuConnected'='true';} -Verbose | fl *
Invoke-CauRun -ClusterName $ClusterName -CauPluginName "Microsoft.RollingUpgradePlugin" -CauPluginArguments @{'WuConnected'='true';} -Verbose -EnableFirewallRules -Force



#Set Cloud Witness
Set-ClusterQuorum -Cluster $ClusterName -Credential $AADCred -CloudWitness -AccountName hciwitnessmcd  -AccessKey "lj7LGQrmkyDoMH2AnHXQjp8EI+gWMPsKDYmMBv1mL7Ldo0cwz+aYIoDA8fO3hJoSyY/fUksiOWlZ/8Heme1XGw=="


#Register Cluster with Azure
Invoke-Command -ComputerName $Node01 {
    Connect-AzAccount -Credential $using:AADCred
    $armtoken = Get-AzAccessToken
    $graphtoken = Get-AzAccessToken -ResourceTypeName AadGraph
    Register-AzStackHCI -SubscriptionId $using:AzureSubID -ComputerName $using:Node01 -AccountId $using:AADAccount -ArmAccessToken $armtoken.Token -GraphAccessToken $graphtoken.Token -EnableAzureArcServer -Credential $using:ADCred 
}
############################################################################################################################################
