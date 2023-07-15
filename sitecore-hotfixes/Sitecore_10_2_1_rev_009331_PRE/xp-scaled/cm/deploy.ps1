[CmdletBinding(DefaultParameterSetName = "no-arguments")]
param(
    [Parameter(HelpMessage = "Name of the resource group in Azure to target.")]
    [string]$ResourceGroupName,

    [Parameter(HelpMessage = "Name of the web app in Azure to target.")]
    [string]$WebAppName,

    [Parameter(HelpMessage = "Path to the WDP to deploy to the target.")]
    [string]$WdpPackagePath,

    [Parameter(HelpMessage = "Path to MSDeploy.")]
    [string]$MsDeployPath = "C:\Program Files\IIS\Microsoft Web Deploy V3\msdeploy.exe",

    [Parameter(HelpMessage = "Skips Azure Login when True.")]
    [switch]$SkipAzureLogin = $True,

    [Parameter(HelpMessage = "Amount of retry attempts. 6 by default which with default retryinterval would come down to 1 minute.")]
    [int]$RetryAttempts = 6,

    [Parameter(HelpMessage = "Amount of time to wait between retries in milliseconds. 10000 by default which is 10 seconds which adds up to 1 minute with default retry attempts.")]
    [int]$RetryInterval = 10000
)

Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function PreparePath($path) {
    if(-Not (Test-Path $path)) {
        $result = New-Item -Path $path -Type Directory -Force
    } else {
        $result = Resolve-Path $path
    }

    return $result
}

function UnzipFolder($zipfile, $folder, $dst) {
    [IO.Compression.ZipFile]::OpenRead($zipfile).Entries | Where-Object {
        ($_.FullName -like "$folder/*") -and ($_.Length -gt 0)
    } | ForEach-Object {
        $parent = Split-Path ($_.FullName -replace $folder, '')
        $parent = PreparePath (Join-Path $dst $parent)
        $file = Join-Path $parent $_.Name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($_, $file, $true)
    }
}

function DownloadWebsiteFile($filePath, $downloadFolderName) {
    $basePath = Split-Path ".\$downloadFolderName\$filePath"
    $fileName = Split-Path $filePath -Leaf
    if(-Not (Test-Path ".\$downloadFolderName\$filePath")) {
        New-Item -Path $basePath -Type Directory -Force
    }
    $outFilePath = Join-Path (Resolve-Path "$basePath") $fileName
    Invoke-WebRequest -Uri "https://$WebAppName.scm.azurewebsites.net/api/vfs/site/wwwroot/$filePath" -Headers @{"Authorization"=("Basic {0}" -f $base64AuthInfo)} -Method GET -OutFile $outFilePath
}

function UploadWebsiteFile($filePath, $uploadFilePath) {
    Invoke-WebRequest -Uri "https://$WebAppName.scm.azurewebsites.net/api/vfs/site/wwwroot/$filePath" -Headers @{"Authorization"=("Basic {0}" -f $base64AuthInfo);"If-Match"="*"} -Method PUT -InFile $uploadFilePath
}

function ApplyTransform($filePath, $xdtFilePath) {
    Write-Verbose "Applying XDT transformation '$xdtFilePath' on '$filePath'..."

    $target = New-Object Microsoft.Web.XmlTransform.XmlTransformableDocument;
    $target.PreserveWhitespace = $true
    $target.Load($filePath);
    
    $transformation = New-Object Microsoft.Web.XmlTransform.XmlTransformation($xdtFilePath);
    
    if ($transformation.Apply($target) -eq $false)
    {
        throw "XDT transformation failed."
    }
    
    $target.Save($filePath);
}

