[CmdletBinding()]
param(
    [string]$SourceFolder,
    [uri]$ArchiveUrl,
    [string]$InstallerDirectory = $PSScriptRoot,
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'Start-Delo-Setup.cmd'),
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Menu,
    [switch]$Check,
    [switch]$DownloadOnly,
    [switch]$ManualWizard,
    [switch]$Credentials,
    [switch]$ResumeAfterRestart,
    [switch]$CopyPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$instance = 'DELO22LAB'
$owner = 'LAB22'
$database = "${owner}_DB"
$sqlServer = ".\$instance"
$siteName = 'Delo22Lab'
$sitePort = 8765
$siteUrl = "http://127.0.0.1:$sitePort/$owner/"
$deloShortDate = 'dd/MM/yyyy'
$stateRoot = Join-Path $env:LOCALAPPDATA 'Delo22Lab-Setup'
$cache = Join-Path $stateRoot 'Media'
$statusPath = Join-Path $stateRoot 'setup.log'
$appcmd = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
$vendorArchiveHash = '75026D10B3D0DE547AB40560BEB26156D6E7E50E6774EC057E684092F5825E46'
$vendorSource = 'https://disk.yandex.ru/d/4FdxZceXFHLXcw'
$githubArchive = 'https://github.com/NIDJEL/delo-22-setup/releases/download/v0.1.0/2025.05.27.1_Box_22.2.zip'
$vendorManifestHash = '390B78953C1E681CE29795980E64FC117C5BD78D4EC0D7AC4A043E2E88CC5ACE'
$iisFeatures = @(
    'IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementConsole', 'IIS-ASPNET45',
    'IIS-HttpRedirect', 'IIS-WebSockets', 'IIS-WindowsAuthentication',
    'IIS-BasicAuthentication', 'IIS-ManagementScriptingTools', 'IIS-Metabase'
)

$packages = @{
    Rewrite = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_ru-RU.msi'
    Routing = 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi'
    Hosting = 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/5.0.17/dotnet-hosting-5.0.17-win.exe'
    SqlBootstrap = 'https://go.microsoft.com/fwlink/?linkid=866658'
    Net35 = 'https://download.microsoft.com/download/298af580-974e-4001-a07d-bb200d7c5792/DotNet35Setup.exe'
}
$packageNames = @{
    Rewrite = 'rewrite.msi'
    Routing = 'arr.msi'
    Hosting = 'hosting.exe'
    SqlBootstrap = 'sql2019-express.exe'
    Net35 = 'DotNet35Setup.exe'
}

function Write-Step([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $statusPath -Value $line -Encoding UTF8
}

function Test-Hash([string]$Path, [string]$Hash) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
        $actual -eq $Hash
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Assert-Publisher([string]$Path, [string]$Publisher) {
    $module = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    Import-Module -Name $module -ErrorAction Stop
    $sig = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $Publisher) {
        throw ('Не прошла проверка подписи. ' + (Split-Path $Path -Leaf))
    }
}

function Receive-File([uri]$Uri, [string]$Path) {
    if ($Uri.Scheme -ne 'https') { throw 'Для загрузки требуется HTTPS.' }
    $temp = "$Path.partial"
    Write-Step ('Загрузка ' + (Split-Path $Path -Leaf))
    $arguments = @('--fail','--location','--proto','=https','--proto-redir','=https',
        '--retry','3','--retry-delay','2','--connect-timeout','20','--max-time','7200',
        '--progress-bar','--output',$temp)
    $partial = Get-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    if ($partial -and $partial.Length -gt 0) {
        & curl.exe @arguments --continue-at - $Uri.AbsoluteUri
        if ($LASTEXITCODE -in 22, 33, 36) { & curl.exe @arguments $Uri.AbsoluteUri }
    } else {
        & curl.exe @arguments $Uri.AbsoluteUri
    }
    if ($LASTEXITCODE -ne 0) { throw ('Не удалось скачать ' + (Split-Path $Path -Leaf)) }
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-MicrosoftPackage([string]$Key) {
    $path = Join-Path $cache $packageNames[$Key]
    if (Test-Path -LiteralPath $path) {
        try {
            Assert-Publisher $path 'CN=Microsoft Corporation'
            return $path
        } catch {
            Write-Step ('Скачиваю пакет заново после ошибки проверки подписи ' + $packageNames[$Key])
        }
    }
    Receive-File $packages[$Key] $path
    Assert-Publisher $path 'CN=Microsoft Corporation'
    $path
}

function Find-VendorRoot([string]$Folder) {
    if (Test-Path -LiteralPath (Join-Path $Folder 'DBCreate\dbmaster.exe')) { return $Folder }
    $matches = @(Get-ChildItem -LiteralPath $Folder -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'DBCreate\dbmaster.exe')
    })
    if ($matches.Count -ne 1) { throw 'Не найдена распакованная сборка ДЕЛО от 27.05.2025.' }
    $matches[0].FullName
}

