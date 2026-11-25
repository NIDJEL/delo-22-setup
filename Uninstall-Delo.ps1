function Get-DeloMsiProduct([string]$DisplayName) {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -match '^\{[0-9a-f-]{36}\}$' -and
            $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -ieq $DisplayName
    } | Select-Object -ExpandProperty PSChildName -Unique
}

function Remove-DeloMsiProduct([string]$DisplayName) {
    foreach ($product in (Get-DeloMsiProduct $DisplayName)) {
        Write-Step "Удаление $DisplayName"
        $code = Start-Installer "$env:SystemRoot\System32\msiexec.exe" @(
            '/x', $product, '/qn', '/norestart', 'REBOOT=ReallySuppress'
        )
        if ($code -eq 3010) { Require-Restart }
    }
    if (Get-DeloMsiProduct $DisplayName) { throw "Windows ещё показывает $DisplayName в списке установленных программ." }
}

function Remove-LabIisSite {
    if (!(Test-Path -LiteralPath $appcmd)) { return }
    $sites = & $appcmd list site /text:name
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить сайты IIS.' }
    if ($siteName -notin $sites) { return }
    $binding = & $appcmd list site $siteName /text:bindings
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить привязку сайта.' }
    $path = & $appcmd list vdir "$siteName/" /text:physicalPath
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить папку сайта.' }
    if ($binding -ne "http/127.0.0.1:${sitePort}:" -or $path -ne (Join-Path $stateRoot 'LocalSite')) {
        throw "IIS: параметры сайта $siteName отличаются от параметров учебной установки."
    }
    $apps = & $appcmd list app "/site.name:$siteName" /text:path
    if ($LASTEXITCODE -ne 0 -or @($apps | Where-Object { $_ -notin '/', "/$owner", "/$owner/CoreHost" }).Count) {
        throw "IIS: на сайте $siteName есть приложения с другими путями."
    }
    $null = & $appcmd delete site $siteName
    if ($LASTEXITCODE -ne 0) { throw "Не удалось удалить сайт $siteName." }
    Write-Step "Локальный сайт $siteName удалён."
}

