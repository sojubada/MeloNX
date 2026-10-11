using System;
using System.Threading;

namespace Ryujinx.Memory
{
    public static class MemoryReclaim
    {
        private static long _guestPhysicalBytes;
        private static long _privateAllocatorBytes;

        /// <summary>
        /// Whether freed guest physical pages should be decommitted from the backing DRAM block.
        /// </summary>
        public static bool GuestPhysicalEnabled { get; set; } = OperatingSystem.IsIOS();

        /// <summary>
        /// Smallest DRAM range worth decommitting. Decommitting costs a couple of syscalls and
        /// splits the host VM map, so small frees are not worth chasing - the guest page heap
        /// reuses them soon enough anyway.
        /// </summary>
        public static ulong GuestPhysicalMinimumSize { get; set; } = 2UL * 1024 * 1024;

        /// <summary>
        /// Whether free ranges inside partially used private allocator blocks should be discarded.
        /// </summary>
        public static bool PrivateAllocatorEnabled { get; set; } = OperatingSystem.IsIOS();

        /// <summary>
        /// Smallest private allocator range worth discarding. Defaults to a single host page:
        /// private allocations are host page granular to begin with, and every one of them held is
        /// real dirty memory, so there is little point holding out for a larger range.
        /// </summary>
        public static ulong PrivateAllocatorMinimumSize { get; set; } = MemoryBlock.GetPageSize();

        /// <summary>
        /// Total guest physical memory decommitted since startup, in bytes.
        /// </summary>
        public static ulong GuestPhysicalBytes => (ulong)Interlocked.Read(ref _guestPhysicalBytes);

        /// <summary>
        /// Total private allocator memory discarded since startup, in bytes.
        /// </summary>
        public static ulong PrivateAllocatorBytes => (ulong)Interlocked.Read(ref _privateAllocatorBytes);

        public static void AddGuestPhysicalBytes(ulong size)
        {
            Interlocked.Add(ref _guestPhysicalBytes, (long)size);
        }

        public static void AddPrivateAllocatorBytes(ulong size)
        {
            Interlocked.Add(ref _privateAllocatorBytes, (long)size);
        }
    }
}
