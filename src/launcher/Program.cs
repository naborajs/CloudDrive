using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace NSCloudDrive.Launcher
{
    static class Program
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("shell32.dll", SetLastError = true)]
        private static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);

        [DllImport("psapi.dll")]
        private static extern int EmptyWorkingSet(IntPtr hwProc);

        private const int SW_RESTORE = 9;
        private const int SW_SHOW = 5;
        private const string AppUserModelId = "NSCloud.NSCloudDrive";
        private const string MutexName = "Local\\NSCloudDrive_AppMutex";
        private const string RestoreEventName = "Local\\NSCloudDrive_RestoreWindow_Event";
        private const string WindowTitle = "NS Cloud Drive - Developed by NABORAJ SARKAR";

        static Program()
        {
            AppDomain.CurrentDomain.AssemblyResolve += (sender, args) =>
            {
                try
                {
                    string asmName = new AssemblyName(args.Name).Name;
                    string simpleName = asmName + ".dll";
                    string psDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32\\WindowsPowerShell\\v1.0");
                    string candidate = Path.Combine(psDir, simpleName);
                    if (File.Exists(candidate))
                    {
                        return Assembly.LoadFrom(candidate);
                    }

                    string gacBase = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Microsoft.NET\\assembly\\GAC_MSIL", asmName);
                    if (Directory.Exists(gacBase))
                    {
                        string[] files = Directory.GetFiles(gacBase, "*.dll", SearchOption.AllDirectories);
                        if (files.Length > 0)
                        {
                            return Assembly.LoadFrom(files[0]);
                        }
                    }
                }
                catch { }
                return null;
            };
        }

        [STAThread]
        static int Main(string[] args)
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
            }
            catch { }

            // 1. Single Instance Check & Foreground Activation
            bool createdNew = false;
            Mutex appMutex = null;

            try
            {
                appMutex = new Mutex(true, MutexName, out createdNew);
            }
            catch (AbandonedMutexException)
            {
                createdNew = true;
            }
            catch
            {
                createdNew = true;
            }

            if (!createdNew)
            {
                ActivateExistingInstance();
                if (appMutex != null)
                {
                    appMutex.Close();
                }
                return 0;
            }

            try
            {
                // 2. Resolve script path
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(baseDir, "src", "NSCloudDrive.ps1");

                if (!File.Exists(scriptPath))
                {
                    string fallback = Path.Combine(baseDir, "NSCloudDrive.ps1");
                    if (File.Exists(fallback))
                    {
                        scriptPath = fallback;
                    }
                    else
                    {
                        MessageBox.Show(
                            string.Format("Could not find application script at:\n{0}\n\nPlease ensure the application files are intact.", scriptPath),
                            "NS Cloud Drive - Error",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Error);
                        return 1;
                    }
                }

                // 3. Execute in-process as native NSCloudDrive.exe host
                try
                {
                    return RunInProcess(scriptPath, args);
                }
                catch (Exception ex)
                {
                    try
                    {
                        string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NSCloudDrive\\logs");
                        if (!Directory.Exists(logDir)) Directory.CreateDirectory(logDir);
                        File.AppendAllText(Path.Combine(logDir, "launcher-error.log"), DateTime.UtcNow.ToString("o") + " [InProcess Exception]: " + ex.ToString() + Environment.NewLine);
                    }
                    catch { }

                    return RunOutOfProcess(scriptPath, baseDir, args);
                }
            }
            finally
            {
                if (appMutex != null)
                {
                    try
                    {
                        appMutex.ReleaseMutex();
                    }
                    catch { }
                    appMutex.Close();
                }
            }
        }

        private static int RunInProcess(string scriptPath, string[] args)
        {
            InitialSessionState initial = InitialSessionState.CreateDefault();
            initial.ApartmentState = ApartmentState.STA;
            initial.ThreadOptions = PSThreadOptions.ReuseThread;
            initial.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

            using (Runspace rs = RunspaceFactory.CreateRunspace(initial))
            {
                rs.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(scriptPath);

                    if (args != null && args.Length > 0)
                    {
                        for (int i = 0; i < args.Length; i++)
                        {
                            string a = args[i];
                            if (string.Equals(a, "-Minimized", StringComparison.OrdinalIgnoreCase) ||
                                string.Equals(a, "/Minimized", StringComparison.OrdinalIgnoreCase))
                            {
                                ps.AddParameter("Minimized", true);
                            }
                            else if (a.StartsWith("-") || a.StartsWith("/"))
                            {
                                string paramName = a.TrimStart('-', '/');
                                if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                                {
                                    ps.AddParameter(paramName, args[i + 1]);
                                    i++;
                                }
                                else
                                {
                                    ps.AddParameter(paramName, true);
                                }
                            }
                            else
                            {
                                ps.AddArgument(a);
                            }
                        }
                    }

                    ps.Invoke();

                    if (ps.HadErrors)
                    {
                        try
                        {
                            string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NSCloudDrive\\logs");
                            if (!Directory.Exists(logDir)) Directory.CreateDirectory(logDir);
                            StringBuilder sb = new StringBuilder();
                            foreach (var err in ps.Streams.Error)
                            {
                                sb.AppendLine(err.ToString());
                            }
                            File.AppendAllText(Path.Combine(logDir, "launcher-error.log"), DateTime.UtcNow.ToString("o") + " [PowerShell Errors]: " + sb.ToString() + Environment.NewLine);
                        }
                        catch { }
                    }

                    return 0;
                }
            }
        }

        private static int RunOutOfProcess(string scriptPath, string baseDir, string[] args)
        {
            string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string psExe = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

            if (!File.Exists(psExe))
            {
                psExe = "powershell.exe";
            }

            StringBuilder argBuilder = new StringBuilder();
            argBuilder.Append("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"");
            argBuilder.Append(scriptPath);
            argBuilder.Append("\"");

            if (args != null && args.Length > 0)
            {
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    if (!string.IsNullOrEmpty(a))
                    {
                        argBuilder.Append(" ");
                        if (a.Contains(" ") || a.Contains("\""))
                        {
                            argBuilder.Append("\"");
                            argBuilder.Append(a.Replace("\"", "\\\""));
                            argBuilder.Append("\"");
                        }
                        else
                        {
                            argBuilder.Append(a);
                        }
                    }
                }
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = psExe;
            psi.Arguments = argBuilder.ToString();
            psi.WorkingDirectory = baseDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            using (Process childProcess = Process.Start(psi))
            {
                if (childProcess == null)
                {
                    return 1;
                }
                try
                {
                    EmptyWorkingSet(Process.GetCurrentProcess().Handle);
                }
                catch { }

                childProcess.WaitForExit();
                return childProcess.ExitCode;
            }
        }

        private static void ActivateExistingInstance()
        {
            try
            {
                using (EventWaitHandle restoreEvent = EventWaitHandle.OpenExisting(RestoreEventName))
                {
                    restoreEvent.Set();
                }
            }
            catch { }

            try
            {
                IntPtr hWnd = FindWindow(null, WindowTitle);
                if (hWnd != IntPtr.Zero)
                {
                    if (IsIconic(hWnd))
                    {
                        ShowWindowAsync(hWnd, SW_RESTORE);
                    }
                    else
                    {
                        ShowWindowAsync(hWnd, SW_SHOW);
                    }
                    SetForegroundWindow(hWnd);
                }
            }
            catch { }
        }
    }
}