function Remove-DeloIisApps([string]$WebFiles) {
    if (!(Test-Path -LiteralPath $appcmd)) { return }
    $names = & $appcmd list app /text:app.name
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить приложения IIS.' }
    foreach ($name in ($names | Where-Object { $_ -match ('/' + [regex]::Escape($owner) + '(?:/CoreHost)?$') } | Sort-Object Length -Descending)) {
        $path = & $appcmd list vdir "$name/" /text:physicalPath
        if ($LASTEXITCODE -ne 0 -or !$path) { throw "Не удалось проверить папку приложения IIS $name." }
        $resolved = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($path)).TrimEnd('\')
        if ($resolved -ine $WebFiles -and
            !$resolved.StartsWith(($WebFiles.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        $null = & $appcmd delete app $name
        if ($LASTEXITCODE -ne 0) { throw "Не удалось удалить приложение IIS $name." }
        Write-Step "Приложение IIS $name удалено."
    }
    $pools = & $appcmd list apppool /text:apppool.name
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить пулы приложений IIS.' }
    foreach ($pool in ($pools | Where-Object { $_ -match ('^Eos\.AppPool\.\d+\.' + [regex]::Escape($owner) + '(?:\.CoreHost)?$') } | Select-Object -Unique)) {
        $remaining = & $appcmd list app "/apppool.name:$pool" /text:app.name
        if ($LASTEXITCODE -ne 0) { throw "Не удалось проверить использование пула $pool." }
        if ($remaining) { continue }
        $null = & $appcmd delete apppool $pool
        if ($LASTEXITCODE -ne 0) { throw "Не удалось удалить пул $pool." }
    }
}

function Remove-LabSqlServer {
    $name = 'MSSQL$' + $instance
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (!$service) { return }
    if ($target.Lab -and !(Test-Path -LiteralPath (Join-Path $stateRoot 'sa.xml'))) {
        Write-Step "Экземпляр SQL Server $instance сохранён. Нет записи этой установки."
        return
    }
    if ($service.Status -ne 'Running') { Start-Service -Name $name }

    $actual = [string](Get-SqlScalar master "SELECT CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName'))")
    if ($actual -ine $instance) { throw 'Подключение указывает на другой экземпляр SQL Server.' }
    $databaseOwner = Get-SqlScalar master "SELECT SUSER_SNAME(owner_sid) FROM sys.databases WHERE name = N'$database'"
    $other = Get-SqlScalar master "SELECT COUNT(*) FROM sys.databases WHERE database_id > 4 AND name <> N'$database'"
    if ($databaseOwner -and ($databaseOwner -is [DBNull] -or $databaseOwner -ine $owner)) {
        throw "Владелец базы $database отличается от $owner."
    }

    $setup = $null
    if ($other -eq 0) {
        $major = [int](Get-SqlScalar master "SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'))")
        $bootstrap = Join-Path $env:ProgramFiles "Microsoft SQL Server\${major}0\Setup Bootstrap"
        if ($major -eq 15) {
            $setup = Join-Path $cache 'SQLSetup\SETUP.EXE'
        }
        if (!$setup -or !(Test-Path -LiteralPath $setup)) {
            $setup = Get-ChildItem -LiteralPath $bootstrap -Directory -ErrorAction SilentlyContinue |
                Where-Object Name -match '^SQL\d{4}$' | ForEach-Object { Join-Path $_.FullName 'setup.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        }
        if (!$setup) { throw "Не найдена локальная программа удаления SQL Server для экземпляра $instance." }
        Assert-Publisher $setup 'CN=Microsoft Corporation'
    }

    if ($databaseOwner) {
        $null = Get-SqlScalar master "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database]; SELECT 1"
        Write-Step "База $database удалена."
    }
    if (!$setup) {
        Write-Step "Экземпляр SQL Server $instance сохранён, поскольку в нём есть другие базы."
        return
    }
    Write-Step "Удаление экземпляра SQL Server $instance"
    $code = Start-Installer $setup @('/Q','/ACTION=Uninstall','/FEATURES=SQLENGINE,FULLTEXT',"/INSTANCENAME=$instance")
    if ($code -eq 3010) { Require-Restart }
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) { throw "Экземпляр SQL Server $instance ещё зарегистрирован." }
}

function Remove-LabShortcuts {
    $startMenu = [Environment]::GetFolderPath('Programs')
    $web = Join-Path $startMenu 'DELO 22.2 Web.url'
    if ($target.Lab -and (Test-Path -LiteralPath $web -PathType Leaf) -and
        ((Get-Content -LiteralPath $web) -contains "URL=$siteUrl")) {
        Remove-Item -LiteralPath $web
    }

    $output = Join-Path $stateRoot 'output-directory.txt'
    $folders = @($InstallerDirectory)
    if (Test-Path -LiteralPath $output) {
        $folders += Get-Content -LiteralPath $output -Encoding UTF8
    }
    $passwordFile = Join-Path $stateRoot "$owner.xml"
    $credentialText = if ($target.Lab -and (Test-Path -LiteralPath $passwordFile)) {
        Get-DesktopCredentialText ([PSCredential]::new($owner, (Import-Clixml -LiteralPath $passwordFile)))
    }
    $programFolders = @(
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Дело'),
        (Join-Path $startMenu 'Дело')
    )
    $shell = New-Object -ComObject WScript.Shell
    if ($removeDesktop) {
        $moduleRoot = $desktop + '\'
        foreach ($folder in ($programFolders | Select-Object -Unique)) {
            $entry = Get-Item -LiteralPath $folder -ErrorAction SilentlyContinue
            if (!$entry -or !$entry.PSIsContainer -or $entry.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
            $removedModule = $false
            foreach ($module in $desktopModules) {
                $path = Join-Path $folder "$module.lnk"
                $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if (!$file -or $file.PSIsContainer -or $file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
                $link = $shell.CreateShortcut($file.FullName)
                if (([string]$link.TargetPath).StartsWith($moduleRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item -LiteralPath $file.FullName
                    $removedModule = $true
                }
            }
            if ($removedModule -and !(Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1)) {
                [IO.Directory]::Delete($folder)
            }
        }
    }
    foreach ($folder in ($folders | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)) {
        foreach ($file in (Get-ChildItem -LiteralPath $folder -File)) {
            if ($file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
            if ($file.Name -match '^Дело(?: \(\d+\))?\.lnk$') {
                $linkTarget = $shell.CreateShortcut($file.FullName).TargetPath
                if ($removeDesktop -and $linkTarget -in $programFolders) { Remove-Item -LiteralPath $file.FullName }
            }
            if ($clearCache -and $file.Name -match '^Дело - управление(?: \(\d+\))?\.lnk$') {
                $link = $shell.CreateShortcut($file.FullName)
                if ($link.Arguments -ceq '-Menu' -and $link.Description -ceq 'Управление учебной установкой ДЕЛО 22.2') {
                    Remove-Item -LiteralPath $file.FullName
                }
            }
            if ($credentialText -and $file.Name -match '^Дело - вход(?: \(\d+\))?\.txt$' -and
                [IO.File]::ReadAllText($file.FullName) -ceq $credentialText) {
                Remove-Item -LiteralPath $file.FullName
            }
            if (!$isLabRemoval -and $removeDesktop -and $file.Name -match '^Дело - вход(?: \(\d+\))?\.txt$') {
                $contents = [IO.File]::ReadAllLines($file.FullName)
                if ('ДЕЛО 22.2 — действующая учебная база' -in $contents -and "База: $database" -in $contents -and
                    "Сервер БД: $sqlServer" -in $contents -and "Логин: $owner" -in $contents) { Remove-Item -LiteralPath $file.FullName }
            }
        }
    }
}

function Remove-VerifiedSetupDirectory([string]$Path, [string]$ExpectedPath) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ($resolved -ine $expected) { throw 'Путь удаления не совпал с папкой этой установки.' }
    $root = Get-Item -LiteralPath $resolved -Force
    for ($folder = $root; $folder; $folder = $folder.Parent) {
        if ($folder.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "Папка $($folder.FullName) ссылается на другой каталог."
        }
    }
    $link = Get-ChildItem -LiteralPath $resolved -Force -Recurse -Attributes ReparsePoint | Select-Object -First 1
    if ($link) {
        throw "В папке $resolved найдена ссылка на другой каталог."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Get-LocalDeloTarget([string]$ClientIni) {
    $client = Get-DesktopClientConnection $ClientIni
    if (!$client -or $client.Owner -notmatch '\A[A-Z][A-Z0-9_]{0,31}\z') { return }
    $localHost = [regex]::Escape($env:COMPUTERNAME)
    if ($client.Server -match ('\A(?:\.|\(local\)|localhost|' + $localHost + ')\\(?<instance>[A-Z][A-Z0-9_]{0,15})\z')) {
        [pscustomobject]@{ Owner = $client.Owner; Instance = $Matches['instance'] }
    }
}

function Invoke-DeloUninstall {
    $labInstance = $instance
    $labOwner = $owner
    $eosRoot = Join-Path ${env:ProgramFiles(x86)} 'EOS'
    $desktop = Join-Path $eosRoot 'Delo'
    $clientIni = Join-Path $desktop 'Office.ini'
    $configured = Get-LocalDeloTarget $clientIni
    $plan = Join-Path $stateRoot 'removal.json'
    $resume = Test-Path -LiteralPath $plan -PathType Leaf
    $labProduct = "ДЕЛО (серверная часть) - $labOwner"
    $labInstalled = ($configured -and $configured.Owner -ieq $labOwner -and $configured.Instance -ieq $labInstance) -or
        (Get-Service -Name ('MSSQL$' + $labInstance) -ErrorAction SilentlyContinue) -or (Get-DeloMsiProduct $labProduct) -or
        (Test-Path -LiteralPath (Join-Path $eosRoot "DeloServer\$labOwner")) -or
        (!$configured -and (Test-Path -LiteralPath (Join-Path $stateRoot 'desktop-owned') -PathType Leaf))

    if ($resume) {
        $target = Get-Content -LiteralPath $plan -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $targets = @()
        if ($labInstalled -or (!$configured -and (Test-Path -LiteralPath $stateRoot -PathType Container))) {
            $targets += [pscustomobject]@{ Owner = $labOwner; Instance = $labInstance }
        }
        if ($configured -and ($configured.Owner -ine $labOwner -or $configured.Instance -ine $labInstance)) {
            $targets += $configured
        }
        if (!$targets.Count) { Write-Host 'Локальная установка ДЕЛО и её загрузки не найдены.'; return }
        $target = $targets[0]
        if ($targets.Count -eq 2) {
            Write-Host "1. $($targets[0].Owner)_DB на .\$($targets[0].Instance)"
            Write-Host "2. $($targets[1].Owner)_DB на .\$($targets[1].Instance)"
            $choice = ([string](Read-Host 'Выберите установку для удаления')).Trim()
            if ($choice -notin '1','2') { return }
            $target = $targets[[int]$choice - 1]
        }
    }
    if (!$target -or $target.Owner -notmatch '\A[A-Z][A-Z0-9_]{0,31}\z' -or
        $target.Instance -notmatch '\A[A-Z][A-Z0-9_]{0,15}\z') { throw 'Сохранённые данные удаления повреждены.' }
    $owner = $target.Owner
    $instance = $target.Instance
    $sqlServer = ".\$instance"
    $database = "${owner}_DB"
    $isLabRemoval = $owner -ieq $labOwner -and $instance -ieq $labInstance
    $target | Add-Member -NotePropertyName Lab -NotePropertyValue $isLabRemoval -Force
    $clearCache = $isLabRemoval -or !$labInstalled
    $confirmation = if ($isLabRemoval) { 'УДАЛИТЬ' } else { "УДАЛИТЬ $database" }
    Write-Host "Будут удалены компоненты этой установки ДЕЛО и база $database с документами на $sqlServer."
    $answer = [string](Read-Host "Для подтверждения введите $confirmation")
    if ($answer.Trim() -ne $confirmation) { return }

    if (!$resume -and !$isLabRemoval) {
        $service = Get-Service -Name ('MSSQL$' + $instance) -ErrorAction SilentlyContinue
        if ($service) {
            if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
            $dbId = Get-SqlScalar master "SELECT DB_ID(N'$database')"
            if ($dbId -and $dbId -isnot [DBNull]) {
                $dbo = Get-SqlScalar master "SELECT SUSER_SNAME(owner_sid) FROM sys.databases WHERE name = N'$database'"
                if ($dbo -ine $owner -or !(Test-DeloDatabase)) { throw "Не удалось подтвердить, что $database принадлежит выбранной установке ДЕЛО." }
            }
        }
    }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $target | ConvertTo-Json -Compress | Set-Content -LiteralPath $plan -Encoding UTF8
    if ($clearCache) { Clear-SetupResume }

    . (Join-Path $PSScriptRoot 'VendorWizard.ps1')
    $wizard = if ($isLabRemoval) { Get-SavedWebWizardProcess (Join-Path $stateRoot 'web-wizard.json') }
    $window = if ($wizard) { Get-WizardWindow web $wizard.Id }
    if ($window) {
        $closed = $false
        if ($wizard) {
            if ((Test-WebReady) -and (Close-CompletedWebWizard)) {
                $closed = $wizard.WaitForExit(3000)
            } else {
                $closed = Close-WebWizardBeforeInstall $window $wizard
            }
        }
        if (!$closed) {
            throw 'Сначала завершите или закройте открытый мастер серверной части.'
        }
    }
    if ($isLabRemoval -and (Get-Service -Name ('MSSQL$' + $instance) -ErrorAction SilentlyContinue) -and (Test-DeloDatabase)) {
        Close-CompletedDatabaseWizard (Join-Path $cache 'Delo22-20250527') $owner
    }

    $webProduct = "ДЕЛО (серверная часть) - $owner"
    $webFiles = Join-Path $eosRoot "DeloServer\$owner"
    Remove-DeloMsiProduct $webProduct
    Remove-DeloIisApps $webFiles
    Remove-VerifiedSetupDirectory $webFiles (Join-Path ${env:ProgramFiles(x86)} "EOS\DeloServer\$owner")

    $markerName = if ($isLabRemoval) { 'remove-client.pending' } else { "remove-$instance-$owner-client.pending" }
    $clientRemoval = Join-Path $stateRoot $markerName
    $configured = Get-LocalDeloTarget $clientIni
    $removeDesktop = if (Test-Path -LiteralPath $clientIni) {
        $configured -and $configured.Owner -ieq $owner -and $configured.Instance -ieq $instance
    } else {
        (Test-Path -LiteralPath $clientRemoval) -or
            ($isLabRemoval -and (Test-Path -LiteralPath (Join-Path $stateRoot 'desktop-owned') -PathType Leaf))
    }
    if ($removeDesktop) {
        New-Item -ItemType File -Path $clientRemoval -Force | Out-Null
        Remove-DeloMsiProduct 'Дело'
        Remove-VerifiedSetupDirectory $desktop (Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo')
    }
    if ($isLabRemoval) { Remove-LabIisSite }
    Remove-LabSqlServer
    Remove-LabShortcuts
    if ($clearCache) {
        Restore-DeloDateFormat
        Remove-VerifiedSetupDirectory $stateRoot (Join-Path $env:LOCALAPPDATA 'Delo22Lab-Setup')
    } else {
        Remove-Item -LiteralPath $plan
        if (Test-Path -LiteralPath $clientRemoval) { Remove-Item -LiteralPath $clientRemoval }
    }
    Write-Host "Удаление установки $database завершено."
}