function Get-VendorManifest {
    $manifest = Join-Path $PSScriptRoot 'VendorFiles.json'
    if (!(Test-Hash $manifest $vendorManifestHash)) { throw 'Не совпала контрольная сумма списка файлов.' }
    Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Expand-VendorFiles([string]$ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open(
        $ArchivePath, [IO.Compression.ZipArchiveMode]::Read, [Text.Encoding]::GetEncoding(866)
    )
    try {
        $entries = @{}
        foreach ($entry in $archive.Entries) { $entries[$entry.FullName.Replace('/', '\')] = $entry }
        $prefix = [IO.Path]::GetFileNameWithoutExtension($ArchivePath) + '\'
        foreach ($file in (Get-VendorManifest)) {
            $entry = $entries[$prefix + $file.Path]
            if (!$entry) { throw "В архиве отсутствует файл $($file.Path)." }
            $target = Join-Path $Destination $file.Path
            if (Test-Hash $target $file.Sha256) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}

function Get-VendorRoot {
    if ($SourceFolder) { return Find-VendorRoot (Resolve-Path -LiteralPath $SourceFolder).Path }
    $archive = Join-Path $cache '2025.05.27.1_Box_22.2.zip'
    $extract = Join-Path $cache 'Delo22-20250527'
    $stamp = Join-Path $extract '.extracted'
    if (!(Test-Path -LiteralPath $stamp)) {
        if (!(Test-Hash $archive $vendorArchiveHash)) {
            if ($ArchiveUrl) {
                Receive-File $ArchiveUrl $archive
            } else {
                try { Receive-File $githubArchive $archive } catch {
                    Write-Step 'Зеркало GitHub недоступно. Использую ссылку ЭОС.'
                }
            }
            if (!$ArchiveUrl -and !(Test-Hash $archive $vendorArchiveHash)) {
                $key = [uri]::EscapeDataString($vendorSource)
                $api = "https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key=$key"
                $download = Invoke-RestMethod -Uri $api -TimeoutSec 30
                $link = [uri]$download.href
                if ($link.Host -notmatch '(^|\.)(disk\.yandex\.ru|yandex\.net)$') {
                    throw 'Яндекс Диск вернул незнакомый адрес.'
                }
                Receive-File $link $archive
            }
        }
        if (!(Test-Hash $archive $vendorArchiveHash)) { throw 'Архив ДЕЛО не прошёл проверку SHA-256.' }
        Write-Step 'Распаковка ДЕЛО 22.2'
        Expand-VendorFiles $archive $extract
        Find-VendorRoot $extract | Out-Null
        New-Item -ItemType File -Path $stamp -Force | Out-Null
    }
    Find-VendorRoot $extract
}

function Assert-VendorFiles([string]$Root) {
    foreach ($file in (Get-VendorManifest)) {
        if (!(Test-Hash (Join-Path $Root $file.Path) $file.Sha256)) {
            throw ('Файл отличается от дистрибутива 27.05.2025. ' + $file.Path)
        }
    }
    Assert-Publisher (Join-Path $Root 'Client\setup.msi') 'ELEKTRONNYE OFISNYE SISTEMY'
    Assert-Publisher (Join-Path $Root 'ServerSetup\setup.msi') 'ELEKTRONNYE OFISNYE SISTEMY'
}

function Start-Installer([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw ('Ошибка установщика ' + (Split-Path $File -Leaf) + ', код ' + $process.ExitCode)
    }
    $process.ExitCode
}

function Get-SetupCredential([string]$Name) {
    $file = Join-Path $stateRoot "$Name.xml"
    if (!(Test-Path -LiteralPath $file)) {
        $bytes = New-Object byte[] 18
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
        $text = 'Delo!9a-' + ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
        ConvertTo-SecureString -String $text -AsPlainText -Force | Export-Clixml -LiteralPath $file
    }
    [PSCredential]::new($Name, (Import-Clixml -LiteralPath $file))
}

function Open-LabSqlConnection([Data.SqlClient.SqlConnection]$Connection) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $Connection.Open()
            return
        } catch {
            $failure = $_.Exception.InnerException
            if ($attempt -eq 3 -or $failure -isnot [Data.SqlClient.SqlException] -or
                $failure.Number -notin -2, 258) { throw }
            Start-Sleep -Seconds 3
        }
    }
}

function Get-SqlScalar([string]$Catalog, [string]$Query) {
    $connection = [Data.SqlClient.SqlConnection]::new("Data Source=lpc:$sqlServer;Initial Catalog=$Catalog;Integrated Security=True;Connect Timeout=40")
    try {
        Open-LabSqlConnection $connection
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.ExecuteScalar()
    } finally { $connection.Dispose() }
}

function Test-DeloDatabase {
    try {
        (Get-SqlScalar $database 'SELECT COUNT(*) FROM sys.tables') -ge 270 -and
            (Get-SqlScalar $database 'SELECT COUNT(*) FROM dbo.USER_CL') -ge 1
    } catch { $false }
}

function Assert-DatabaseLogin([pscredential]$Admin) {
    $password = $Admin.Password.Copy()
    $password.MakeReadOnly()
    $credential = [Data.SqlClient.SqlCredential]::new($Admin.UserName, $password)
    $connection = [Data.SqlClient.SqlConnection]::new(
        "Data Source=lpc:$sqlServer;Initial Catalog=$database;Connect Timeout=40", $credential
    )
    try {
        Open-LabSqlConnection $connection
    } catch {
        throw "Не удалось войти в базу $database как $($Admin.UserName)."
    } finally {
        $connection.Dispose()
        $password.Dispose()
    }
}

function Enable-WindowsFeatureSet([string[]]$Names) {
    $toEnable = @()
    foreach ($name in $Names) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
        if (!$feature) { throw "Компонент Windows $name недоступен в этой системе." }
        if ($feature.State -eq 'EnablePending') { return $true }
        if ($feature.State -ne 'Enabled') { $toEnable += $name }
    }
    if ($toEnable.Count -eq 0) { return $false }
    Write-Step ('Включение компонентов Windows ' + ($toEnable -join ', '))
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $toEnable -All -NoRestart
    [bool]$result.RestartNeeded
}

function Install-Net35 {
    $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    if ($build -lt 28000) {
        if (!(Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3')) {
            Write-Step 'В этом образе Windows компонент NetFx3 недоступен. Продолжаю установку настольного ДЕЛО.'
            return $false
        }
        return (Enable-WindowsFeatureSet 'NetFx3')
    }
    $runtime = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v2.0.50727\mscorwks.dll'
    if (!(Test-Path -LiteralPath $runtime)) {
        $setup = Get-MicrosoftPackage Net35
        Write-Step 'Установка отдельного пакета .NET Framework 3.5 для Windows 11 26H1'
        if ((Start-Installer $setup @('/quiet','/norestart')) -eq 3010) { return $true }
        if (!(Test-Path -LiteralPath $runtime)) { throw 'Не удалось подтвердить установку .NET Framework 3.5.' }
    }
    $false
}

function Get-IisModules {
    $lines = & $appcmd list modules
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось прочитать список модулей IIS.' }
    $lines -join "`n"
}

function Install-IisComponents {
    if (Enable-WindowsFeatureSet $iisFeatures) { return $true }
    if (!(Test-Path -LiteralPath $appcmd)) { throw 'IIS включён, но appcmd.exe недоступен.' }
    foreach ($part in @(@('Rewrite','RewriteModule'), @('Routing','ApplicationRequestRouting'))) {
        if ((Get-IisModules).Contains($part[1])) { continue }
        $file = Get-MicrosoftPackage $part[0]
        Write-Step ('Установка ' + $part[1])
        if ((Start-Installer "$env:SystemRoot\System32\msiexec.exe" @('/i', ('"' + $file + '"'), '/qn', '/norestart')) -eq 3010) {
            return $true
        }
    }
    $stack64 = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.AspNetCore.App\5.0.17'
    $stack32 = Join-Path ${env:ProgramFiles(x86)} 'dotnet\shared\Microsoft.AspNetCore.App\5.0.17'
    if (!(Get-IisModules).Contains('AspNetCoreModuleV2') -or !(Test-Path -LiteralPath $stack64) -or !(Test-Path -LiteralPath $stack32)) {
        $file = Get-MicrosoftPackage Hosting
        Write-Step 'Установка .NET Hosting Bundle 5.0.17'
        if ((Start-Installer $file @('/install', '/quiet', '/norestart')) -eq 3010) { return $true }
    }
    $false
}

function Install-SqlServer([pscredential]$Sa) {
    $name = 'MSSQL$' + $instance
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (!$service) {
        $media = Join-Path $cache 'SQLMedia'
        New-Item -ItemType Directory -Path $media -Force | Out-Null
        $express = @(Get-ChildItem -LiteralPath $media -Filter 'SQLEXPRADV_x64_*.exe' -File)
        if ($express.Count -eq 0) {
            $bootstrap = Get-MicrosoftPackage SqlBootstrap
            Write-Step 'Загрузка SQL Server 2019 Express Advanced'
            $null = Start-Installer $bootstrap @('/ACTION=Download', '/MEDIATYPE=Advanced', ('/MEDIAPATH="' + $media + '"'), '/QUIET')
            $express = @(Get-ChildItem -LiteralPath $media -Filter 'SQLEXPRADV_x64_*.exe' -File)
        }
        if ($express.Count -ne 1) { throw 'Не найден пакет SQL Server 2019 Express Advanced.' }
        Assert-Publisher $express[0].FullName 'CN=Microsoft Corporation'
        $extract = Join-Path $cache 'SQLSetup'
        $setup = Join-Path $extract 'SETUP.EXE'
        if (!(Test-Path -LiteralPath $setup)) {
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            $null = Start-Installer $express[0].FullName @(('/x:"' + $extract + '"'), '/q')
        }
        Assert-Publisher $setup 'CN=Microsoft Corporation'
        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $arguments = @('/Q','/ACTION=Install','/IACCEPTSQLSERVERLICENSETERMS','/FEATURES=SQLENGINE,FULLTEXT',
            "/INSTANCENAME=$instance",'/SQLCOLLATION=Cyrillic_General_CI_AS','/SECURITYMODE=SQL',
            ('/SAPWD=' + $Sa.GetNetworkCredential().Password),('/SQLSYSADMINACCOUNTS="' + $account + '"'),
            '/SQLSVCSTARTUPTYPE=Automatic','/TCPENABLED=0','/NPENABLED=0','/BROWSERSVCSTARTUPTYPE=Disabled',
            '/UpdateEnabled=False','/USEMICROSOFTUPDATE=False')
        Write-Step 'Установка локального SQL Server 2019 Express'
        if ((Start-Installer $setup $arguments) -eq 3010) { return $true }
    } elseif ($service.Status -ne 'Running') { Start-Service -Name $name }
    $version = [string](Get-SqlScalar master "SELECT CONVERT(nvarchar(20), SERVERPROPERTY('ProductVersion'))")
    if (!$version.StartsWith('15.')) { throw "Для этой сборки требуется SQL Server 2019. Обнаружена версия $version." }
    $false
}

function Initialize-LocalSite {
    $path = Join-Path $stateRoot 'LocalSite'
    New-Item -Path $path -ItemType Directory -Force | Out-Null
    $binding = "http/127.0.0.1:${sitePort}:"
    $sites = & $appcmd list site /text:name
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить сайт IIS.' }
    if ($siteName -in $sites) {
        $site = & $appcmd list site $siteName /text:bindings
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить привязку сайта IIS.' }
        $existingPath = & $appcmd list vdir "$siteName/" /text:physicalPath
        if ($LASTEXITCODE -ne 0 -or $site -ne $binding -or $existingPath -ne $path) {
            throw "Сайт $siteName уже принадлежит другой установке."
        }
        return
    }
    $conflicts = Get-NetTCPConnection -LocalPort $sitePort -State Listen -ErrorAction SilentlyContinue
    if ($conflicts) { throw "Локальный порт $sitePort уже занят." }
    $null = & $appcmd add site "/name:$siteName" "/bindings:$binding" "/physicalPath:$path"
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать локальный сайт IIS.' }
}

function Test-WebReady {
    $http = & curl.exe --noproxy '*' --location --max-redirs 6 --connect-timeout 3 --max-time 15 --silent --output NUL --write-out '%{http_code} %{url_effective}' $siteUrl
    $LASTEXITCODE -eq 0 -and $http -match ('^200 ' + [regex]::Escape($siteUrl) + '.*login')
}

function Get-DesktopClientConnection([string]$IniPath) {
    if (!(Test-Path -LiteralPath $IniPath -PathType Leaf)) { return }
    $config = [string](Get-Content -LiteralPath $IniPath -Raw -Encoding Default)
    $section = [regex]::Match($config, '(?ims)^[ \t]*\[Database\][ \t]*\r?\n(?<settings>.*?)(?=^[ \t]*\[|\z)')
    $settings = if ($section.Success) { $section.Groups['settings'].Value } else { $config }
    $server = [regex]::Match($settings, '(?im)^[ \t]*ServerName[ \t]*=[ \t]*([^\r\n]+)').Groups[1].Value.Trim()
    $databaseOwner = [regex]::Match($settings, '(?im)^[ \t]*(?:Owner|DBOwner)[ \t]*=[ \t]*([^\r\n]+)').Groups[1].Value.Trim()
    if ($server -and $databaseOwner) { [pscustomobject]@{ Server = $server; Owner = $databaseOwner } }
}

function Test-ClientReady {
    $root = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo'
    $client = Get-DesktopClientConnection (Join-Path $root 'Office.ini')
    $client -and $client.Server -ieq $sqlServer -and $client.Owner -ieq $owner -and
        (Test-Path -LiteralPath (Join-Path $root 'Bin\base32.exe') -PathType Leaf)
}

function Get-SetupResumeTaskName {
    'Delo22Lab.Setup.Resume.' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Clear-SetupResume {
    $name = Get-SetupResumeTaskName
    if (Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false
    }
    $pending = Join-Path $stateRoot 'pending-restart.txt'
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
}

function Require-Restart {
    if ($Uninstall) {
        Write-Step 'Windows требуется перезагрузка. После неё откройте управление ДЕЛО и снова выберите удаление.'
        exit 3010
    }

    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $launcher = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
    $arguments = @('-Install', '-ResumeAfterRestart')
    if ($SourceFolder) { $arguments += @('-SourceFolder', ('"' + (Resolve-Path -LiteralPath $SourceFolder).Path + '"')) }
    if ($ArchiveUrl) { $arguments += @('-ArchiveUrl', ('"' + $ArchiveUrl.AbsoluteUri + '"')) }
    if ($ManualWizard) { $arguments += '-ManualWizard' }
    if ([IO.Path]::GetExtension($launcher) -ieq '.cmd') {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $PSCommandPath + '"')) + $arguments
        $launcher = Join-Path $PSHOME 'powershell.exe'
    }
    $action = New-ScheduledTaskAction -Execute $launcher -Argument ($arguments -join ' ') -WorkingDirectory $InstallerDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
    Register-ScheduledTask -TaskPath '\' -TaskName (Get-SetupResumeTaskName) -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $stateRoot 'pending-restart.txt') -Value $boot -Encoding ASCII
    } catch {
        Clear-SetupResume
        throw
    }
    Write-Step 'Windows требуется перезагрузка. Установка автоматически продолжится после входа в этот профиль.'
    exit 3010
}

function Install-DesktopClient([string]$Root) {
    if (Test-ClientReady) {
        Write-Step 'Настольный клиент уже установлен.'
        return
    }
    $clientIni = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo\Office.ini'
    $repair = Test-Path -LiteralPath $clientIni
    if ($repair) {
        $client = Get-DesktopClientConnection $clientIni
        if (!$client -or $client.Server -ine $sqlServer -or $client.Owner -ine $owner) {
            throw 'Найден другой клиент ДЕЛО. Его настройки сохранены.'
        }
    }
    $file = Join-Path $Root 'Client\setup.msi'
    $log = Join-Path $stateRoot 'client-msi.log'
    Write-Step 'Установка настольного клиента'
    $arguments = @(
        '/i', ('"' + $file + '"'), '/qn', '/norestart', '/Le', ('"' + $log + '"'),
        'ISSETUPDRIVEN=1', 'DBTYPE=MSS', "DBSERVERNAME=$sqlServer", "DBOWNER=$owner", 'ADDLOCAL=ALL'
    )
    if ($repair) { $arguments += 'REINSTALL=ALL', 'REINSTALLMODE=omus' }
    $code = Start-Installer "$env:SystemRoot\System32\msiexec.exe" $arguments
    if ($code -eq 3010) { Require-Restart }
    if (!(Test-ClientReady)) { throw 'Не удалось подтвердить конфигурацию настольного клиента.' }
}

function Set-DeloDateFormat {
    $current = [DeloDialog]::GetShortDate()
    if ($current -ceq $deloShortDate) { return }
    $backup = Join-Path $stateRoot 'short-date-before.txt'
    Set-Content -LiteralPath $backup -Value $current -NoNewline -Encoding UTF8
    [DeloDialog]::SetShortDate($deloShortDate)
    Write-Step "Короткая дата текущего профиля Windows настроена для настольного ДЕЛО ($deloShortDate)."
}

function Restore-DeloDateFormat {
    $backup = Join-Path $stateRoot 'short-date-before.txt'
    if ((Test-Path -LiteralPath $backup -PathType Leaf) -and [DeloDialog]::GetShortDate() -ceq $deloShortDate) {
        $previous = Get-Content -LiteralPath $backup -Raw -Encoding UTF8
        if ($previous) {
            [DeloDialog]::SetShortDate($previous)
            Write-Step 'Короткая дата текущего профиля Windows восстановлена.'
        }
    }
}

function Get-DesktopProgramsFolder {
    $shortcuts = 'Документы', 'Отчетные формы', 'Подсистема протоколирования',
        'Пользователи', 'Поточное сканирование', 'Справочники'
    foreach ($name in 'CommonPrograms', 'Programs') {
        $folder = Join-Path ([Environment]::GetFolderPath($name)) 'Дело'
        $missing = @($shortcuts | Where-Object {
            !(Test-Path -LiteralPath (Join-Path $folder "$_.lnk") -PathType Leaf)
        })
        if ($missing.Count -eq 0) { return $folder }
    }
    throw 'В меню «Пуск» не удалось найти папку «Дело» со всеми шестью ярлыками.'
}

function Get-AdjacentOutputPath([string]$Name, [scriptblock]$CanReuse) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [IO.Path]::GetExtension($Name)
    for ($index = 1; ; $index++) {
        $filename = if ($index -eq 1) { $Name } else { "$stem ($index)$extension" }
        $path = Join-Path $InstallerDirectory $filename
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (!$item) { return $path }
        if (!$item.PSIsContainer -and !$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            (& $CanReuse $path)) { return $path }
    }
}

