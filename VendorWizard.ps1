Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
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
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern int GetLocaleInfoEx(string localeName, uint type, StringBuilder value, int capacity);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool SetLocaleInfoW(uint locale, uint type, string value);

    public static string GetShortDate() {
        const uint shortDate = 0x1f;
        var value = new StringBuilder(100);
        if (GetLocaleInfoEx(null, shortDate, value, value.Capacity) == 0) throw new Win32Exception();
        return value.ToString();
    }

    public static void SetShortDate(string value) {
        const uint userDefault = 0x400;
        const uint shortDate = 0x1f;
        if (!SetLocaleInfoW(userDefault, shortDate, value)) throw new Win32Exception();
        IntPtr result;
        SendMessageTimeout(new IntPtr(0xffff), 0x001a, IntPtr.Zero, "intl", 2, 1000, out result);
    }

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

function Get-WizardWindow([string]$Kind, [int]$WebProcessId = $script:webWizardProcessId) {
    foreach ($window in $uia::RootElement.FindAll($treeChildren, $allElements)) {
        try {
            $properties = $window.Current
            $windowProcessId = $properties.ProcessId
            if (!$windowProcessId) { continue }
            $title = $properties.Name
            $process = Get-Process -Id $windowProcessId -ErrorAction SilentlyContinue
            if (!$process) { continue }
            if (($Kind -eq 'database' -and $process.ProcessName -eq 'dbmaster' -and $title -like 'Мастер баз данных*') -or
                ($Kind -eq 'web' -and $title -like 'ДЕЛО (серверная часть)*' -and
                    (($WebProcessId -and $process.Id -eq $WebProcessId) -or (!$WebProcessId -and $process.ProcessName -eq 'msiexec')))) {
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

function Wait-WizardControl([string]$Kind, [string]$Key, [string]$Type, [int]$Seconds = 45) {
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

function Close-SetupWizardProcess([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    $null = $Process.CloseMainWindow()
    if (!$Process.WaitForExit(2000)) { Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue }
}

function Start-DatabaseWizard {
    param([string]$Root, [string]$Server, [string]$Owner, [pscredential]$Sa, [pscredential]$Admin, [switch]$Assist)
    if (Get-WizardWindow database) { throw 'Закройте уже открытый мастер баз данных.' }
    $directory = Join-Path $Root 'DBCreate'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $wizard = Start-Process -FilePath (Join-Path $directory 'dbmaster.exe') -WorkingDirectory $directory -PassThru
        if ($Assist) { Show-DatabaseInstructions $Server $Owner $Sa $Admin; return }
        $creating = $false
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
            $creating = $true
            Invoke-WizardButton database '1001'
            $deadline = [DateTime]::UtcNow.AddMinutes(30)
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($wizard.HasExited) { return }
                $window = Get-WizardWindow database
                if (Test-WizardText $window 'SQL Server Agent.*Прекратить установку БД') {
                    Invoke-WizardButton database 'name=Нет'
                }
                if (Test-WizardText $window 'успешно завершен|успешно выполнен|Операция завершена|Выполнение операции завершено') {
                    return
                }
                $protocol = Join-Path $directory "Создание БД\dbmaster_$Owner.log"
                if (Test-Path -LiteralPath $protocol) {
                    if ((Get-Content -LiteralPath $protocol -Tail 16 -Encoding Default) -match 'Операция .*завершена') { return }
                }
                Start-Sleep -Seconds 2
            }
            throw [TimeoutException]::new('Истекло время создания базы.')
        } catch {
            $details = $_.Exception.Message
            if ($creating -or $attempt -eq 2) { throw "Не завершилось автоматическое создание базы. $details" }
            Close-SetupWizardProcess $wizard
            Write-Step "Повторно открываю мастер базы. $details"
        }
    }
}

function Show-WebInstructions([string]$Server, [string]$Owner, [string]$SiteName, [string]$SiteUrl) {
    Write-Host 'Если мастер просит пароль, закройте предупреждение и вставьте пароль из файла «Дело - вход.txt» рядом с EXE. Затем нажмите Tab.'
    Write-Host "Мастер сервера: MS SQL Server, сервер $Server и владелец $Owner."
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
        Close-SetupWizardProcess $process
        Write-Step 'Завершённое окно мастера базы закрыто.'
    }
}

function Start-VendorWebSetup([string]$Root, [string]$Server, [string]$Owner, [string]$SiteUrl) {
    $directory = Join-Path $Root 'ServerSetup'
    $worker = Join-Path $PSScriptRoot 'Run-WebMsi.ps1'
    $package = Join-Path $directory 'setup.msi'
    $credential = Join-Path $stateRoot "$Owner.xml"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $worker + '"'),
        ('"' + $package + '"'), ('"' + $credential + '"'), $Server, $Owner, $SiteUrl)
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments `
        -WorkingDirectory $directory -PassThru -WindowStyle Hidden
}

function Get-SavedWebWizardProcess([string]$State) {
    if (!(Test-Path -LiteralPath $State)) { return }
    try {
        $saved = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
        if (!$saved -or !$saved.PSObject.Properties['Id'] -or !$saved.PSObject.Properties['StartTicks']) { return }
        $current = Get-Process -Id $saved.Id -ErrorAction SilentlyContinue
        if ($current -and $current.ProcessName -in 'msiexec', 'powershell' -and
            $saved.StartTicks -eq $current.StartTime.ToUniversalTime().Ticks) { $current }
    } catch { return }
}

function Test-WebWizardMissingField([Windows.Automation.AutomationElement]$Window) {
    if (!$Window) { return $false }
    $processId = $Window.Current.ProcessId
    foreach ($candidate in $uia::RootElement.FindAll($treeChildren, $allElements)) {
        if ($candidate.Current.ProcessId -eq $processId -and
            (Test-WizardText $candidate 'Не задано поле')) { return $true }
    }
    $false
}

function Close-WebWizardBeforeInstall([Windows.Automation.AutomationElement]$Window, [Diagnostics.Process]$Process) {
    if (!(Test-WizardText $Window 'Вас приветствует программа установки|Сервер базы данных') -and
        !(Test-WebWizardMissingField $Window)) { return $false }
    Close-SetupWizardProcess $Process
    $true
}

function Close-CompletedWebWizard {
    $wizard = Get-SavedWebWizardProcess (Join-Path $stateRoot 'web-wizard.json')
    if (!$wizard) { return $false }
    $window = Get-WizardWindow web $wizard.Id
    foreach ($caption in 'Готово', '&Готово', 'Завершить', '&Завершить', 'Закрыть', '&Закрыть') {
        $finish = Find-WizardControl $window "name=$caption" 'Button'
        if ($finish) { return [DeloDialog]::Click([IntPtr]$finish.Current.NativeWindowHandle) }
    }
    $false
}

function Get-WebWizardStage([Windows.Automation.AutomationElement]$Window, [array]$Pages) {
    if (Test-WebWizardMissingField $Window) {
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

function Invoke-WebWizard {
    param([string]$Root, [string]$Server, [string]$Owner, [pscredential]$Admin, [string]$SiteName, [string]$SiteUrl, [switch]$Assist)
    $state = Join-Path $stateRoot 'web-wizard.json'
    $wizard = Get-SavedWebWizardProcess $state
    $window = if ($wizard) { Get-WizardWindow web $wizard.Id }
    if (!$window -and (Get-WizardWindow web 0)) {
        throw 'Открыт мастер серверной части от другого запуска. Закройте его и снова запустите обновлённый установщик.'
    }
    if ($window -and $wizard.ProcessName -eq 'msiexec' -and (Close-WebWizardBeforeInstall $window $wizard)) {
        $window = $null
        $wizard = $null
        Write-Step 'Открываю обновлённый мастер с реквизитами подключения.'
    }
    if (!$window -and (!$wizard -or $wizard.ProcessName -eq 'msiexec')) {
        $wizard = Start-VendorWebSetup $Root $Server $Owner $SiteUrl
        @{ Id = $wizard.Id; StartTicks = $wizard.StartTime.ToUniversalTime().Ticks } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $state -Encoding UTF8
    } else {
        Write-Step 'Продолжаю работу с открытым мастером серверной части.'
    }
    $script:webWizardProcessId = $wizard.Id
    $nativeBootstrap = $wizard.ProcessName -eq 'powershell'
    try {
        if (!$window) {
            $null = Wait-WizardControl web '15447' 'Button'
            $window = Get-WizardWindow web
        }
        if ($Assist) { Show-WebInstructions $Server $Owner $SiteName $SiteUrl; return }
        $pages = @(
            @('15447', 'Button'), @('15465', 'Edit'), @('15525', 'Edit'), @('15559', 'Tree'),
            @('15611', 'ComboBox'), @('15600', 'CheckBox'), @('15589', 'Button')
        )
        $start = Get-WebWizardStage $window $pages
        for ($step = $start; $step -lt $pages.Count; $step++) {
            $null = Wait-WizardControl web $pages[$step][0] $pages[$step][1]
            switch ($step) {
                1 {
                    if (!$nativeBootstrap) {
                        Set-WizardField web '15465' $Server
                        Set-WizardField web '15470' $Owner
                        Set-WizardField web '15474' ($Admin.GetNetworkCredential().Password)
                    }
                }
                4 { Select-WizardOption web '15611' $SiteName }
                5 {
                    $box = Wait-WizardControl web '15600' 'CheckBox'
                    $native = [IntPtr]$box.Current.NativeWindowHandle
                    if ($native -eq [IntPtr]::Zero -or ![DeloDialog]::Check($native)) {
                        $toggle = $box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
                        if ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) { $toggle.Toggle() }
                    }
                    if (!$nativeBootstrap) { Set-WizardField web '15606' $SiteUrl }
                }
            }
            $button = if ($step -eq $pages.Count - 1) { '15589' } else { '15447' }
            Invoke-WizardButton web $button
            if ($step -eq 1 -and (Test-WebWizardMissingField (Get-WizardWindow web))) {
                throw [TimeoutException]::new('Мастер не сохранил реквизиты подключения.')
            }
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ((Test-WebReady) -and (Close-CompletedWebWizard)) { return }
            if ($wizard.HasExited -and !(Get-WizardWindow web)) {
                if ($nativeBootstrap -and $wizard.ExitCode -eq 3010) { Require-Restart }
                if ($nativeBootstrap -and $wizard.ExitCode -ne 0) {
                    throw "Мастер серверной части закрылся. Код Windows Installer: $($wizard.ExitCode)."
                }
                return
            }
            Start-Sleep -Seconds 3
        }
    } catch {
        if ($wizard.HasExited) {
            throw "Мастер серверной части закрылся. Код Windows Installer: $($wizard.ExitCode)."
        }
        $details = $_.Exception.GetType().Name
        if ($_.Exception -is [TimeoutException]) { $details = $_.Exception.Message }
        throw "Не завершилась автоматическая установка ДЕЛО-Web. $details"
    } finally {
        $script:webWizardProcessId = $null
    }
}

function Start-WebWizard {
    param([string]$Root, [string]$Server, [string]$Owner, [pscredential]$Admin, [string]$SiteName, [string]$SiteUrl, [switch]$Assist)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-WebWizard $Root $Server $Owner $Admin $SiteName $SiteUrl -Assist:$Assist
            return
        } catch {
            if ($Assist -or $attempt -eq 2) { throw }
            $wizard = Get-SavedWebWizardProcess (Join-Path $stateRoot 'web-wizard.json')
            $window = if ($wizard) { Get-WizardWindow web $wizard.Id }
            if (!$window -or !(Close-WebWizardBeforeInstall $window $wizard)) { throw }
            Write-Step 'Повторно открываю мастер серверной части с параметрами подключения.'
        }
    }
}
