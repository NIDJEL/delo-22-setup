Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DeloDialog {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, string value,
        uint flags, uint milliseconds, out IntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr value,
        uint flags, uint milliseconds, out IntPtr result);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);

    private static IntPtr Send(IntPtr window, uint message, long wParam, IntPtr value) {
        IntPtr result;
        if (SendMessageTimeout(window, message, new IntPtr(wParam), value, 2, 3000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Wizard control did not respond");
        return result;
    }

    public static string WindowClass(IntPtr window) {
        var buffer = new StringBuilder(128);
        GetClassName(window, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    private static bool Notify(IntPtr window, int code) {
        long parameter = (ushort)GetDlgCtrlID(window) + ((long)code << 16);
        return PostMessage(GetParent(window), 0x111, new IntPtr(parameter), window);
    }

    public static bool SetText(IntPtr window, string value) {
        IntPtr result;
        return SendMessageTimeout(window, 0xC, IntPtr.Zero, value, 2, 3000, out result) != IntPtr.Zero
            && result != IntPtr.Zero;
    }

    public static bool Click(IntPtr window) {
        return Notify(window, 0);
    }

    public static bool FocusDialogControl(IntPtr window) {
        IntPtr dialog = GetAncestor(window, 2); // GA_ROOT
        if (dialog == IntPtr.Zero) return false;
        SetForegroundWindow(dialog);
        return PostMessage(dialog, 0x0028, window, new IntPtr(1)); // WM_NEXTDLGCTL, HWND mode
    }

    public static void CommitEdit(IntPtr window) {
        // MSI writes the property on focus loss, even when Next is invoked through WM_COMMAND.
        const uint wmKillFocus = 0x0008;
        const uint wmCommand = 0x0111;
        const long enKillFocus = 0x0200;
        Send(window, wmKillFocus, 0, IntPtr.Zero);
        long notification = (ushort)GetDlgCtrlID(window) + (enKillFocus << 16);
        Send(GetParent(window), wmCommand, notification, window);
    }

    public static bool Check(IntPtr window) {
        if (Send(window, 0xF0, 0, IntPtr.Zero).ToInt32() == 0)
            Send(window, 0xF1, 1, IntPtr.Zero);
        return Notify(window, 0);
    }

    public static bool SelectCombo(IntPtr window, string text) {
        IntPtr index;
        if (SendMessageTimeout(window, 0x158, new IntPtr(-1), text, 2, 3000, out index) == IntPtr.Zero || index.ToInt64() < 0)
            return false;
        Send(window, 0x14E, index.ToInt64(), IntPtr.Zero);
        return Notify(window, 1);
    }

    public static bool SelectSingleChild(IntPtr window) {
        const uint getNextItem = 0x110A;
        IntPtr root = Send(window, getNextItem, 0, IntPtr.Zero);
        IntPtr item = Send(window, getNextItem, 4, root);
        if (item == IntPtr.Zero || Send(window, getNextItem, 1, item) != IntPtr.Zero)
            return false;
        return Send(window, 0x110B, 9, item) != IntPtr.Zero;
    }
}
'@

$script:uia = [Windows.Automation.AutomationElement]
$script:treeChildren = [Windows.Automation.TreeScope]::Children
$script:treeBelow = [Windows.Automation.TreeScope]::Descendants
$script:allElements = [Windows.Automation.Condition]::TrueCondition
$script:webWizardProcessId = $null

function Get-WizardWindow([string]$Kind) {
    foreach ($window in $uia::RootElement.FindAll($treeChildren, $allElements)) {
        try {
            $properties = $window.Current
            $windowProcessId = $properties.ProcessId
            if (!$windowProcessId) { continue }
            $title = $properties.Name
            $process = Get-Process -Id $windowProcessId -ErrorAction SilentlyContinue
            if (!$process) { continue }
            if (($Kind -eq 'database' -and $process.ProcessName -eq 'dbmaster' -and $title -like 'Мастер баз данных*') -or
                ($Kind -eq 'web' -and $process.ProcessName -eq 'msiexec' -and $title -like 'ДЕЛО (серверная часть)*' -and
                    (!$script:webWizardProcessId -or $process.Id -eq $script:webWizardProcessId))) {
                return $window
            }
        } catch [Windows.Automation.ElementNotAvailableException] { continue }
    }
}

function Find-WizardControl(
    [Windows.Automation.AutomationElement]$Window,
    [string]$Key,
    [string]$Type
) {
    if (!$Window) { return }
    $property = $uia::AutomationIdProperty
    if ($Key.StartsWith('name=')) {
        $property = $uia::NameProperty
        $Key = $Key.Substring(5)
    }
    $condition = [Windows.Automation.PropertyCondition]::new($property, $Key)
    foreach ($element in $Window.FindAll($treeBelow, $condition)) {
        $current = $element.Current
        if ($current.IsOffscreen -or (!$current.IsEnabled -and $Type -ne 'Text')) { continue }
        if (!$Type -or $current.ControlType.ProgrammaticName -eq "ControlType.$Type") { return $element }
        $class = [DeloDialog]::WindowClass([IntPtr]$current.NativeWindowHandle)
        $expectedClass = switch ($Type) {
            'Button' { 'Button' }
            'CheckBox' { 'Button|Check' }
            'Edit' { 'Edit' }
            'ComboBox' { 'ComboBox' }
            'Tree' { 'TreeView|SysTreeView' }
            'Text' { 'Static|Text' }
            default { '^$' }
        }
        if ($class -and $class -match $expectedClass) { return $element }
    }
}

function Wait-WizardControl([string]$Kind, [string]$Key, [string]$Type, [int]$Seconds = 22) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        try {
            $control = Find-WizardControl (Get-WizardWindow $Kind) $Key $Type
            if ($control) { return $control }
        } catch [Windows.Automation.ElementNotAvailableException] {}
        Start-Sleep -Milliseconds 280
    }
    throw [TimeoutException]::new("Не найден элемент мастера $Key.")
}

function Invoke-WizardButton([string]$Kind, [string]$Key) {
    $control = Wait-WizardControl $Kind $Key 'Button'
    $native = [IntPtr]$control.Current.NativeWindowHandle
    if ($native -eq [IntPtr]::Zero -or ![DeloDialog]::Click($native)) {
        $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    Start-Sleep -Milliseconds 550
}

function Set-WizardField([string]$Kind, [string]$Id, [string]$Value) {
    $control = Wait-WizardControl $Kind $Id 'Edit'
    $native = [IntPtr]$control.Current.NativeWindowHandle
    if ($native -ne [IntPtr]::Zero) {
        if ($Kind -eq 'web') { $null = [DeloDialog]::FocusDialogControl($native) }
        if ([DeloDialog]::SetText($native, $Value)) {
            if ($Kind -eq 'web') { [DeloDialog]::CommitEdit($native) }
            return
        }
    }
    $pattern = $control.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $pattern.SetValue($Value)
    if ($Kind -eq 'web') {
        if ($native -eq [IntPtr]::Zero) { throw 'Поле мастера требует ручного ввода.' }
        [DeloDialog]::CommitEdit($native)
    }
}

function Select-WizardOption([string]$Kind, [string]$ComboId, [string]$Value) {
    $box = Wait-WizardControl $Kind $ComboId 'ComboBox'
    $native = [IntPtr]$box.Current.NativeWindowHandle
    if ($native -ne [IntPtr]::Zero -and [DeloDialog]::SelectCombo($native, $Value)) {
        Start-Sleep -Milliseconds 350
        return
    }
    $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $optionKey = "name=$Value"
    $item = Wait-WizardControl $Kind $optionKey 'ListItem' 6
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $expand = $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($expand.Current.ExpandCollapseState -eq [Windows.Automation.ExpandCollapseState]::Expanded) {
        $expand.Collapse()
    }
}

function Test-WizardText([Windows.Automation.AutomationElement]$Window, [string]$Pattern) {
    if (!$Window) { return $false }
    foreach ($item in $Window.FindAll($treeBelow, $allElements)) {
        if (!$item.Current.IsOffscreen -and $item.Current.Name -match $Pattern) { return $true }
    }
    $false
}

function Show-DatabaseInstructions([string]$Server, [string]$Owner, [pscredential]$Sa, [pscredential]$Admin) {
    Write-Host "Мастер БД: MS SQL Server (Microsoft OLE DB) → Создание БД ДЕЛО 22.2."
    Write-Host "Сервер $Server. Пользователь SA. Владелец будущей базы $Owner."
    $null = Read-Host 'Нажмите Enter, чтобы скопировать пароль SA'
    $Sa.GetNetworkCredential().Password | Set-Clipboard
    $null = Read-Host 'После проверки соединения вернитесь сюда и нажмите Enter, чтобы скопировать пароль владельца'
    $Admin.GetNetworkCredential().Password | Set-Clipboard
    Write-Host 'Вставьте пароль владельца в оба поля. Оставьте размер и заполнение демоданными по умолчанию.'
    Write-Host 'На вопрос, прекращать ли создание базы из-за отсутствия SQL Server Agent, выберите «Нет».'
    $null = Read-Host 'Закройте мастер после успешного создания базы и нажмите Enter'
}

function Start-DatabaseWizard {
    param([string]$Root, [string]$Server, [string]$Owner, [pscredential]$Sa, [pscredential]$Admin, [switch]$Assist)
    if (Get-WizardWindow database) { throw 'Закройте уже открытый мастер баз данных.' }
    $directory = Join-Path $Root 'DBCreate'
    $wizard = Start-Process -FilePath (Join-Path $directory 'dbmaster.exe') -WorkingDirectory $directory -PassThru
    if ($Assist) { Show-DatabaseInstructions $Server $Owner $Sa $Admin; return }

    try {
        Invoke-WizardButton database '1001'
        Select-WizardOption database '1009' 'MS SQL Server (Microsoft OLE DB)'
        $tree = Wait-WizardControl database '1010' 'Tree'
        $nativeTree = [IntPtr]$tree.Current.NativeWindowHandle
        if ($nativeTree -eq [IntPtr]::Zero -or ![DeloDialog]::SelectSingleChild($nativeTree)) {
            $item = Wait-WizardControl database 'name=Создание БД ДЕЛО 22.2' 'TreeItem' 5
            $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        }
        Invoke-WizardButton database '1001'
        Set-WizardField database '1003' $Server
        Set-WizardField database '1006' 'SA'
        Set-WizardField database '1007' ($Sa.GetNetworkCredential().Password)
        Invoke-WizardButton database '1001'
        Set-WizardField database '1004' $Owner
        Set-WizardField database '1006' ($Admin.GetNetworkCredential().Password)
        Set-WizardField database '1008' ($Admin.GetNetworkCredential().Password)
        Invoke-WizardButton database '1001'
        $null = Wait-WizardControl database '1011' 'Edit'
        Invoke-WizardButton database '1001'
        $null = Wait-WizardControl database '1003' 'CheckBox'
        Invoke-WizardButton database '1001'
        $null = Wait-WizardControl database '2006' ''
        Invoke-WizardButton database '1001'
        $deadline = [DateTime]::UtcNow.AddMinutes(12)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($wizard.HasExited) { return }
            $window = Get-WizardWindow database
            if (Test-WizardText $window 'SQL Server Agent.*Прекратить установку БД') {
                Invoke-WizardButton database 'name=Нет'
            }
            if (Test-WizardText $window 'успешно завершен|успешно выполнен|Операция завершена|Выполнение операции завершено') {
                break
            }
            $protocol = Join-Path $directory "Создание БД\dbmaster_$Owner.log"
            if (Test-Path -LiteralPath $protocol) {
                if ((Get-Content -LiteralPath $protocol -Tail 16 -Encoding Default) -match 'Операция .*завершена') { return }
            }
            Start-Sleep -Seconds 2
        }
    } catch {
        $details = $_.Exception.GetType().Name
        if ($_.Exception -is [TimeoutException]) { $details = $_.Exception.Message }
        Write-Step "Мастер БД требует ручного завершения. $details"
        Show-DatabaseInstructions $Server $Owner $Sa $Admin
    }
}

function Show-WebInstructions([string]$Server, [string]$Owner, [pscredential]$Admin, [string]$SiteName, [string]$SiteUrl) {
    Write-Host 'Если открыто предупреждение, нажмите «ОК». На экране подключения заново введите данные и нажмите Tab после каждого поля.'
    Write-Host "Мастер сервера: MS SQL Server, сервер $Server и владелец $Owner."
    $null = Read-Host 'Нажмите Enter, чтобы скопировать пароль владельца базы'
    $Admin.GetNetworkCredential().Password | Set-Clipboard
    Write-Host "Оставьте стандартные компоненты. Выберите сайт $SiteName и имя приложения $Owner."
    Write-Host "На следующем экране включите «Изменить адрес» и введите $SiteUrl"
    $null = Read-Host 'Нажмите «Установить», дождитесь завершения, закройте мастер и нажмите Enter здесь'
}

function Close-CompletedDatabaseWizard([string]$Root, [string]$Owner) {
    $directory = Join-Path $Root 'DBCreate'
    $protocol = Join-Path $directory "Создание БД\dbmaster_$Owner.log"
    if (!(Test-Path -LiteralPath $protocol)) { return }
    $lines = [IO.File]::ReadAllLines($protocol, [Text.Encoding]::GetEncoding(1251))
    if (!($lines | Select-Object -Last 16 | Where-Object { $_ -match 'Операция .*завершена' })) { return }

    $program = Join-Path $directory 'dbmaster.exe'
    foreach ($process in @(Get-Process -Name dbmaster -ErrorAction SilentlyContinue)) {
        if ($process.Path -ine $program) { continue }
        $null = $process.CloseMainWindow()
        if (!$process.WaitForExit(2000)) {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        }
        Write-Step 'Завершённое окно мастера базы закрыто.'
    }
}

function Start-VendorWebSetup([string]$Root, [string]$Server, [string]$Owner, [string]$SiteUrl) {
    $directory = Join-Path $Root 'ServerSetup'
    $setup = Join-Path $directory 'setup.exe'
    # Non-secret values go straight to Windows Installer, before its edit controls exist.
    $properties = "DBTYPE=MSS DBSERVERNAME=$Server DBOWNER=$Owner DELOWEBAPPNAME=$Owner DELOWEBURLCHANGE=1 DELOWEBURLCHANGED=$SiteUrl"
    Start-Process -FilePath $setup -ArgumentList ('/v"' + $properties + '"') -WorkingDirectory $directory -PassThru
}

function Get-SavedWebWizard([Windows.Automation.AutomationElement]$Window, [string]$State) {
    if (!$Window -or !(Test-Path -LiteralPath $State)) { return }
    $processId = $Window.Current.ProcessId
    if (!$processId) { return }
    $current = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (!$current) { return }
    $saved = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved -and $saved.Id -eq $current.Id -and $saved.StartTicks -eq $current.StartTime.ToUniversalTime().Ticks) {
        @{ Process = $current; PropertiesPreset = [bool]($saved.PSObject.Properties['PropertiesPreset'] -and $saved.PropertiesPreset) }
    }
}