function Get-DesktopCredentialText([pscredential]$Admin) {
    $contents = @(
        'Учебная установка ДЕЛО 22.2'
        ''
        "Логин: $($Admin.UserName)"
        "Пароль: $($Admin.GetNetworkCredential().Password)"
        "ДЕЛО-Web: $siteUrl"
    ) -join "`r`n"
    $contents + "`r`n"
}

function Save-DesktopCredentials([pscredential]$Admin) {
    $contents = Get-DesktopCredentialText $Admin
    $credentials = Get-AdjacentOutputPath 'Дело - вход.txt' {
        param($path)
        [IO.File]::ReadAllText($path) -ceq $contents
    }
    if (!(Test-Path -LiteralPath $credentials)) {
        $file = [IO.File]::Open($credentials, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = [IO.StreamWriter]::new($file, [Text.UTF8Encoding]::new($true))
            try { $writer.Write($contents) } finally { $writer.Dispose() }
        } finally { $file.Dispose() }
    }
    Write-Step "Данные входа сохранены в файле $credentials"
    $record = Join-Path $stateRoot 'output-directory.txt'
    $folder = (Resolve-Path -LiteralPath $InstallerDirectory).ProviderPath
    if (!(Test-Path -LiteralPath $record) -or $folder -notin (Get-Content -LiteralPath $record -Encoding UTF8)) {
        Add-Content -LiteralPath $record -Value $folder -Encoding UTF8
    }
    $credentials
}

