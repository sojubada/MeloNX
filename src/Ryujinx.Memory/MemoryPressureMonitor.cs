using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Memory
{
    /// <summary>
    /// How badly the host wants memory back.
    /// </summary>
    public enum MemoryPressureLevel
    {
        /// <summary>
        /// No pressure, or none reported since the last time it was consumed.
        /// </summary>
        Normal = 0,

        /// <summary>
        /// The host is short on memory. Give back what is cheap to rebuild.
        /// </summary>
        Warning = 1,

        /// <summary>
        /// The process is about to be killed. Give back everything that can be given back.
        /// </summary>
        Critical = 2,
    }

    /// <summary>
    /// Watches the host for memory pressure and records the worst level seen.
    /// </summary>
    public static partial class MemoryPressureMonitor
    {
        private const nuint DispatchMemoryPressureWarn = 0x02;
        private const nuint DispatchMemoryPressureCritical = 0x04;

        private const long DispatchQueuePriorityDefault = 0;

        [LibraryImport("libSystem.dylib", EntryPoint = "dispatch_source_create")]
        private static partial nint DispatchSourceCreate(nint type, nuint handle, nuint mask, nint queue);

        [LibraryImport("libSystem.dylib", EntryPoint = "dispatch_source_set_event_handler_f")]
        private static partial void DispatchSourceSetEventHandler(nint source, nint handler);

        [LibraryImport("libSystem.dylib", EntryPoint = "dispatch_source_get_data")]
        private static partial nuint DispatchSourceGetData(nint source);

        [LibraryImport("libSystem.dylib", EntryPoint = "dispatch_get_global_queue")]
        private static partial nint DispatchGetGlobalQueue(long identifier, nuint flags);

        [LibraryImport("libSystem.dylib", EntryPoint = "dispatch_resume")]
        private static partial void DispatchResume(nint obj);

        private static int _pendingLevel;
        private static int _started;

        private static nint _source;
        
        public static event Action<MemoryPressureLevel> PressureChanged;
        public static bool IsSupported => OperatingSystem.IsIOS() || OperatingSystem.IsMacOS();

        /// <summary>
        /// Begins watching for pressure. Safe to call more than once; only the first call does
        /// anything. Failure to subscribe is not fatal - it just means nothing will be trimmed
        /// ahead of the host running out.
        /// </summary>
        /// <returns>True if the monitor is running, false if it could not be started</returns>
        public static bool Start()
        {
            if (!IsSupported)
            {
                return false;
            }

            if (Interlocked.Exchange(ref _started, 1) != 0)
            {
                return _source != nint.Zero;
            }

            try
            {
                if (!NativeLibrary.TryLoad("libSystem.dylib", out nint libSystem) ||
                    !NativeLibrary.TryGetExport(libSystem, "_dispatch_source_type_memorypressure", out nint sourceType))
                {
                    return false;
                }

                nint queue = DispatchGetGlobalQueue(DispatchQueuePriorityDefault, 0);

                nint source = DispatchSourceCreate(
                    sourceType,
                    0,
                    DispatchMemoryPressureWarn | DispatchMemoryPressureCritical,
                    queue);

                if (source == nint.Zero)
                {
                    return false;
                }

                unsafe
                {
                    DispatchSourceSetEventHandler(source, (nint)(delegate* unmanaged<nint, void>)&OnPressure);
                }

                _source = source;

                // Dispatch sources are created suspended.
                DispatchResume(source);

                return true;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
            {
                return false;
            }
        }

        [UnmanagedCallersOnly]
        private static void OnPressure(nint context)
        {
            nuint data = DispatchSourceGetData(_source);

            MemoryPressureLevel level = (data & DispatchMemoryPressureCritical) != 0
                ? MemoryPressureLevel.Critical
                : MemoryPressureLevel.Warning;

            int current;

            do
            {
                current = Volatile.Read(ref _pendingLevel);

                if (current >= (int)level)
                {
                    break;
                }
            }
            while (Interlocked.CompareExchange(ref _pendingLevel, (int)level, current) != current);

            PressureChanged?.Invoke(level);
        }

        /// <summary>
        /// Takes the worst pressure level reported since this was last called, and clears it.
        /// Call from a thread that is allowed to act on it.
        /// </summary>
        public static MemoryPressureLevel ConsumePendingLevel()
        {
            return (MemoryPressureLevel)Interlocked.Exchange(ref _pendingLevel, (int)MemoryPressureLevel.Normal);
        }

        /// <summary>
        /// Reports pressure as though the host had asked for it. For the platform layer to call when it learns about pressure another way, such as a UIKit memory warning.
        /// </summary>
        public static void ReportPressure(MemoryPressureLevel level)
        {
            if (level == MemoryPressureLevel.Normal)
            {
                return;
            }

            int current;

            do
            {
                current = Volatile.Read(ref _pendingLevel);

                if (current >= (int)level)
                {
                    return;
                }
            }
            while (Interlocked.CompareExchange(ref _pendingLevel, (int)level, current) != current);

            PressureChanged?.Invoke(level);
        }
    }
}
