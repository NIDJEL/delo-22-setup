using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("Установщик ДЕЛО 22.2")]
[assembly: AssemblyDescription("Локальная учебная установка ДЕЛО 22.2")]
[assembly: AssemblyFileVersion("0.3.0.0")]
[assembly: AssemblyVersion("0.3.0.0")]

internal static class DeloSetup
{
    private static readonly string[] Resources =
    {
        "Install-Delo.ps1",
        "VendorWizard.ps1",
        "Uninstall-Delo.ps1",
        "VendorFiles.json"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        int exitCode = 1;
        try
        {
            Console.Title = "Установка ДЕЛО 22.2";
            Console.OutputEncoding = Encoding.UTF8;
            exitCode = RunInstaller(args);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Не удалось запустить установку. " + error.Message);
        }

        if (exitCode != 0 && !Console.IsInputRedirected)
        {
            Console.WriteLine("Нажмите Enter, чтобы закрыть установщик.");
            Console.ReadLine();
        }
        return exitCode;
    }

    private static int RunInstaller(string[] args)
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
                "-InstallerDirectory", installerDirectory
            };
            var start = new ProcessStartInfo {
                FileName = Path.Combine(powerShellDirectory, "powershell.exe"),
                Arguments = string.Join(" ", parameters.Concat(args).Select(QuoteArgument)),
                WorkingDirectory = installerDirectory,
                UseShellExecute = false
            };
            start.EnvironmentVariables["PSModulePath"] = Path.Combine(powerShellDirectory, "Modules") +
                ";" + Path.Combine(programFiles, @"WindowsPowerShell\Modules");
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
