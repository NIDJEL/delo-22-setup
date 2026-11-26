Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# These accounts are created by the vendor wizards and used by the destination installation.
$deloServiceLogins = @($owner, "${owner}_0", "${owner}_file_sync", "${owner}_ntfy_service",
    "${owner}_web_user", "${owner}_ntfy_manage_user")
$deloUserLoginPattern = '^' + [regex]::Escape($owner) + '_(?:[0-9A-F]{2}){1,60}$'

function ConvertTo-DeloSqlName([string]$Name) {
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-DeloSqlText([string]$Value) {
    "N'" + $Value.Replace("'", "''") + "'"
}

function Invoke-DeloTransferSql([string]$Catalog, [string]$Query, [switch]$Rows) {
    $connection = [Data.SqlClient.SqlConnection]::new(
        "Data Source=lpc:$sqlServer;Initial Catalog=$Catalog;Integrated Security=True;Connect Timeout=40;Pooling=False")
    try {
        Open-LabSqlConnection $connection
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 0
        $command.CommandText = $Query
        if ($Rows) {
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $values = [ordered]@{}
                    for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                        $values[$reader.GetName($index)] = $reader.GetValue($index)
                    }
                    [pscustomobject]$values
                }
            } finally { $reader.Dispose() }
        } else { $null = $command.ExecuteNonQuery() }
    } finally { $connection.Dispose() }
}

function Get-DeloTransferBackupPath {
    $folder = [string](Get-SqlScalar master "SELECT SERVERPROPERTY('InstanceDefaultBackupPath')")
    if (!$folder -or !(Test-Path -LiteralPath $folder -PathType Container)) {
        throw 'Не найдена локальная папка резервных копий SQL Server.'
    }
    Join-Path $folder ('DeloTransfer-' + [guid]::NewGuid().ToString('N') + '.bak')
}

function Assert-DeloStoredFiles([string]$Catalog) {
    $count = Get-SqlScalar $Catalog @'
SELECT COUNT_BIG(*) FROM dbo.REF_FILE AS ref
WHERE NULLIF(ref.PATH, '') IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM dbo.FILE_CONTENTS AS f WHERE f.ISN_REF_FILE = ref.ISN_REF_FILE)
    AND NOT EXISTS (SELECT 1 FROM dbo.FILE_CONTENTS2 AS f WHERE f.ISN_REF_FILE = ref.ISN_REF_FILE);
'@
    if ($count -gt 0) { throw "Найдено вложений во внешнем хранилище: $count. Для них нужен отдельный перенос." }
}

function Get-DeloBrokerEnabled {
    [bool](Get-SqlScalar $database 'SELECT is_broker_enabled FROM sys.databases WHERE database_id = DB_ID();')
}

function Get-DeloTransferLogins {
    $logins = Invoke-DeloTransferSql $database -Rows -Query @'
SELECT principal.name AS Name, login.name AS LoginName,
    CONVERT(varchar(34), login.sid, 1) AS Sid,
    CONVERT(varchar(514), login.password_hash, 1) AS PasswordHash,
    login.is_disabled AS Disabled, login.is_policy_checked AS Policy, login.is_expiration_checked AS Expiration,
    CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.server_permissions AS permission
        WHERE permission.grantee_principal_id = login.principal_id
          AND permission.permission_name = 'VIEW SERVER STATE' AND permission.state = 'G') THEN 1 ELSE 0 END) AS ViewServerState
FROM sys.database_principals AS principal
LEFT JOIN sys.sql_logins AS login ON login.sid = principal.sid
WHERE principal.principal_id > 4 AND principal.authentication_type = 1
ORDER BY principal.name;
'@
    foreach ($login in $logins) {
        if ($login.Name -in $deloServiceLogins) { continue }
        if ($login.Name -notmatch $deloUserLoginPattern -or $login.LoginName -ine $login.Name -or
            $login.PasswordHash -is [DBNull]) {
            throw "Не удалось сопоставить SQL-учётную запись $($login.Name) для переноса."
        }
        $login | Select-Object Name, Sid, PasswordHash, Disabled, Policy, Expiration, ViewServerState
    }
}