function Save-AdjacentShortcut([string]$Name, [string]$Target, [string]$Arguments, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = Get-AdjacentOutputPath $Name {
        param($path)
        try {
            $existing = $shell.CreateShortcut($path)
            $existing.TargetPath -ieq $Target -and $existing.Arguments -ceq $Arguments
        } catch { $false }
    }
    if (!(Test-Path -LiteralPath $shortcut)) {
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $Target
        if ($Arguments) { $link.Arguments = $Arguments }
        $link.WorkingDirectory = if (Test-Path -LiteralPath $Target -PathType Container) { $Target } else { Split-Path $Target -Parent }
        $link.Description = $Description
        $link.Save()
    }
    $shortcut
}

function Save-DesktopFiles([string]$ProgramsFolder, [pscredential]$Admin) {
    $null = Save-DesktopCredentials $Admin
    $shortcut = Save-AdjacentShortcut 'Дело.lnk' $ProgramsFolder '' 'Настольные модули ДЕЛО'
    Write-Step "Ярлык на настольные модули сохранён в файле $shortcut"
    if (Test-Path -LiteralPath $InstallerPath -PathType Leaf) {
        $null = Save-AdjacentShortcut 'Дело - управление.lnk' $InstallerPath '-Menu' 'Управление учебной установкой ДЕЛО 22.2'
    }
}