function Close-WebWizardBeforeInstall([Windows.Automation.AutomationElement]$Window, [Diagnostics.Process]$Process) {
    if (!(Test-WizardText $Window 'Вас приветствует программа установки|Сервер базы данных|Не задано поле')) { return $false }
    $null = $Process.CloseMainWindow()
    if (!$Process.WaitForExit(1600)) { Stop-Process -Id $Process.Id }
    $true
}

function Close-CompletedWebWizard {
    $window = Get-WizardWindow web
    if (!(Get-SavedWebWizard $window (Join-Path $stateRoot 'web-wizard.json'))) { return $false }
    foreach ($caption in 'Готово', '&Готово', 'Завершить', '&Завершить', 'Закрыть', '&Закрыть') {
        if (Find-WizardControl $window "name=$caption" 'Button') {
            Invoke-WizardButton web "name=$caption"
            return $true
        }
    }
    $false
}

function Get-WebWizardStage([Windows.Automation.AutomationElement]$Window, [array]$Pages) {
    if (Test-WizardText $Window 'Не задано поле') {
        throw [TimeoutException]::new('Мастер отклонил заполненные реквизиты. Закройте предупреждение и заполните поля вручную.')
    }
    for ($step = $Pages.Count - 1; $step -ge 1; $step--) {
        if (Find-WizardControl $Window $Pages[$step][0] $Pages[$step][1]) { return $step }
    }
    if (Test-WizardText $Window '^Вас приветствует программа установки') { return 0 }
    foreach ($control in $Window.FindAll($treeBelow, $allElements)) {
        if (!$control.Current.IsOffscreen -and
            ([DeloDialog]::WindowClass([IntPtr]$control.Current.NativeWindowHandle) -eq 'msctls_progress32' -or
                $control.Current.Name -match '^(?:&)?(?:Готово|Завершить|Закрыть)$')) { return $Pages.Count }
    }
    throw [TimeoutException]::new('Текущий экран мастера требует ручного продолжения.')
}

