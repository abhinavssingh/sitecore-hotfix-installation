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
$xdbPrcTaskDBUserNameParam = "-setParam:name=`"XDB Processing Tasks DB User Name`",value=`"notUsed`""
$xdbPrcTaskDBUPwdParam = "-setParam:name=`"XDB Processing Tasks DB Password`",value=`"notUsed`""
$xdbPrcTaskAdminParam = "-setParam:name=`"XDB Processing Tasks Admin Connection String`",value=`"notUsed`""
$masterParam = "-setParam:name=`"Master Connection String`",value=`"notUsed`""
$coreParam = "-setParam:name=`"Core Connection String`",value=`"notUsed`""
$securityParam = "-setParam:name=`"Security Connection String`",value=`"notUsed`""
$reportingParam = "-setParam:name=`"Reporting Connection String`",value=`"notUsed`""
$xdbPrcPoolParam = "-setParam:name=`"XDB Processing Pools Connection String`",value=`"notUsed`""
$xdbPrcTaskParam = "-setParam:name=`"XDB Processing Tasks Connection String`",value=`"notUsed`""
$xdbRefDataParam = "-setParam:name=`"XDB Reference Data Connection String`",value=`"notUsed`""
$repServiceApiKeyParam = "-setParam:name=`"Reporting Service Api Key`",value=`"notUsed`""
$applicationInsightsParam = "-setParam:name=`"Application Insights Instrumentation Key`",value=`"notUsed`""
$applicationInsightRoleParam = "-setParam:name=`"Application Insights Role`",value=`"notUsed`""
$sitecoreCountersParam = "-setParam:name=`"Store Sitecore Counters In Application Insights`",value=`"notUsed`""
$aiParam = "-setParam:name=`"Use Application Insights`",value=`"notUsed`""
$xconnectParam = "-setParam:name=`"XConnect Collection`",value=`"notUsed`""
$xconnectCollectionCertiParam = "-setParam:name=`"XConnect Collection Certificate`",value=`"notUsed`""
$allowInavalidClientCertiParam = "-setParam:name=`"Allow Invalid Client Certificates`",value=`"notUsed`""
$licenseParam = "-setParam:name=`"License Xml`",value=`"notUsed`""
$securityClientIPParam = "-setParam:name=`"IP Security Client IP`",value=`"notUsed`""
$securityClientIPMaskParam = "-setParam:name=`"IP Security Client IP Mask`",value=`"notUsed`""
$doNotDeleteRule = "-enableRule:DoNotDeleteRule"
$appOfflineRule = "-enableRule:AppOffline"
$retryAttemptsParam = "-retryAttempts:$RetryAttempts"
$retryIntervalParam = "-retryInterval:$RetryInterval"
$verboseParam = "-verbose"
Invoke-Expression "& '$MsDeployPath' --% $verb $source $dest $iisWebAppParam $xdbPrcTaskDBUserNameParam $xdbPrcTaskDBUPwdParam $xdbPrcTaskAdminParam $masterParam $coreParam $securityParam $reportingParam $xdbPrcPoolParam $xdbPrcTaskParam $xdbRefDataParam $repServiceApiKeyParam $applicationInsightsParam $applicationInsightRoleParam $sitecoreCountersParam $aiParam $xconnectParam $xconnectCollectionCertiParam $allowInavalidClientCertiParam $licenseParam $securityClientIPParam $securityClientIPMaskParam $doNotDeleteRule $appOfflineRule $retryAttemptsParam $retryIntervalParam $verboseParam"

Write-Host "Uploading configuration..." -ForegroundColor Green
Get-ChildItem $configurationPath -File -Recurse | ForEach-Object {
    $targetWebsiteFile = $_.FullName.Replace("$configurationPath\", "").Replace("\", "/")
    UploadWebsiteFile $targetWebsiteFile $_.FullName
}