function Use-ExistingDesktopClient([string]$IniPath) {
    $root = Split-Path $IniPath -Parent
    if (!(Test-Path -LiteralPath (Join-Path $root 'Bin\base32.exe') -PathType Leaf)) {
        throw 'Найдена конфигурация ДЕЛО, но исполняемый файл настольного клиента отсутствует.'
    }
    $client = Get-DesktopClientConnection $IniPath
    if (!$client) { throw 'В существующем подключении ДЕЛО отсутствует сервер или владелец базы.' }
    $programs = Get-DesktopProgramsFolder
    $shortcut = Save-AdjacentShortcut 'Дело.lnk' $programs '' 'Настольные модули ДЕЛО'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Write-Step "Используется установленное ДЕЛО. Сервер $($client.Server), владелец базы $($client.Owner)."
    Write-Step "Ярлык на существующие модули сохранён в файле $shortcut"
}

function Show-Preflight {
    if (![Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Нужен Windows x64 на процессоре Intel или AMD.'
    }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.ProductType -ne 1 -or [version]$os.Version -lt [version]'10.0.19045') {
        throw 'Нужен Windows 10 22H2 либо Windows 11.'
    }
    $free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($stateRoot)).AvailableFreeSpace
    if ($free -lt 8GB) { throw 'На диске профиля нужно минимум 8 ГБ свободного места.' }
    if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'В системе не найден curl.exe.' }
    Write-Host "$($os.Caption) | $([math]::Round($free/1GB)) ГБ свободно | $siteUrl"
}

