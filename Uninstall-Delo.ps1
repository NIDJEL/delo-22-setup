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

function Remove-LabSqlServer {
    $name = 'MSSQL$' + $instance
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (!$service) { return }
    if (!(Test-Path -LiteralPath (Join-Path $stateRoot 'sa.xml'))) {
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

    if ($databaseOwner) {
        $null = Get-SqlScalar master "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database]; SELECT 1"
        Write-Step "База $database удалена."
    }
    if ($other -gt 0) {
        Write-Step "Экземпляр SQL Server $instance сохранён, поскольку в нём есть другие базы."
        return
    }

    $setup = Join-Path $cache 'SQLSetup\SETUP.EXE'
    if (!(Test-Path -LiteralPath $setup)) {
        $setup = Join-Path $env:ProgramFiles 'Microsoft SQL Server\150\Setup Bootstrap\SQL2019\setup.exe'
    }
    if (!(Test-Path -LiteralPath $setup)) {
        throw "Не найдена локальная программа удаления SQL Server для экземпляра $instance."
    }
    Assert-Publisher $setup 'CN=Microsoft Corporation'
    Write-Step "Удаление экземпляра SQL Server $instance"
    $code = Start-Installer $setup @('/Q','/ACTION=Uninstall','/FEATURES=SQLENGINE,FULLTEXT',"/INSTANCENAME=$instance")
    if ($code -eq 3010) { Require-Restart }
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) { throw "Экземпляр SQL Server $instance ещё зарегистрирован." }
}

function Remove-LabShortcuts {
    $startMenu = [Environment]::GetFolderPath('Programs')
    $web = Join-Path $startMenu 'DELO 22.2 Web.url'
    if ((Test-Path -LiteralPath $web -PathType Leaf) -and
        ((Get-Content -LiteralPath $web) -contains "URL=$siteUrl")) {
        Remove-Item -LiteralPath $web
    }

    $output = Join-Path $stateRoot 'output-directory.txt'
    $folders = @($InstallerDirectory)
    if (Test-Path -LiteralPath $output) {
        $folders += Get-Content -LiteralPath $output -Encoding UTF8
    }
    $passwordFile = Join-Path $stateRoot "$owner.xml"
    $credentialText = if (Test-Path -LiteralPath $passwordFile) {
        Get-DesktopCredentialText ([PSCredential]::new($owner, (Import-Clixml -LiteralPath $passwordFile)))
    }
    $programFolders = @(
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Дело'),
        (Join-Path $startMenu 'Дело')
    )
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in ($folders | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)) {
        foreach ($file in (Get-ChildItem -LiteralPath $folder -File)) {
            if ($file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
            if ($file.Name -match '^Дело(?: \(\d+\))?\.lnk$') {
                $target = $shell.CreateShortcut($file.FullName).TargetPath
                if ($target -in $programFolders) { Remove-Item -LiteralPath $file.FullName }
            }
            if ($file.Name -match '^Дело - управление(?: \(\d+\))?\.lnk$') {
                $link = $shell.CreateShortcut($file.FullName)
                if ($link.Arguments -ceq '-Menu' -and $link.Description -ceq 'Управление учебной установкой ДЕЛО 22.2') {
                    Remove-Item -LiteralPath $file.FullName
                }
            }
            if ($credentialText -and $file.Name -match '^Дело - вход(?: \(\d+\))?\.txt$' -and
                [IO.File]::ReadAllText($file.FullName) -ceq $credentialText) {
                Remove-Item -LiteralPath $file.FullName
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
    if ($root.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Папка $resolved ссылается на другой каталог."
    }
    $link = Get-ChildItem -LiteralPath $resolved -Force -Recurse -Attributes ReparsePoint | Select-Object -First 1
    if ($link) {
        throw "В папке $resolved найдена ссылка на другой каталог."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-DeloUninstall {
    if (!(Test-Path -LiteralPath $stateRoot -PathType Container)) {
        Write-Host 'Учебная установка в этом профиле Windows не найдена.'
        return
    }
    Write-Host "Будут удалены учебный клиент, сайт и база $database с документами, а также скачанные пакеты."
    $answer = [string](Read-Host 'Для подтверждения введите УДАЛИТЬ')
    if ($answer.Trim() -ne 'УДАЛИТЬ') { return }
    Clear-SetupResume

    . (Join-Path $PSScriptRoot 'VendorWizard.ps1')
    $wizard = Get-SavedWebWizardProcess (Join-Path $stateRoot 'web-wizard.json')
    $window = if ($wizard) { Get-WizardWindow web $wizard.Id } else { Get-WizardWindow web }
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
    if (Test-DeloDatabase) { Close-CompletedDatabaseWizard (Join-Path $cache 'Delo22-20250527') $owner }

    $eosRoot = Join-Path ${env:ProgramFiles(x86)} 'EOS'
    $webProduct = "ДЕЛО (серверная часть) - $owner"
    $serverRemoval = Join-Path $stateRoot 'remove-server.pending'
    if (Get-DeloMsiProduct $webProduct) {
        New-Item -ItemType File -Path $serverRemoval -Force | Out-Null
        Remove-DeloMsiProduct $webProduct
    }
    if (Test-Path -LiteralPath $serverRemoval) {
        $webFiles = Join-Path $eosRoot "DeloServer\$owner"
        Remove-VerifiedSetupDirectory $webFiles (Join-Path $eosRoot 'DeloServer\LAB22')
    }

    $clientRemoval = Join-Path $stateRoot 'remove-client.pending'
    $client = Join-Path $eosRoot 'Delo\Office.ini'
    if (Test-Path -LiteralPath $client) {
        if (Test-ClientReady) {
            New-Item -ItemType File -Path $clientRemoval -Force | Out-Null
            Remove-DeloMsiProduct 'Дело'
        }
        else { Write-Step 'Найден настольный клиент с другим подключением. Его файлы сохранены.' }
    }
    if ((Test-Path -LiteralPath $clientRemoval) -and !(Get-DeloMsiProduct 'Дело')) {
        $desktop = Join-Path $eosRoot 'Delo'
        Remove-VerifiedSetupDirectory $desktop (Join-Path ${env:ProgramFiles(x86)} 'EOS\Delo')
    }
    Remove-LabIisSite
    Remove-LabSqlServer
    Remove-LabShortcuts
    Remove-VerifiedSetupDirectory $stateRoot (Join-Path $env:LOCALAPPDATA 'Delo22Lab-Setup')
    Write-Host 'Удаление учебной установки завершено. Общие компоненты Windows сохранены.'
}