if(-Not (Test-Path $MsDeployPath)) {
    Write-Host "MS Deploy was not found at `"$MsDeployPath`"!" -ForegroundColor Red
    return
}

if(-Not $SkipAzureLogin) {
    Write-Host "Logging into Azure..." -ForegroundColor Green
    & az login
}

Write-Host "Fetching Publish Profile..." -ForegroundColor Green
$publishProfile = az webapp deployment list-publishing-profiles --resource-group $ResourceGroupName --name $WebAppName --query "[?publishMethod=='MSDeploy']" | ConvertFrom-Json
$userName = $publishProfile.userName
$password = $publishProfile.userPWD
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $userName, $password)))

Write-Host "Preparing configuration..." -ForegroundColor Green
$xdtsPath = (PreparePath ".\xdts")
UnzipFolder $WdpPackagePath "Content/Website/App_Data/Transforms/xdts" $xdtsPath
Get-ChildItem $xdtsPath -File -Include "*.xdt" -Recurse | ForEach-Object {
    $targetWebsiteFile = $_.FullName.Replace("$xdtsPath\", "").Replace("\", "/").Replace(".xdt", "")
    DownloadWebsiteFile $targetWebsiteFile "Configuration"
}
$configurationPath = (PreparePath ".\Configuration")
$currentDateTime = (Get-Date).ToString("dd-MM-yyyy-hh-mm-ss")
$backupPath = (PreparePath ".\Backup-$currentDateTime")
robocopy $configurationPath $backupPath /s

Write-Host "Preparing transformations..." -ForegroundColor Green
$nupkgPath = Join-Path (Resolve-Path ".") "microsoft.web.xdt.3.1.0.nupkg"
$xdtDllBinPath = PreparePath ".\bin"
Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.Xdt/3.1.0" -OutFile $nupkgPath
UnzipFolder $nupkgPath "lib/netstandard2.0" $xdtDllBinPath
Add-Type -Path (Resolve-Path ".\bin\Microsoft.Web.XmlTransform.dll")

Write-Host "Running transformations..." -ForegroundColor Green
Get-ChildItem $xdtsPath -File -Include "*.xdt" -Recurse | ForEach-Object {
    $targetFilePath = $_.FullName.Replace($xdtsPath, $configurationPath).Replace(".xdt", "")
    if (-not(Test-Path $targetFilePath -PathType Leaf)) {
        Write-Verbose "No matching file '$targetFilePath' for transformation '$($_.FullName)'. Skipping..."
    } else {
        ApplyTransform $targetFilePath $_.FullName
    }
}

Write-Host "Starting MSDeploy..." -ForegroundColor Green
$verb = "-verb:sync"
$source = "-source:package=`"$WdpPackagePath`""
$dest = "-dest:auto,ComputerName=`"https://$WebAppName.scm.azurewebsites.net/msdeploy.axd?site=$WebAppName`",UserName=`"$userName`",Password=`"$password`",AuthType=`"Basic`""
$iisWebAppParam = "-setParam:name=`"Application Path`",value=`"$WebAppName`""
$coreAdminParam = "-setParam:name=`"Core Admin Connection String`",value=`"notUsed`""
$masterAdminParam = "-setParam:name=`"Master Admin Connection String`",value=`"notUsed`""
$adminPasswordParam = "-setParam:name=`"Sitecore Admin New Password`",value=`"notUsed`""
$coreDbUserNameParam = "-setParam:name=`"Core DB User Name`",value=`"notUsed`""
$coreDbUserPasswordParam = "-setParam:name=`"Core DB Password`",value=`"notUsed`""
$securityDbUserNameParam = "-setParam:name=`"Security DB User Name`",value=`"notUsed`""
$securityDbUserPasswordParam = "-setParam:name=`"Security DB Password`",value=`"notUsed`""
$masterDbUserNameParam = "-setParam:name=`"Master DB User Name`",value=`"notUsed`""
$masterDbUserPasswordParam = "-setParam:name=`"Master DB Password`",value=`"notUsed`""
$webDbUserNameParam = "-setParam:name=`"Web DB User Name`",value=`"notUsed`""
$webDbUserPasswordParam = "-setParam:name=`"Web DB Password`",value=`"notUsed`""
$expFormDbUserNameParam = "-setParam:name=`"Experience Forms DB User Name`",value=`"notUsed`""
$expFormDbUserPasswordParam = "-setParam:name=`"Experience Forms DB Password`",value=`"notUsed`""
$exmMasterDbUserNameParam = "-setParam:name=`"EXM Master DB User Name`",value=`"notUsed`""
$exmMasterDbUserPasswordParam = "-setParam:name=`"EXM Master DB Password`",value=`"notUsed`""
$securityAdminParam = "-setParam:name=`"Security Admin Connection String`",value=`"notUsed`""
$webAdminParam = "-setParam:name=`"Web Admin Connection String`",value=`"notUsed`""
$expFormsAdminParam = "-setParam:name=`"Experience Forms Admin Connection String`",value=`"notUsed`""
$exmMasterAdminParam = "-setParam:name=`"EXM Master Admin Connection String`",value=`"notUsed`""
$processingUrlParam = "-setParam:name=`"Processing Service Url`",value=`"notUsed`""
$reportingApiKeyParam = "-setParam:name=`"Reporting Service Api Key`",value=`"notUsed`""
$masterParam = "-setParam:name=`"Master Connection String`",value=`"notUsed`""
$coreParam = "-setParam:name=`"Core Connection String`",value=`"notUsed`""
$securityParam = "-setParam:name=`"Security Connection String`",value=`"notUsed`""
$webParam = "-setParam:name=`"Web Connection String`",value=`"notUsed`""
$xdbRefDataParam = "-setParam:name=`"XDB Reference Data Connection String`",value=`"notUsed`""
$expFormsParam = "-setParam:name=`"Experience Forms Connection String`",value=`"notUsed`""
$exmMasterParam = "-setParam:name=`"EXM Master Connection String`",value=`"notUsed`""
$reportingParam = "-setParam:name=`"Reporting Connection String`",value=`"notUsed`""
$searchParam = "-setParam:name=`"Search Provider`",value=`"notUsed`""
$solrParam = "-setParam:name=`"SOLR Connection String`",value=`"notUsed`""
$messagingParam = "-setParam:name=`"Messaging Connection String`",value=`"notUsed`""
$applicationInsightsParam = "-setParam:name=`"Application Insights Instrumentation Key`",value=`"notUsed`""
$applicationInsightRoleParam = "-setParam:name=`"Application Insights Role`",value=`"notUsed`""
$sitecoreCountersParam = "-setParam:name=`"Store Sitecore Counters In Application Insights`",value=`"notUsed`""
$aiParam = "-setParam:name=`"Use Application Insights`",value=`"notUsed`""
$xconnectParam = "-setParam:name=`"XConnect Collection`",value=`"notUsed`""
$xconnectSearchParam = "-setParam:name=`"XConnect Search`",value=`"notUsed`""
$xdbRefDataClientParam = "-setParam:name=`"XDB Reference Data Client`",value=`"notUsed`""
$xdbMAReportingClientParam = "-setParam:name=`"XDB MA Reporting Client`",value=`"notUsed`""
$xdbMAOpsClientParam = "-setParam:name=`"XDB MA Ops Client`",value=`"notUsed`""
$cortexReportingClientParam = "-setParam:name=`"Cortex Reporting Client`",value=`"notUsed`""
$cortexProcessingEngineParam = "-setParam:name=`"Cortex Processing Engine`",value=`"notUsed`""
$xcCollectionCertiParam = "-setParam:name=`"XConnect Collection Certificate`",value=`"notUsed`""
$xcSearchCertiParam = "-setParam:name=`"XConnect Search Certificate`",value=`"notUsed`""
$xdbRefdataClientCertiParam = "-setParam:name=`"XDB Reference Data Client Certificate`",value=`"notUsed`""
$xdbMAReportingClientCertiParam = "-setParam:name=`"XDB MA Reporting Client Certificate`",value=`"notUsed`""
$xdbMAOPsClientCertiParam = "-setParam:name=`"XDB MA Ops Client Certificate`",value=`"notUsed`""
$cortexReportingClientCertiParam = "-setParam:name=`"Cortex Reporting Client Certificate`",value=`"notUsed`""
$cortexPrcEngineCertiParam = "-setParam:name=`"Cortex Processing Engine Client Certificate`",value=`"notUsed`""
$allowInavalidClientCertiParam = "-setParam:name=`"Allow Invalid Client Certificates`",value=`"notUsed`""
$licenseParam = "-setParam:name=`"License Xml`",value=`"notUsed`""
$securityClientIPParam = "-setParam:name=`"IP Security Client IP`",value=`"notUsed`""
$securityClientIPMaskParam = "-setParam:name=`"IP Security Client IP Mask`",value=`"notUsed`""
$exmCryptographicKeyParam = "-setParam:name=`"EXM Cryptographic Key`",value=`"notUsed`""
$exmAuthenticationKeyParam = "-setParam:name=`"EXM Authentication Key`",value=`"notUsed`""
$exmEDSParam = "-setParam:name=`"EXM EDS Provider`",value=`"notUsed`""
$telerikEncryptionKeyParam = "-setParam:name=`"Telerik Encryption Key`",value=`"notUsed`""
$siSecretParam = "-setParam:name=`"Sitecore Identity Secret`",value=`"notUsed`""
$siAuthorityParam = "-setParam:name=`"Sitecore Identity Authority`",value=`"notUsed`""
$doNotDeleteRule = "-enableRule:DoNotDeleteRule"
$appOfflineRule = "-enableRule:AppOffline"
$retryAttemptsParam = "-retryAttempts:$RetryAttempts"
$retryIntervalParam = "-retryInterval:$RetryInterval"
$verboseParam = "-verbose"
Invoke-Expression "& '$MsDeployPath' --% $verb $source $dest $iisWebAppParam $coreAdminParam $masterAdminParam $adminPasswordParam $coreDbUserNameParam $coreDbUserPasswordParam $securityDbUserNameParam $securityDbUserPasswordParam $masterDbUserNameParam $masterDbUserPasswordParam $webDbUserNameParam $webDbUserPasswordParam $expFormDbUserNameParam $expFormDbUserPasswordParam $exmMasterDbUserNameParam $exmMasterDbUserPasswordParam $securityAdminParam $webAdminParam $expFormsAdminParam $exmMasterAdminParam $processingUrlParam $reportingApiKeyParam $masterParam $coreParam $securityParam $webParam $xdbRefDataParam $expFormsParam $exmMasterParam $reportingParam $searchParam $solrParam $messagingParam $applicationInsightsParam $applicationInsightRoleParam $sitecoreCountersParam $aiParam $xconnectParam $xconnectSearchParam $xdbRefDataClientParam $xdbMAReportingClientParam $xdbMAOpsClientParam $cortexReportingClientParam $cortexProcessingEngineParam $xcCollectionCertiParam $xcSearchCertiParam $xdbRefdataClientCertiParam $xdbMAReportingClientCertiParam $xdbMAOPsClientCertiParam $cortexReportingClientCertiParam $cortexPrcEngineCertiParam $allowInavalidClientCertiParam $licenseParam $securityClientIPParam $securityClientIPMaskParam $exmCryptographicKeyParam $exmAuthenticationKeyParam $exmEDSParam $telerikEncryptionKeyParam $siSecretParam $siAuthorityParam $doNotDeleteRule $appOfflineRule $retryAttemptsParam $retryIntervalParam $verboseParam"

Write-Host "Uploading configuration..." -ForegroundColor Green
Get-ChildItem $configurationPath -File -Recurse | ForEach-Object {
    $targetWebsiteFile = $_.FullName.Replace("$configurationPath\", "").Replace("\", "/")
    UploadWebsiteFile $targetWebsiteFile $_.FullName
}