function Invoke-DeloSetup {
    if ($Menu) {
        Write-Host 'ДЕЛО 22.2'
        Write-Host '1. Установить или продолжить'
        Write-Host '2. Удалить ДЕЛО'
        Write-Host '3. Открыть TXT с логином и паролем'
        $choice = ([string](Read-Host 'Введите 1, 2 или 3')).Trim()
        if ($choice -eq '2') { $Uninstall = $true }
        elseif ($choice -eq '3') { $Credentials = $true }
        elseif ($choice -eq '1') { $Install = $true }
        else { return }
    }
    if ($Install -and $Uninstall) { throw 'Выберите одну операцию.' }
    if ($Credentials -or $CopyPassword) {
        $client = Get-DesktopClientConnection (Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo\Office.ini')
        if ($Credentials -and $client -and ($client.Server -ine $sqlServer -or $client.Owner -ine $owner)) {
            $text = Get-ChildItem -LiteralPath $InstallerDirectory -File -Filter 'Дело - вход*.txt' | Where-Object {
                $lines = [IO.File]::ReadAllLines($_.FullName)
                "Логин: $($client.Owner)" -in $lines -and "Сервер БД: $($client.Server)" -in $lines
            } | Select-Object -First 1
            if (!$text) { throw 'Файл с данными входа существующего ДЕЛО рядом с установщиком не найден.' }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"' + $text.FullName + '"')
            return
        }
        $file = Join-Path $stateRoot "$owner.xml"
        if (!(Test-Path -LiteralPath $file)) { throw 'Пароль появится после создания локальной базы.' }
        $credential = [PSCredential]::new($owner, (Import-Clixml -LiteralPath $file))
        if ($Credentials) {
            $path = Save-DesktopCredentials $credential
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"' + $path + '"')
        } else {
            $credential.GetNetworkCredential().Password | Set-Clipboard
            Write-Host "Пароль для $owner скопирован в буфер обмена."
        }
        return
    }

    if ($Check -and !$Uninstall) { Show-Preflight; return }
    if ($DownloadOnly) {
        Show-Preflight
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        foreach ($item in 'Rewrite','Routing','Hosting','SqlBootstrap') { Get-MicrosoftPackage $item | Out-Null }
        Assert-VendorFiles (Get-VendorRoot)
        Write-Step 'Загрузки и контрольные суммы проверены.'
        return
    }

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','RemoteSigned','-File', ('"' + $PSCommandPath + '"'))
        if ($SourceFolder) { $arguments += @('-SourceFolder', ('"' + (Resolve-Path -LiteralPath $SourceFolder).Path + '"')) }
        if ($ArchiveUrl) { $arguments += @('-ArchiveUrl', ('"' + $ArchiveUrl.AbsoluteUri + '"')) }
        if ($InstallerDirectory) { $arguments += @('-InstallerDirectory', ('"' + $InstallerDirectory + '"')) }
        if ($InstallerPath) { $arguments += @('-InstallerPath', ('"' + $InstallerPath + '"')) }
        if ($ManualWizard) { $arguments += '-ManualWizard' }
        if ($ResumeAfterRestart) { $arguments += '-ResumeAfterRestart' }
        if ($Uninstall) { $arguments += '-Uninstall' } else { $arguments += '-Install' }
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $child.ExitCode
    }

    $lock = [Threading.Mutex]::new($false, 'Local\Delo22Lab.Setup')
    $held = $false
    try {
        try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Установщик уже открыт.' }
        if ($Uninstall) {
            . (Join-Path $PSScriptRoot 'Uninstall-Delo.ps1')
            Invoke-DeloUninstall
            return
        }
        if (Test-Path -LiteralPath (Join-Path $stateRoot 'removal.json')) {
            throw 'Удаление ДЕЛО ещё не завершено. Откройте меню и выберите пункт 2.'
        }
        $pending = Join-Path $stateRoot 'pending-restart.txt'
        if (Test-Path -LiteralPath $pending) {
            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
            if ([long](Get-Content -LiteralPath $pending -Raw) -eq $boot) {
                Write-Step 'Windows ожидает перезагрузку. Установка продолжится после входа в этот профиль.'
                exit 3010
            }
            Clear-SetupResume
        } elseif ($ResumeAfterRestart) {
            Clear-SetupResume
            return
        }
        $clientIni = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo\Office.ini'
        $client = Get-DesktopClientConnection $clientIni
        if ((Test-Path -LiteralPath $clientIni -PathType Leaf) -and
            (!$client -or $client.Server -ine $sqlServer -or $client.Owner -ine $owner -or
                !(Test-Path -LiteralPath (Join-Path $stateRoot 'sa.xml')))) {
            Use-ExistingDesktopClient $clientIni
            return
        }
        Show-Preflight
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $root = Get-VendorRoot
        Assert-VendorFiles $root
        if (Install-Net35) { Require-Restart }
        $existing = Get-Service -Name ('MSSQL$' + $instance) -ErrorAction SilentlyContinue
        if ($existing -and !(Test-Path -LiteralPath (Join-Path $stateRoot 'sa.xml'))) {
            throw "Экземпляр $instance уже используется другой установкой."
        }
        $sa = Get-SetupCredential sa
        $admin = Get-SetupCredential $owner
        if (Install-SqlServer $sa) { Require-Restart }
        $currentDb = Get-SqlScalar master "SELECT DB_ID(N'$database')"
        if ($null -ne $currentDb -and $currentDb -isnot [DBNull] -and !(Test-DeloDatabase)) {
            throw "Найдена незавершённая база $database. Проверьте её перед повторной установкой."
        }

        . (Join-Path $PSScriptRoot 'VendorWizard.ps1')
        if (!(Test-DeloDatabase)) {
            Write-Step "Создание базы $database"
            Start-DatabaseWizard -Root $root -Server $sqlServer -Owner $owner -Sa $sa -Admin $admin -Assist:$ManualWizard
            if (!(Test-DeloDatabase)) { throw "Мастер не завершил создание $database." }
        } else {
            Write-Step "База $database уже создана."
        }
        Assert-DatabaseLogin $admin
        Close-CompletedDatabaseWizard $root $owner
        Install-DesktopClient $root
        New-Item -ItemType File -Path (Join-Path $stateRoot 'desktop-owned') -Force | Out-Null
        $programsFolder = Get-DesktopProgramsFolder
        Set-DeloDateFormat
        Write-Step 'Настольное ДЕЛО готово. Проверены вход в базу и шесть ярлыков меню «Пуск».'
        Save-DesktopFiles $programsFolder $admin

        if (!(Get-WindowsOptionalFeature -Online -FeatureName 'IIS-WebServerRole')) {
            Write-Step 'В этом образе Windows недоступен IIS. Настольное ДЕЛО и TXT с данными входа готовы.'
            return
        }
        if (Install-IisComponents) { Require-Restart }
        Initialize-LocalSite
        if (!(Test-WebReady)) {
            Write-Step "Установка ДЕЛО-Web на $siteUrl"
            Start-WebWizard -Root $root -Server $sqlServer -Owner $owner -Admin $admin -SiteName $siteName -SiteUrl $siteUrl -Assist:$ManualWizard
            $ready = $false
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                if (Test-WebReady) { $ready = $true; break }
                Start-Sleep -Seconds 4
            }
            if (!$ready) { throw "Страница входа пока не открывается по адресу $siteUrl." }
        } else {
            $null = Close-CompletedWebWizard
        }
        $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'DELO 22.2 Web.url'
        Set-Content -LiteralPath $shortcut -Value @('[InternetShortcut]', "URL=$siteUrl") -Encoding ASCII
        Write-Step "Установка проверена. $siteUrl"
        Write-Host "Логин администратора: $owner"
    } finally {
        if ($held) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}

try {
    Invoke-DeloSetup
} catch {
    $message = $_.Exception.Message -replace 'Delo!9a-[a-f0-9]{36}', '[пароль скрыт]'
    if ($Install -and !(Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    if (Test-Path -LiteralPath $stateRoot) { Write-Step "Остановка. $message" } else { Write-Host $message }
    Write-Host "Журнал: $statusPath"
    exit 1
}
