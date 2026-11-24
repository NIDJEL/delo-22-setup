[CmdletBinding()]
param(
    [string]$SourceFolder,
    [uri]$ArchiveUrl,
    [string]$InstallerDirectory,
    [switch]$Check,
    [switch]$DownloadOnly,
    [switch]$ManualWizard,
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
$stateRoot = Join-Path $env:LOCALAPPDATA 'Delo22Lab-Setup'
$cache = Join-Path $stateRoot 'Media'
$statusPath = Join-Path $stateRoot 'setup.log'
$appcmd = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
$vendorArchiveHash = '75026D10B3D0DE547AB40560BEB26156D6E7E50E6774EC057E684092F5825E46'
$vendorSource = 'https://disk.yandex.ru/d/4FdxZceXFHLXcw'
$githubArchive = 'https://github.com/NIDJEL/delo-22-setup/releases/download/v0.1.0/2025.05.27.1_Box_22.2.zip'
$vendorManifestHash = '390B78953C1E681CE29795980E64FC117C5BD78D4EC0D7AC4A043E2E88CC5ACE'
$windowsFeatures = @(
    'IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementConsole', 'IIS-ASPNET45',
    'IIS-HttpRedirect', 'IIS-WebSockets', 'IIS-WindowsAuthentication',
    'IIS-BasicAuthentication', 'IIS-ManagementScriptingTools', 'IIS-Metabase', 'NetFx3'
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
    & curl.exe --fail --location --proto '=https' --proto-redir '=https' --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 7200 --progress-bar --output $temp $Uri.AbsoluteUri
    if ($LASTEXITCODE -ne 0) { throw ('Не удалось скачать ' + (Split-Path $Path -Leaf)) }
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-MicrosoftPackage([string]$Key) {
    $path = Join-Path $cache $packageNames[$Key]
    if (!(Test-Path -LiteralPath $path)) { Receive-File $packages[$Key] $path }
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

function Get-VendorRoot {
    if ($SourceFolder) { return Find-VendorRoot (Resolve-Path -LiteralPath $SourceFolder).Path }
    $archive = Join-Path $cache '2025.05.27.1_Box_22.2.zip'
    $extract = Join-Path $cache 'DeloBox-2025-05-27-cp866'
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
        if (!(Test-Path -LiteralPath $extract)) {
            Write-Step 'Распаковка ДЕЛО 22.2'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $staging = "$extract-$([guid]::NewGuid().ToString('N'))"
            [IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging, [Text.Encoding]::GetEncoding(866))
            Find-VendorRoot $staging | Out-Null
            Move-Item -LiteralPath $staging -Destination $extract
        }
        Find-VendorRoot $extract | Out-Null
        New-Item -ItemType File -Path $stamp -Force | Out-Null
    }
    Find-VendorRoot $extract
}

function Assert-VendorFiles([string]$Root) {
    $manifest = Join-Path $PSScriptRoot 'VendorFiles.json'
    if (!(Test-Hash $manifest $vendorManifestHash)) { throw 'Не совпала контрольная сумма списка файлов.' }
    foreach ($file in (Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if (!(Test-Hash (Join-Path $Root $file.Path) $file.Sha256)) {
            throw ('Файл отличается от дистрибутива 27.05.2025. ' + $file.Path)
        }
    }
    Assert-Publisher (Join-Path $Root 'Client\setup.msi') 'ELEKTRONNYE OFISNYE SISTEMY'
    Assert-Publisher (Join-Path $Root 'ServerSetup\setup.msi') 'ELEKTRONNYE OFISNYE SISTEMY'
}

function Start-Installer([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
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

function Get-SqlScalar([string]$Catalog, [string]$Query) {
    $connection = [Data.SqlClient.SqlConnection]::new("Data Source=lpc:$sqlServer;Initial Catalog=$Catalog;Integrated Security=True;Connect Timeout=5")
    try {
        $connection.Open()
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
        "Data Source=lpc:$sqlServer;Initial Catalog=$database;Connect Timeout=5", $credential
    )
    try {
        $connection.Open()
    } catch {
        throw "Не удалось войти в базу $database как $($Admin.UserName)."
    } finally {
        $connection.Dispose()
        $password.Dispose()
    }
}

function Install-WindowsFeatures {
    $modernNet35 = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber -ge 28000
    $toEnable = @()
    foreach ($feature in $windowsFeatures) {
        if ($modernNet35 -and $feature -eq 'NetFx3') { continue }
        $value = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($value -eq 'EnablePending') { return $true }
        if ($value -ne 'Enabled') { $toEnable += $feature }
    }
    if ($toEnable.Count -gt 0) {
        Write-Step 'Включение компонентов IIS и .NET Framework'
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $toEnable -All -NoRestart
        if ($result.RestartNeeded -or !(Test-Path -LiteralPath $appcmd)) { return $true }
    }
    $runtime = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v2.0.50727\mscorwks.dll'
    if ($modernNet35 -and !(Test-Path -LiteralPath $runtime)) {
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

function Test-ClientReady {
    $root = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo'
    $ini = Join-Path $root 'Office.ini'
    if (!(Test-Path -LiteralPath $ini) -or !(Test-Path -LiteralPath (Join-Path $root 'Bin\base32.exe'))) { return $false }
    $config = Get-Content -LiteralPath $ini -Raw -Encoding Default
    $config -match ('(?im)^ServerName=' + [regex]::Escape($sqlServer) + '\s*$') -and
        $config -match ('(?im)^(?:Owner|DBOwner)=' + [regex]::Escape($owner) + '\s*$')
}

function Require-Restart {
    $launcher = if ($InstallerDirectory) { 'Delo-Setup.exe' } else { 'Start-Delo-Setup.cmd' }
    Write-Step "Перезагрузите Windows и снова запустите $launcher. Установленные компоненты и скачанные файлы сохранятся."
    exit 3010
}

function Install-DesktopClient([string]$Root) {
    if (Test-ClientReady) { return }
    $clientIni = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo\Office.ini'
    if (Test-Path -LiteralPath $clientIni) { throw 'Найден другой клиент ДЕЛО. Его настройки сохранены.' }
    $file = Join-Path $Root 'Client\setup.msi'
    $log = Join-Path $stateRoot 'client-msi.log'
    Write-Step 'Установка настольного клиента'
    $code = Start-Installer "$env:SystemRoot\System32\msiexec.exe" @(
        '/i', ('"' + $file + '"'), '/qn', '/norestart', '/Le', ('"' + $log + '"'),
        'ISSETUPDRIVEN=1', 'DBTYPE=MSS', "DBSERVERNAME=$sqlServer", "DBOWNER=$owner", 'ADDLOCAL=ALL'
    )
    if ($code -eq 3010) { Require-Restart }
    if (!(Test-ClientReady)) { throw 'Не удалось подтвердить конфигурацию настольного клиента.' }
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

function Save-DesktopFiles([string]$ProgramsFolder, [pscredential]$Admin) {
    $contents = @(
        'Учебная установка ДЕЛО 22.2'
        ''
        "Логин: $($Admin.UserName)"
        "Пароль: $($Admin.GetNetworkCredential().Password)"
        "ДЕЛО-Web: $siteUrl"
    ) -join "`r`n"
    $contents += "`r`n"

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

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = Get-AdjacentOutputPath 'Дело.lnk' {
        param($path)
        try { $shell.CreateShortcut($path).TargetPath -ieq $ProgramsFolder } catch { $false }
    }
    if (!(Test-Path -LiteralPath $shortcut)) {
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $ProgramsFolder
        $link.WorkingDirectory = $ProgramsFolder
        $link.Description = 'Настольные модули ДЕЛО'
        $link.Save()
    }
    Write-Step "Ярлык на настольные модули сохранён в файле $shortcut"
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
    if ($CopyPassword) {
        $file = Join-Path $stateRoot "$owner.xml"
        if (!(Test-Path -LiteralPath $file)) { throw 'Пароль появится после создания локальной базы.' }
        $credential = [PSCredential]::new($owner, (Import-Clixml -LiteralPath $file))
        $credential.GetNetworkCredential().Password | Set-Clipboard
        Write-Host "Пароль для $owner скопирован в буфер обмена."
        return
    }
    Show-Preflight
    if ($Check) { return }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    if ($DownloadOnly) {
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
        if ($ManualWizard) { $arguments += '-ManualWizard' }
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $child.ExitCode
    }

    $lock = [Threading.Mutex]::new($false, 'Local\Delo22Lab.Setup')
    $held = $false
    try {
        try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Установщик уже открыт.' }
        $consent = Join-Path $stateRoot 'accepted'
        if (!(Test-Path -LiteralPath $consent)) {
            Write-Host 'Учебная установка ДЕЛО 22.2 и Microsoft SQL Server 2019 Express.'
            if ((Read-Host 'Принять условия установщиков и продолжить? Введите YES') -cne 'YES') { return }
            New-Item -Path $consent -ItemType File -Force | Out-Null
        }
        $root = Get-VendorRoot
        Assert-VendorFiles $root
        $clientIni = Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo\Office.ini'
        if ((Test-Path -LiteralPath $clientIni) -and !(Test-ClientReady)) {
            throw 'Найден другой настольный клиент ДЕЛО. Этот установщик рассчитан на компьютер без настроенного клиента.'
        }
        if (Install-WindowsFeatures) { Require-Restart }
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
        }
        Assert-DatabaseLogin $admin
        Install-DesktopClient $root
        $programsFolder = Get-DesktopProgramsFolder
        Write-Step 'Настольное ДЕЛО готово. Проверены вход в базу и шесть ярлыков меню «Пуск».'
        if ($InstallerDirectory) { Save-DesktopFiles $programsFolder $admin }

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
        }
        $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'DELO 22.2 Web.url'
        Set-Content -LiteralPath $shortcut -Value @('[InternetShortcut]', "URL=$siteUrl") -Encoding ASCII
        Write-Step "Установка проверена. $siteUrl"
        Write-Host "Логин администратора: $owner"
        if ($InstallerDirectory) {
            Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ('"' + $programsFolder + '"')
        } else {
            $null = Read-Host 'Нажмите Enter, чтобы скопировать пароль и открыть страницу входа'
            $admin.GetNetworkCredential().Password | Set-Clipboard
            Start-Process $siteUrl
        }
    } finally {
        if ($held) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}

try {
    Invoke-DeloSetup
} catch {
    $message = $_.Exception.Message -replace 'Delo!9a-[a-f0-9]{36}', '[пароль скрыт]'
    if (Test-Path -LiteralPath $stateRoot) { Write-Step "Остановка. $message" } else { Write-Host $message }
    Write-Host "Журнал: $statusPath"
    exit 1
}