function Export-DeloDatabase([string]$Path) {
    if (!$Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $Path = Get-AdjacentOutputPath "Дело-$database-$stamp.delo" { $false }
    }
    if (Test-Path -LiteralPath $Path) { throw "Файл уже существует: $Path" }
    if ([IO.Path]::GetExtension($Path) -ine '.delo') { throw 'Укажите имя файла с расширением .delo.' }
    $backup = Get-DeloTransferBackupPath
    $outputTemp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $dbName = ConvertTo-DeloSqlName $database
    $device = ConvertTo-DeloSqlText $backup
    try {
        Assert-DeloStoredFiles $database
        $logins = @(Get-DeloTransferLogins)
        $manifest = [pscustomobject]@{
            Format = 1
            Database = $database
            UseBroker = Get-DeloBrokerEnabled
            Logins = $logins
        } | ConvertTo-Json -Depth 4 -Compress
        Write-Step "Создание резервной копии $database."
        Invoke-DeloTransferSql master "BACKUP DATABASE $dbName TO DISK = $device WITH COPY_ONLY, CHECKSUM;"
        Invoke-DeloTransferSql master "RESTORE VERIFYONLY FROM DISK = $device WITH CHECKSUM;"
        Assert-DeloStoredFiles $database
        $currentLogins = @(Get-DeloTransferLogins)
        if ((ConvertTo-Json -InputObject $logins -Compress) -cne (ConvertTo-Json -InputObject $currentLogins -Compress)) {
            throw 'Во время экспорта изменились учётные записи. Повторите экспорт после завершения работы пользователей.'
        }
        Write-Step 'Упаковка проверенной резервной копии.'
        $zip = [IO.Compression.ZipFile]::Open($outputTemp, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $backup, 'database.bak')
            $entry = $zip.CreateEntry('transfer.json')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($manifest) } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        [IO.File]::Move($outputTemp, $Path)
        Write-Step "Файл для переноса готов: $Path"
    } finally {
        foreach ($file in $backup, $outputTemp) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

function Read-DeloTransferBackup([string]$Path, [string]$Backup) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $metadata = $zip.GetEntry('transfer.json')
        $backupEntry = $zip.GetEntry('database.bak')
        if ($zip.Entries.Count -ne 2 -or !$metadata -or !$backupEntry -or $metadata.Length -gt 1MB) {
            throw 'Файл переноса не содержит резервную копию и описание базы.'
        }
        $reader = [IO.StreamReader]::new($metadata.Open())
        try { $manifest = ConvertFrom-Json -InputObject $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifest.Format -ne 1 -or $manifest.Database -cne $database -or
            $manifest.UseBroker -isnot [bool] -or $manifest.Logins -isnot [array]) {
            throw "Файл переноса не подходит для базы $database."
        }
        $names = @{}
        $sids = @{}
        foreach ($login in $manifest.Logins) {
            if ($login.Name -isnot [string] -or $login.Name -notmatch $deloUserLoginPattern -or
                $login.Sid -isnot [string] -or $login.Sid -notmatch '^0x[0-9A-F]{32}$' -or
                $login.PasswordHash -isnot [string] -or $login.PasswordHash -notmatch '^0x0200[0-9A-F]{136}$' -or
                $login.Disabled -isnot [bool] -or $login.Policy -isnot [bool] -or
                $login.Expiration -isnot [bool] -or $login.ViewServerState -isnot [bool] -or
                ($login.Expiration -and !$login.Policy) -or $names.ContainsKey($login.Name) -or $sids.ContainsKey($login.Sid)) {
                throw 'В файле переноса повреждено описание SQL-учётной записи.'
            }
            $names[$login.Name] = $true
            $sids[$login.Sid] = $true
        }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Backup))
        if ($backupEntry.Length -gt $drive.AvailableFreeSpace) { throw 'Недостаточно места для распаковки базы.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($backupEntry, $Backup)
        $manifest
    } finally { $zip.Dispose() }
}

function Restore-DeloTransferBackup([string]$Backup, [string]$Stage) {
    $device = ConvertTo-DeloSqlText $Backup
    $header = @(Invoke-DeloTransferSql master "RESTORE HEADERONLY FROM DISK = $device;" -Rows)
    if ($header.Count -ne 1 -or $header[0].DatabaseName -ine $database -or $header[0].BackupType -ne 1 -or
        !$header[0].HasBackupChecksums -or $header[0].SoftwareVersionMajor -ne 15) {
        throw "Нужна полная резервная копия $database из SQL Server 2019 с контрольной суммой."
    }
    $dataFolder = [string](Get-SqlScalar master "SELECT SERVERPROPERTY('InstanceDefaultDataPath')")
    $logFolder = [string](Get-SqlScalar master "SELECT SERVERPROPERTY('InstanceDefaultLogPath')")
    $files = @(Invoke-DeloTransferSql master "RESTORE FILELISTONLY FROM DISK = $device;" -Rows)
    if (!$files -or !$dataFolder -or !$logFolder) { throw 'Не удалось получить список файлов и папки SQL Server.' }
    $moves = foreach ($file in $files) {
        switch ($file.Type) {
            'D' { $folder = $dataFolder; $extension = '.mdf' }
            'L' { $folder = $logFolder; $extension = '.ldf' }
            default { throw "В копии обнаружен неподдерживаемый тип файла SQL Server: $($file.Type)" }
        }
        $target = Join-Path $folder "$Stage-$($file.FileId)$extension"
        "MOVE $(ConvertTo-DeloSqlText $file.LogicalName) TO $(ConvertTo-DeloSqlText $target)"
    }
    $options = $moves -join ', '
    Invoke-DeloTransferSql master "RESTORE VERIFYONLY FROM DISK = $device WITH CHECKSUM, $options;"
    Invoke-DeloTransferSql master "RESTORE DATABASE [$Stage] FROM DISK = $device WITH CHECKSUM, RECOVERY, $options;"
    if (!(Test-DeloDatabase $Stage)) { throw 'В восстановленной копии не найдены таблицы ДЕЛО.' }
    Assert-DeloStoredFiles $Stage
}

