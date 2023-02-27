Connect-AzAccount -Identity -Environment "AzureCloud" | out-null

filter Convert-DateTimeFormat
    {
        param($OutputFormat='yyyy-MM-dd HH:mm:ss fff')
        try 
            {
                ([DateTime]$_).ToString($OutputFormat)
            } 
        catch 
            {
            }
    }

############################## only this value needs to differ between runbooks
$tenantName = ("tenantName")
##############################

$today = (Get-Date -Hour 0 -Minute -0 -Second 0).Date
$yesterday = ($today).AddDays(-1) 
$startDate = $yesterday | Convert-DateTimeFormat -OutputFormat 'yyyy-MM-dd'
$endDate = $today | Convert-DateTimeFormat -OutputFormat 'yyyy-MM-dd'
$tenantSecret = ("tenantid-",$tenantName -join "")
$applicationSecret = ("applicationid-",$tenantName -join "")
$passwordSecret = ("password-",$tenantName -join "")
$storageTenantSecret = ("storage-tenant")
$storageSubscriptionSecret = ("storage-subscriptionid")
$storageAccountSecret = ("storage-account")
$accountKeySecret = ("storage-key")
$keyVault = ("keyVault")
$containerName = ("exports")

$tenantValue = (Get-AzKeyVaultSecret -Name $tenantSecret -VaultName $keyVault).SecretValue
$applicationValue = (Get-AzKeyVaultSecret -Name $applicationSecret -VaultName $keyVault).SecretValue
$passwordValue = (Get-AzKeyVaultSecret -Name $passwordSecret -VaultName $keyVault).SecretValue
$storageAccountValue = (Get-AzKeyVaultSecret -Name $storageAccountSecret -VaultName $keyVault).SecretValue
$accountKeyValue = (Get-AzKeyVaultSecret -Name $accountKeySecret -VaultName $keyVault).SecretValue
#$storageTenantValue = (Get-AzKeyVaultSecret -Name $storageTenantSecret -VaultName $keyVault).SecretValue
#$storageSubscriptionValue = (Get-AzKeyVaultSecret -Name $storageSubscriptionSecret -VaultName $keyVault).SecretValue

$tenantId = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tenantValue))
$applicationid = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($applicationValue))
$password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordValue))
$password = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $applicationId, $password)
$storageAccount = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($storageAccountValue))
$accountKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($accountKeyValue))

Connect-AzAccount `
	-ServicePrincipal `
	-TenantId $tenantId `
	-Credential $credential | out-null

$subscriptionList = [System.Collections.ArrayList](Get-AzSubscription -TenantId $tenantId | Where-Object -Property State -eq "Enabled").SubscriptionId

foreach($subscriptionid in $subscriptionList)
	{
		Write-Host ("SubscriptionId: ", $subscriptionId -join "")

		Set-AzContext -SubscriptionId $subscriptionId | out-null

		$token = (Get-AzAccessToken)
		$token = $token.Token

		$uri = ("https://management.azure.com/subscriptions/",$subscriptionId,"/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=2022-05-01" -join "")
		$authentication = ("Bearer ",$token -join "")

		$headers = @{
			authorization = "Bearer $token"
			content = "application/json"
		}
		
		$timePeriod = @{
			start = $startDate
			end = $endDate
		}
		
		$body = @{
			metric = "ActualCost"
			timePeriod = $timePeriod
		} | ConvertTo-Json
		
		$requestReport = ( `
		Invoke-WebRequest `
			-Method "POST" `
			-Headers $headers `
			-Body $body `
			-Uri $uri `
			-UseBasicParsing 
		)		

		if($requestReport)
		{
		
			Start-Sleep `
				-Seconds 10
			
			$reportLocation = ($requestReport.Headers.Location)
			
			Write-Host ("Report Location: ", $reportLocation -join "")
			
			$reportResult = ( `
			Invoke-WebRequest `
				-Method "GET" `
				-Uri $reportLocation `
				-Headers $headers `
				-UseBasicParsing `
			)
			
			if($reportResult)
			{
				
				Start-Sleep `
					-Seconds 10
				
				$csvData = ($reportResult.Content | ConvertFrom-Json)
				
				$byteCount = ($csvData.manifest.byteCount)
				$status = ($csvData.status)
				$sourceFile = ($csvData.manifest.blobs.blobLink)
				
				Write-Host ("Source File: ", $sourceFile -join "")
				Write-Host ("Status: ", $status -join "")
				Write-Host ("Byte Count: ",  $byteCount -join "")
				
				if($status -eq "Completed")
				{
		
					$blobName = ($tenantName,"/",$tenantName,"_",$subscriptionId,"_",$startDate,"_",$endDate,"_","billingSummary.csv" -join "")
					$blobUploadURL = ("https://",$storageAccount,".blob.core.windows.net/",$containerName,"/",$blobName," HTTP/1.1" -join "")
					$context = New-AzStorageContext -StorageAccountName $storageAccount -StorageAccountKey $accountKey
					$sasExpiry = (Get-Date).AddHours(1).ToUniversalTime()
					$sasToken =  New-AzStorageContainerSASToken -Context $context -Container $containerName -Permission "w" -ExpiryTime $sasExpiry
					$sasUrl = "https://$storageAccount.blob.core.windows.net/$containerName/$blobName$sasToken"
		
					$headers = @{
						"x-ms-blob-type" = "BlockBlob"
						"x-ms-copy-source" = "$sourceFile"
					}
					
					Invoke-RestMethod `
						-Method "PUT" `
						-Uri $sasUrl `
						-Headers $headers
				}

				Clear-Variable csvData
				Clear-Variable byteCount
				Clear-Variable status
				Clear-Variable sourceFile
				Clear-Variable reportResult
				Clear-Variable requestReport
				Clear-Variable reportLocation
			}
		}
	}
