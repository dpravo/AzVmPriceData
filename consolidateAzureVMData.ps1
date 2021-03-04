# auth details
$tenantId = "<your tenant id>"
$subscriptionid = "<your subscription id>"
$clientId = "<app registration client id>"
$clientSecret = "<app registration secret>"
$resource = "https://management.azure.com/"
$RequestAccessTokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/token"
$body = "grant_type=client_credentials&client_id=$clientId&client_secret=$clientSecret&resource=$resource"

# pricesheet api page size
$pricesheetPageSize = 10000

# local data export settings (dont set these to true if running as a runbook)
$savePriceSheetsLocally = $true
$priceSheetsLocalPath = "c:\temp\pricesheet_data.json"
$saveSkusLocally = $true
$skusLocalPath = "c:\temp\sku_data.json"
$saveConsolidatedDataLocally = $true
$consolidatedDataLocalPath = "C:\temp\az_consolidated_data.json"

# this is if you want to save final consolidated dataset to Azure storage account
$saveConsoldiatedDataToAzStorageAccount = $false
$azStorageAccountName = "<your storae account name>"
$azStorageAccountContainerName = "<storage account container name>"
$azStorageAccountFilename = "az_consolidated_data.json"
$azStorageAccountSASToken = "<storage account sas token>"

# hardcoded mapping of required locations
$dictLocation = @{ 
    "US East" = "eastus";
    "US West" = "westus";
    "IN South" = "SouthIndia";
    "AP Southeast" = "southeastasia";
    "EU North" = "northeurope"
}

# get the auth token
write-output "* Authenticating with Azure AD.."
$Token = Invoke-RestMethod -Method Post -Uri $RequestAccessTokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'

# pull the pricesheet from the consumption api - https://docs.microsoft.com/en-us/rest/api/consumption/pricesheet/get
write-output "* Getting pricesheet data (paginated at $pricesheetPageSize records per page, may take a minute).."
$pricesheetApiUrl= "https://management.azure.com/subscriptions/$subscriptionid/providers/Microsoft.Consumption/pricesheets/default?`$expand=properties/meterDetails&`$top=$pricesheetPageSize&api-version=2019-10-01"
$Headers = @{}
$Headers.Add("Authorization","$($Token.token_type) "+ " " + "$($Token.access_token)")

# array to hold pricesheet data
$allPriceSheets = @()

# variable to help with paging
$hasMoreData = $true

# actually retrieve the data and loop through the pages
while($hasMoreData){

    $priceSheets = Invoke-RestMethod -Method Get -Uri $pricesheetApiUrl -Headers $Headers
    $allPriceSheets += $priceSheets.properties.pricesheets

    if ($priceSheets.properties.nextLink){

        Write-Output "* Another page of data to get.."
        $pricesheetApiUrl = $priceSheets.properties.nextLink 

    }else{

        Write-Output "* Finished retrieving data."
        $hasMoreData = $false

    }

}


# filter pricesheets just down to the virtual machines
Write-Output "* Retrieved $($allPriceSheets.count) pricesheet records, filtering to just virtual machines, no promo, no low priority.."
$vmPriceSheets = $allPriceSheets | Where-Object {$_.meterDetails.meterCategory -eq "Virtual Machines"}
$vmPriceSheets = $vmPriceSheets | Where-Object {$_.meterDetails.meterSubCategory -notlike "*Promo*"}
$vmPriceSheets = $vmPriceSheets | Where-Object {$_.meterDetails.meterName -notlike "*Low Priority"}
Write-Output "* Filtered pricesheet data down to $($vmPriceSheets.count) pricesheet records."

# dump it to filesystem if configured above
if ($savePriceSheetsLocally){ $vmPriceSheets | ConvertTo-Json -Depth 99 | Out-File $priceSheetsLocalPath }

# get the sku details from the compute api - https://docs.microsoft.com/en-us/rest/api/compute/resourceskus/list
write-output "* Getting SKU data (not paginated, make take a minute).."
$skuApiUrl= "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/skus?`$expand=properties/additionalProperties&api-version=2019-04-01"
$Headers = @{}
$Headers.Add("Authorization","$($Token.token_type) "+ " " + "$($Token.access_token)")

# actually get the data
$skus = Invoke-RestMethod -Method Get -Uri $skuApiUrl -Headers $Headers
Write-Output "* Finished retrieving data."

# filter it just to virtualMachines, no promos
Write-Output "* Retrieved $($skus.value.count) sku records, filtering to just Virtual Machines, no promo.."
$vmSkus = $skus.value | Where-Object {$_.resourceType -eq "virtualMachines"}
$vmSkus = $vmSkus | Where-Object {$_.name -notlike "*_Promo"}
Write-Output "* Filtered sku data down to $($vmSkus.count) sku records."

# dump it to filesystem if configured above
if ($saveSkusLocally){ $vmSkus | ConvertTo-Json -depth 99 | Out-File $skusLocalPath }

# function to calculate the monthly price based on the unit of measure and the unit price from the pricesheet
function get-PricePerMonth{
    param([string]$unit_of_measure, [double]$unit_price)
    
    $unit_of_measure = $($unit_of_measure.split(" "))[0]    
    
    # 8760 (hours in 365 days) / unit of measure =  number of units per year
    $cost_per_year = (8760 / $unit_of_measure) * $unit_price
    $price_per_month = $cost_per_year / 12
    
    return [math]::Round($price_per_month,2)
}