function Connect-DeloTransferLogins([string]$Stage, [object[]]$Logins) {
    $ownerName = ConvertTo-DeloSqlName $owner
    $commands = @("ALTER AUTHORIZATION ON DATABASE::[$Stage] TO $ownerName;")
    foreach ($name in $deloServiceLogins | Select-Object -Skip 1) {
        $value = ConvertTo-DeloSqlText $name
        $identifier = ConvertTo-DeloSqlName $name
        $commands += "IF USER_ID($value) IS NOT NULL ALTER USER $identifier WITH LOGIN = $identifier;"
    }
    foreach ($login in $Logins) {
        $name = ConvertTo-DeloSqlText $login.Name
        $identifier = ConvertTo-DeloSqlName $login.Name
        $hash = $login.PasswordHash
        $sid = $login.Sid
        $defaultDatabase = ConvertTo-DeloSqlName $database
        $create = "CREATE LOGIN $identifier WITH PASSWORD = $hash HASHED, SID = $sid, DEFAULT_DATABASE = $defaultDatabase, CHECK_POLICY = OFF;"
        if ($login.Policy) { $create += " ALTER LOGIN $identifier WITH CHECK_POLICY = ON;" }
        if ($login.Expiration) { $create += " ALTER LOGIN $identifier WITH CHECK_EXPIRATION = ON;" }
        if ($login.Disabled) { $create += " ALTER LOGIN $identifier DISABLE;" }
        if ($login.ViewServerState) {
            $grant = ConvertTo-DeloSqlText "GRANT VIEW SERVER STATE TO $identifier;"
            $create += " EXEC master.sys.sp_executesql $grant;"
        }
        $commands += @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $name AND sid = $sid AND authentication_type = 1)
    THROW 51000, N'SQL-учётная запись не соответствует резервной копии.', 1;
IF SUSER_ID($name) IS NULL
BEGIN
    $create
END
ELSE IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = $name AND sid = $sid AND password_hash = $hash
    AND is_disabled = $([int]$login.Disabled) AND is_policy_checked = $([int]$login.Policy)
    AND is_expiration_checked = $([int]$login.Expiration))
    THROW 51001, N'SQL-учётная запись $($login.Name) уже существует на этом ПК с другими данными.', 1;
"@
    }
    Invoke-DeloTransferSql $Stage @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
$($commands -join "`n")
IF EXISTS (SELECT 1 FROM sys.database_principals AS principal
    WHERE principal.principal_id > 4 AND principal.type IN ('S', 'U', 'G', 'K', 'C')
      AND principal.authentication_type IN (1, 3)
      AND NOT EXISTS (SELECT 1 FROM sys.server_principals AS login WHERE login.sid = principal.sid))
    THROW 51002, N'В копии есть пользователи SQL Server без подходящих локальных учётных записей.', 1;
COMMIT;
"@
}

