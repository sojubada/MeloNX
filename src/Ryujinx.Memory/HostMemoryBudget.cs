using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Memory
{
    public static partial class HostMemoryBudget
    {
        private const ulong MiB = 1024 * 1024;
        private const ulong MinimumPlausibleBudget = 512 * MiB;

        [LibraryImport("libSystem.dylib", EntryPoint = "os_proc_available_memory")]
        private static partial long OsProcAvailableMemory();

        [LibraryImport("libSystem.dylib", EntryPoint = "mach_task_self")]
        private static partial nint MachTaskSelf();

        [LibraryImport("libSystem.dylib", EntryPoint = "task_info")]
        private static unsafe partial int TaskInfo(nint task, uint flavor, ulong* info, uint* count);

        private const uint TaskVmInfo = 22;
        private const uint TaskVmInfoCount = 87;
        private const int PhysFootprintIndex = 144 / 8;

        private static long _cachedTotalBytes = -1;
        public static bool IsConstrained => OperatingSystem.IsIOS();
        
        public static ulong AvailableBytes
        {
            get
            {
                if (!OperatingSystem.IsIOS())
                {
                    return 0;
                }

                try
                {
                    long available = OsProcAvailableMemory();

                    return available > 0 ? (ulong)available : 0;
                }
                catch (EntryPointNotFoundException)
                {
                    return 0;
                }
            }
        }


        public static unsafe ulong FootprintBytes
        {
            get
            {
                if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsIOS())
                {
                    return 0;
                }

                try
                {
                    ulong* info = stackalloc ulong[(int)(TaskVmInfoCount / 2 + 1)];
                    uint count = TaskVmInfoCount;

                    if (TaskInfo(MachTaskSelf(), TaskVmInfo, info, &count) != 0)
                    {
                        return 0;
                    }

                    return info[PhysFootprintIndex];
                }
                catch (EntryPointNotFoundException)
                {
                    return 0;
                }
            }
        }


        public static ulong TotalBytes
        {
            get
            {
                long cached = Interlocked.Read(ref _cachedTotalBytes);

                if (cached >= 0)
                {
                    return (ulong)cached;
                }

                ulong total = 0;

                if (IsConstrained)
                {
                    ulong available = AvailableBytes;

                    if (available != 0)
                    {
                        total = Math.Max(FootprintBytes + available, MinimumPlausibleBudget);
                    }
                }

                Interlocked.Exchange(ref _cachedTotalBytes, (long)total);

                return total;
            }
        }

        public static ulong? GetShare(int divisor, ulong min, ulong max)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(divisor);

            ulong total = TotalBytes;

            if (total == 0)
            {
                return null;
            }

            return Math.Clamp(total / (ulong)divisor, min, max);
        }
    }
}