# now reconcile pricesheet data with resource data and consolidate into one dataset

# array to hold final list of valid meters
$arrMetersFound = @()

write-host "* About to analyse resources in the following locations.."
$dictLocation

# loop through each location
foreach ($loc in $dictLocation.keys){

    Write-output "* Analysing $meterLocation`.."
    $meterLocation = $loc
    $skuLocation = $dictLocation[$meterLocation]

    write-output "* Filtering pricesheet meters where location is $meterLocation (sku location $skuLocation).."
    $regionallyFilteredMeters = $vmPricesheets | Where-Object {$_.meterDetails.meterLocation -eq $meterLocation } 
    write-output "* Found total of $($regionallyFilteredMeters.count) meters in this region."

    write-output "* Filtering the skus where location is $skuLocation (meter location $meterLocation).."    
    $regionallyFilteredSkus = $vmSkus | Where-Object {$_.locations[0] -eq $skuLocation}
    write-output "* Found total of $($regionallyFilteredSkus.count) skus in this region."
    
    $meterCounter = 0
    
    # loop through each meter
    foreach ($meter in $regionallyFilteredMeters){

        $meterCounter = $meterCounter + 1

        $arrSkus = @()
        
        # replace spaces in metername with underscores to try and match the sku size
        $meterSize = $meter.meterDetails.meterName.replace(" ","_")
        
        write-output "* ($meterCounter of $($regionallyFilteredMeters.count)) Part number $($meter.partnumber) - $($meter.meterDetails.meterName), looking in skus for $meterSize`.."
        
        # is it a basic meter? If so, just get the basic sku.
        if ($meter.meterdetails.subcategory -match "basic"){

            $filteredSkus = $regionallyFilteredSkus | Where-Object {($_.size -eq $meterSize) -and ($_.tier -eq "Basic")}  

        }else{

            $filteredSkus = $regionallyFilteredSkus | Where-Object {($_.size -eq $meterSize) -and ($_.tier -ne "Basic")}  

        }
        
        if (!$filteredSkus){
            
            write-output "* $meterSize not found in skus, checking if there is a slash in the name.."

            if ($meterSize -match "/"){

                write-output "* Found a slash in the name, see if we can split it up and find a match.."

                $splitMeterSize = $meterSize.split("/")

                foreach($meterSize in $splitMeterSize){
                
                    $filteredSkus = $regionallyFilteredSkus | Where-Object {$_.size -eq $meterSize }    

                }

                if (!$filteredSkus){
            
                    write-output "* $meterSize not found in skus after doing the slash analysis."

                }else{
                
                    Write-output "* Matched after slash analysis!"

                }        

            }else{

                write-output "* No slash - $meterSize - couldn't find a match."

            }

        }else{

            Write-output "* Matched on basic size + tier!"

        }

        foreach ($sku in $filteredSkus){
            
                $objTmp = New-Object -TypeName psobject
                $objTmp | Add-Member -MemberType NoteProperty -Name partNumber -Value $meter.partnumber
                $objTmp | Add-Member -MemberType NoteProperty -Name skuSize -Value $sku.size
                $objTmp | Add-Member -MemberType NoteProperty -Name tier -Value $sku.tier
                $objTmp | Add-Member -MemberType NoteProperty -Name unitPrice -Value $meter.unitPrice
                $objTmp | Add-Member -MemberType NoteProperty -Name unitOfMeasure -Value $meter.unitOfMeasure
                $objTmp | Add-Member -MemberType NoteProperty -Name pricePerMonth -Value $(get-pricePerMonth $meter.unitOfMeasure $meter.unitPrice)
                $objTmp | Add-Member -MemberType NoteProperty -Name location -Value $meter.meterDetails.meterLocation
                $objTmp | Add-Member -MemberType NoteProperty -Name subcategory -Value $meter.meterDetails.metersubCategory
                $objTmp | Add-Member -MemberType NoteProperty -Name vCPUs -Value ($sku.capabilities | Where-Object {$_.name -eq "vCPUs"}).value
                $objTmp | Add-Member -MemberType NoteProperty -Name memoryGB -Value ($sku.capabilities | Where-Object {$_.name -eq "MemoryGB"}).value
                $arrSkus += $objTmp
                $arrMetersFound += $objTmp

        }      
        
    }

}
   
if ($saveConsolidatedDataLocally) { $arrMetersFound | ConvertTo-Json -Depth 10 | out-file $consolidatedDataLocalPath }

if ($saveConsoldiatedDataToAzStorageAccount){
    
    # save a copy of consolidated data to a temp dir so we can then upload it
    $systemTempPath = [System.IO.Path]::GetTempPath()
	$fileTempPath = $systemTempPath + $azStorageAccountFilename
    $arrMetersFound | ConvertTo-Json -Depth 10 | out-file $fileTempPath    
    # storage account url for upload
    $storageAccountURL = "https://$azStorageAccountName`.blob.core.windows.net/$azStorageAccountContainerName/$azStorageAccountFilename$azStorageAccountSASToken"
    # required headers
    $headers = @{ 'x-ms-blob-type' = 'BlockBlob' }
    # perform the upload
    Invoke-RestMethod -Uri $storageAccountURL -Method Put -Headers $headers -InFile $consolidatedDataLocalPath

}