function Complete-DeloDatabaseSwitch {
    $state = Get-Content -LiteralPath $transferState -Raw -Encoding UTF8 | ConvertFrom-Json
    $stage = [string]$state.Stage
    $archive = [string]$state.Archive
    if ($stage -notmatch "^$($database)_import_[0-9a-f]{12}$" -or
        $archive -notmatch "^$($database)_before_[0-9]{8}_[0-9]{6}_[0-9a-f]{12}$" -or
        $state.OldId -isnot [int] -or $state.NewId -isnot [int] -or $state.UseBroker -isnot [bool]) {
        throw 'Не удалось прочитать состояние переноса базы.'
    }
    $dbName = ConvertTo-DeloSqlName $database
    $dbText = ConvertTo-DeloSqlText $database
    $oldId = $state.OldId
    $newId = $state.NewId
    $broker = if ($state.UseBroker) {
        @"
IF EXISTS (SELECT 1 FROM sys.databases AS previous JOIN sys.databases AS imported
    ON previous.service_broker_guid = imported.service_broker_guid
    WHERE previous.database_id = $oldId AND imported.database_id = $newId AND previous.is_broker_enabled = 1)
    ALTER DATABASE [$archive] SET DISABLE_BROKER WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = $newId AND is_broker_enabled = 0)
    ALTER DATABASE $dbName SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
"@
    }
    Invoke-DeloTransferSql master @"
IF DB_ID($dbText) = $oldId AND DB_ID(N'$stage') = $newId AND DB_ID(N'$archive') IS NULL
BEGIN TRY
    ALTER DATABASE $dbName SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    ALTER DATABASE $dbName MODIFY NAME = [$archive];
END TRY
BEGIN CATCH
    IF DB_ID($dbText) = $oldId ALTER DATABASE $dbName SET MULTI_USER WITH ROLLBACK IMMEDIATE;
    THROW;
END CATCH;
IF DB_ID($dbText) IS NULL AND DB_ID(N'$stage') = $newId AND DB_ID(N'$archive') = $oldId
    ALTER DATABASE [$stage] MODIFY NAME = $dbName;
IF ISNULL(DB_ID($dbText), 0) <> $newId OR ISNULL(DB_ID(N'$archive'), 0) <> $oldId
    THROW 51003, N'Имена баз изменились во время переноса.', 1;
ALTER DATABASE [$archive] SET MULTI_USER WITH ROLLBACK IMMEDIATE;
$broker
"@
    Remove-Item -LiteralPath $transferState
    Write-Step "Импорт завершён. Предыдущая база сохранена как $archive."
}

function Import-DeloDatabase([string]$Path) {
    if (!$Path) {
        Add-Type -AssemblyName System.Windows.Forms
        $picker = [Windows.Forms.OpenFileDialog]::new()
        try {
            $picker.Title = 'Выберите файл переноса базы ДЕЛО'
            $picker.Filter = 'База ДЕЛО (*.delo)|*.delo'
            $picker.InitialDirectory = $InstallerDirectory
            if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
            $Path = $picker.FileName
        } finally { $picker.Dispose() }
    }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Файл переноса не найден: $Path" }
    if (!(Test-Path -LiteralPath (Join-Path $stateRoot "$owner.xml") -PathType Leaf)) {
        throw 'Данные входа LAB22 отсутствуют. Завершите установку ДЕЛО через пункт 1.'
    }
    $admin = Get-SetupCredential $owner
    Assert-DatabaseLogin $admin
    Write-Host 'Закройте модули ДЕЛО и вкладки ДЕЛО-Web на этом ПК. Текущая база будет сохранена под отдельным именем.'
    if ((Read-Host 'Для переключения на импортированную базу введите ИМПОРТ') -cne 'ИМПОРТ') { return }
    $backup = Get-DeloTransferBackupPath
    $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $stage = "${database}_import_$token"
    $archive = "${database}_before_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$token"
    $journal = "$transferState.$token.tmp"
    $readyToSwitch = $false
    try {
        $manifest = Read-DeloTransferBackup $Path $backup
        Write-Step "Проверка и восстановление $database из файла переноса."
        Restore-DeloTransferBackup $backup $stage
        Connect-DeloTransferLogins $stage $manifest.Logins
        Assert-DatabaseLogin $admin $stage
        $state = Invoke-DeloTransferSql master "SELECT DB_ID(N'$database') AS OldId, DB_ID(N'$stage') AS NewId;" -Rows
        $state | Add-Member -NotePropertyName UseBroker -NotePropertyValue $manifest.UseBroker
        $state | Add-Member -NotePropertyName Stage -NotePropertyValue $stage
        $state | Add-Member -NotePropertyName Archive -NotePropertyValue $archive
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $journal -Encoding UTF8
        [IO.File]::Move($journal, $transferState)
        $readyToSwitch = $true
        Complete-DeloDatabaseSwitch
        Write-Step 'Откройте ДЕЛО через обычный ярлык. Данные входа LAB22 на этом ПК доступны через пункт 3.'
    } finally {
        foreach ($file in $backup, $journal) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        if (!$readyToSwitch) {
            Invoke-DeloTransferSql master "IF DB_ID(N'$stage') IS NOT NULL DROP DATABASE [$stage];"
        }
    }
}
