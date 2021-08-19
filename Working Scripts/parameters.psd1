#Set Name of Node01
Node01 = "gblrhshci01"

#Set Name of Node02
Node02 = "gblrhshci02"

#Set IP for MGMT Node1 Nic
node01_MgmtIP="192.168.0.110"

#Set IP for MGMT Node2 Nic
node02_MgmtIP="192.168.0.111"

#Set Default GW IP
GWIP = "192.168.0.1"

#Set IP of AD DNS Server
DNSIP = "172.16.100.20"

#Set Server List 
ServerList = $Node01, $Node02

#Set Cluster Name and Cluster IP
ClusterName = "mcdhcicl"
ClusterIP = "192.168.0.115"

#Set StoragePool Name
StoragePoolName= "ASHCI Storage Pool 1"

#Set First Cluster Shared Volume Friendly Info
CSVFriendlyname="Volume01-Thin"
CSVSize=5GB

#Set name of AD Domain
ADDomain = "mcd.local"

#Set AD Domain Cred
AzDJoin = Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "DomainJoinerSecret"
ADcred = [pscredential]::new("mcd\djoiner",$AZDJoin.SecretValue)
#$ADpassword = ConvertTo-SecureString "" -AsPlainText -Force
#$ADCred = New-Object System.Management.Automation.PSCredential ("mcd\djoiner", $ADpassword)

#Set Cred for AAD tenant and subscription
$AADAccount = "azstackadmin@azurestackdemo1.onmicrosoft.com"
$AADAdmin=Get-AzKeyVaultSecret -VaultName 'MCD-CNUS-KV' -Name "AADAdmin"
$AADCred = [pscredential]::new("azstackadmin@azurestackdemo1.onmicrosoft.com",$AADAdmin.SecretValue)
$AzureSubID = "0c6c3a0d-0866-4e68-939d-ef81ca6f802e"