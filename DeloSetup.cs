using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("Установщик ДЕЛО 22.2")]
[assembly: AssemblyDescription("Локальная учебная установка ДЕЛО 22.2")]
[assembly: AssemblyFileVersion("0.3.7.0")]
[assembly: AssemblyVersion("0.3.7.0")]

internal static class DeloSetup
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    private static readonly string[] Resources =
    {
        "Install-Delo.ps1",
        "VendorWizard.ps1",
        "Run-WebMsi.ps1",
        "Uninstall-Delo.ps1",
        "VendorFiles.json"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        bool background = false;
        bool showResult = false;
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
            IntPtr console = GetConsoleWindow();
            if (console != IntPtr.Zero) Console.Title = "Установка ДЕЛО 22.2";
            if (args.Length == 0 || (args.Length == 1 && args[0].Equals("-Menu", StringComparison.OrdinalIgnoreCase)))
            {
                Console.WriteLine("ДЕЛО 22.2");
                Console.WriteLine("1. Установить или продолжить");
                Console.WriteLine("2. Удалить ДЕЛО");
                Console.WriteLine("3. Открыть TXT с логином и паролем");
                Console.WriteLine("4. Запустить ДЕЛО-Web");
                Console.Write("Введите номер пункта: ");
                string choice = ReadMenuChoice();
                switch (choice)
                {
                    case "1":
                        return ShowResult(FollowInstallation());
                    case "2": args = new[] { "-Uninstall" }; break;
                    case "3": args = new[] { "-Credentials" }; break;
                    case "4": args = new[] { "-StartWeb" }; showResult = true; break;
                    default: return 0;
                }
            }
            background = args.Any(arg => arg.Equals("-Install", StringComparison.OrdinalIgnoreCase)) &&
                !args.Any(arg => arg.Equals("-ManualWizard", StringComparison.OrdinalIgnoreCase));
            int code = RunInstaller(args, background);
            return showResult ? ShowResult(code) : code;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Не удалось запустить установку. " + error.Message);
            if (background)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                File.AppendAllText(LogPath, "Не удалось запустить установку. " + error.Message + Environment.NewLine);
            }
            return 1;
        }
    }

    private static string LogPath
    {
        get
        {
            string folder = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(folder, "Delo22Lab-Setup", "setup.log");
        }
    }

    private static int FollowInstallation()
    {
        string path = LogPath;
        long position = File.Exists(path) ? new FileInfo(path).Length : 0;
        Console.WriteLine("Установка началась. Ход работы будет показан ниже.");
        var worker = new ProcessStartInfo {
            FileName = Assembly.GetExecutingAssembly().Location,
            Arguments = "-Install",
            CreateNoWindow = true,
            UseShellExecute = false
        };
        using (Process process = Process.Start(worker))
        {
            while (!process.WaitForExit(500)) ShowNewLogLines(path, ref position);
            ShowNewLogLines(path, ref position);
            return process.ExitCode;
        }
    }

    private static void ShowNewLogLines(string path, ref long position)
    {
        try
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (stream.Length < position) position = 0;
                long end = stream.Length;
                if (end == position) return;
                stream.Seek(position, SeekOrigin.Begin);
                byte[] data = new byte[end - position];
                int read = stream.Read(data, 0, data.Length);
                if (read == 0) return;
                int lastLine = Array.LastIndexOf(data, (byte)'\n', read - 1, read);
                if (lastLine < 0) return;
                Console.Write(Encoding.UTF8.GetString(data, 0, lastLine + 1).TrimStart('\uFEFF'));
                position += lastLine + 1;
            }
        }
        catch (IOException) { }
    }

    private static int ShowResult(int code)
    {
        if (code == 3010)
            Console.WriteLine("Требуется перезагрузка Windows.");
        else if (code != 0)
            Console.WriteLine("Операция завершилась с ошибкой. Журнал находится в " + LogPath);
        if (!Console.IsInputRedirected)
        {
            Console.Write("Нажмите Enter, чтобы закрыть окно: ");
            Console.ReadLine();
        }
        return code;
    }

    private static string ReadMenuChoice()
    {
        if (!Console.IsInputRedirected) return (Console.ReadLine() ?? "").Trim();
        // Leave any following lines for the PowerShell confirmation prompt.
        var line = new StringBuilder();
        Stream input = Console.OpenStandardInput();
        int value;
        while ((value = input.ReadByte()) >= 0 && value != '\n') line.Append((char)value);
        return line.ToString().Trim();
    }

    private static int RunInstaller(string[] args, bool background)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        string installerDirectory = Path.GetDirectoryName(assembly.Location);
        string staging = Path.Combine(Path.GetTempPath(), "Delo22Setup-" + Guid.NewGuid().ToString("N"));

        Directory.CreateDirectory(staging);
        try
        {
            foreach (string name in Resources)
            {
                using (Stream resource = assembly.GetManifestResourceStream(name))
                {
                    if (resource == null)
                        throw new InvalidOperationException("В установщике отсутствует " + name + ".");
                    using (FileStream file = new FileStream(Path.Combine(staging, name), FileMode.CreateNew))
                        resource.CopyTo(file);
                }
            }

            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powerShellDirectory = Path.Combine(windows, @"System32\WindowsPowerShell\v1.0");
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string[] parameters = {
                "-NoLogo", "-NoProfile", "-ExecutionPolicy", "RemoteSigned",
                "-File", Path.Combine(staging, "Install-Delo.ps1"),
                "-InstallerDirectory", installerDirectory,
                "-InstallerPath", assembly.Location
            };
            string powerShell = Path.Combine(powerShellDirectory, "powershell.exe");
            string arguments = string.Join(" ", parameters.Concat(args).Select(QuoteArgument));
            string modulePath = Path.Combine(powerShellDirectory, "Modules") +
                ";" + Path.Combine(programFiles, @"WindowsPowerShell\Modules");
            if (background)
            {
                Environment.SetEnvironmentVariable("PSModulePath", modulePath);
                return BackgroundDesktop.Run(powerShell, QuoteArgument(powerShell) + " " + arguments, installerDirectory);
            }
            var start = new ProcessStartInfo {
                FileName = powerShell,
                Arguments = arguments,
                WorkingDirectory = installerDirectory,
                UseShellExecute = false
            };
            start.EnvironmentVariables["PSModulePath"] = modulePath;
            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        finally
        {
            try
            {
                foreach (string name in Resources)
                    File.Delete(Path.Combine(staging, name));
                Directory.Delete(staging);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static string QuoteArgument(string value)
    {
        var quoted = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
                quoted.Append('\\', backslashes + 1);
            quoted.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }
        quoted.Append('\\', backslashes * 2).Append('"');
        return quoted.ToString();
    }
}