function Start-WebWizard {
    param([string]$Root, [string]$Server, [string]$Owner, [pscredential]$Admin, [string]$SiteName, [string]$SiteUrl, [switch]$Assist)
    $state = Join-Path $stateRoot 'web-wizard.json'
    $window = Get-WizardWindow web
    $wizard = $null
    $propertiesPreset = $false
    if ($window) {
        $saved = Get-SavedWebWizard $window $state
        if (!$saved) {
            throw 'Открыт мастер серверной части от другого запуска. Закройте его и снова запустите обновлённый установщик.'
        }
        $propertiesPreset = $saved.PropertiesPreset
        if (!$propertiesPreset -and (Close-WebWizardBeforeInstall $window $saved.Process)) {
            $window = $null
            Write-Step 'Предыдущий мастер остановился на вводе реквизитов. Открываю форму с заданными параметрами.'
        } else {
            $script:webWizardProcessId = $saved.Process.Id
            Write-Step 'Продолжаю работу с открытым мастером серверной части.'
        }
    }
    if (!$window) {
        $wizard = Start-VendorWebSetup $Root $Server $Owner $SiteUrl
        $propertiesPreset = $true
        try {
            $firstButton = Wait-WizardControl web '15447' 'Button'
            $current = Get-Process -Id $firstButton.Current.ProcessId
            @{
                Id = $current.Id
                StartTicks = $current.StartTime.ToUniversalTime().Ticks
                PropertiesPreset = $propertiesPreset
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $state -Encoding UTF8
            $script:webWizardProcessId = $current.Id
            $window = Get-WizardWindow web
        } catch {
            if (!$Assist) { Write-Step 'Не удалось автоматически открыть форму мастера серверной части.' }
            Show-WebInstructions $Server $Owner $Admin $SiteName $SiteUrl
            return
        }
    }

    try {
        if ($Assist) { Show-WebInstructions $Server $Owner $Admin $SiteName $SiteUrl; return }
        $pages = @(
            @('15447', 'Button'), @('15465', 'Edit'), @('15525', 'Edit'), @('15559', 'Tree'),
            @('15611', 'ComboBox'), @('15600', 'CheckBox'), @('15589', 'Button')
        )
        $start = Get-WebWizardStage $window $pages
        for ($step = $start; $step -lt $pages.Count; $step++) {
            $null = Wait-WizardControl web $pages[$step][0] $pages[$step][1]
            switch ($step) {
                1 {
                    if (!$propertiesPreset) {
                        Set-WizardField web '15465' $Server
                        Set-WizardField web '15470' $Owner
                    }
                    Set-WizardField web '15474' ($Admin.GetNetworkCredential().Password)
                }
                4 { Select-WizardOption web '15611' $SiteName }
                5 {
                    $box = Wait-WizardControl web '15600' 'CheckBox'
                    $native = [IntPtr]$box.Current.NativeWindowHandle
                    if ($native -eq [IntPtr]::Zero -or ![DeloDialog]::Check($native)) {
                        $toggle = $box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
                        if ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) { $toggle.Toggle() }
                    }
                    Set-WizardField web '15606' $SiteUrl
                }
            }
            $button = if ($step -eq $pages.Count - 1) { '15589' } else { '15447' }
            Invoke-WizardButton web $button
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(12)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ((Test-WebReady) -and (Close-CompletedWebWizard)) { return }
            if ((!$wizard -or $wizard.HasExited) -and !(Get-WizardWindow web)) { return }
            Start-Sleep -Seconds 3
        }
    } catch {
        $details = $_.Exception.GetType().Name
        if ($_.Exception -is [TimeoutException]) { $details = $_.Exception.Message }
        Write-Step "Мастер сервера требует ручного завершения. $details"
        Show-WebInstructions $Server $Owner $Admin $SiteName $SiteUrl
    } finally {
        $script:webWizardProcessId = $null
    }
}
