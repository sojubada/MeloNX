using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;
using static Ryujinx.Memory.MemoryManagerUnixHelper;

namespace Ryujinx.Memory
{
    /// <summary>
    /// tvOS "RAM swap": backs the guest's private memory blocks (the bulk of a game's
    /// RAM, e.g. ~2.7 GB for Kirby) with unlinked files instead of anonymous memory.
    ///
    /// Apple TV has 4 GB and tvOS has no swap. Anonymous memory can only be compressed,
    /// and it counts against the app's footprint at full size. Pages of a shared file
    /// mapping are ordinary file cache instead: when RAM runs short the kernel writes
    /// them to the file and frees the RAM, and reads them back on the next access. So
    /// the flash storage acts as swap for guest RAM, and those pages leave the footprint.
    ///
    /// Each block is its own temporary file, unlinked as soon as it is created, so its
    /// disk space is returned when the block is unmapped or the app exits — nothing is
    /// left behind even after a crash. Semantics stay those of the anonymous blocks:
    /// a new file reads as zeros, views are made with vm_remap from the base mapping,
    /// and blocks are released with vm_deallocate.
    ///
    /// Enabled by the app with MELONX_GUEST_SWAP_DIR (the directory for the files);
    /// any failure falls back to anonymous memory.
    /// </summary>
    [SupportedOSPlatform("ios")]
    public static unsafe class GuestMemorySwap
    {
        /// <summary>Free space always left on the device, so games never fill the disk.</summary>
        private const long ReservedFreeSpace = 3L * 1024 * 1024 * 1024;

        private static readonly string _directory = InitDirectory();
        private static long _bytes;
        private static readonly ConcurrentDictionary<nint, ulong> _blocks = new();
        private static int _loggedFallback;

        public static bool Enabled => _directory != null;

        /// <summary>Total size of the guest memory currently backed by swap files.</summary>
        public static ulong Bytes => (ulong)Interlocked.Read(ref _bytes);

        private static string InitDirectory()
        {
            if (!OperatingSystem.IsTvOS())
            {
                return null;
            }

            string dir = Environment.GetEnvironmentVariable("MELONX_GUEST_SWAP_DIR");

            if (string.IsNullOrEmpty(dir))
            {
                return null;
            }

            try
            {
                Directory.CreateDirectory(dir);

                // Files are unlinked at creation; anything here is from a run killed
                // between creating and unlinking a file.
                foreach (string stale in Directory.GetFiles(dir, "guest-*"))
                {
                    File.Delete(stale);
                }

                return dir;
            }
            catch (Exception e)
            {
                Console.WriteLine($"[GuestMemorySwap] disabled: {e.Message}");
                return null;
            }
        }

        public static bool TryAllocate(ulong size, out nint address)
        {
            address = nint.Zero;

            if (_directory == null || size == 0)
            {
                return false;
            }

            try
            {
                long free = new DriveInfo(_directory).AvailableFreeSpace;

                // Sparse file: disk is only used for pages the kernel actually writes
                // out, but size the check for the whole block to be safe.
                if (free - (long)size < ReservedFreeSpace)
                {
                    LogFallbackOnce($"only {free / (1024 * 1024)} MB free on disk");
                    return false;
                }
            }
            catch
            {
                // Could not read free space: be safe and use anonymous memory.
                return false;
            }

            byte[] template = System.Text.Encoding.UTF8.GetBytes(Path.Combine(_directory, "guest-XXXXXX") + "\0");
            int fd;

            fixed (byte* pTemplate = template)
            {
                fd = mkstemp((nint)pTemplate);

                if (fd == -1)
                {
                    LogFallbackOnce($"mkstemp failed ({Marshal.GetLastPInvokeError()})");
                    return false;
                }

                unlink((nint)pTemplate);
            }

            try
            {
                if (ftruncate(fd, (nint)size) != 0)
                {
                    LogFallbackOnce($"ftruncate failed ({Marshal.GetLastPInvokeError()})");
                    return false;
                }

                nint ptr = Mmap(nint.Zero, size, MmapProts.PROT_READ | MmapProts.PROT_WRITE, MmapFlags.MAP_SHARED, fd, 0);

                if (ptr == nint.Zero || ptr == new nint(-1))
                {
                    LogFallbackOnce($"mmap failed ({Marshal.GetLastPInvokeError()})");
                    return false;
                }

                _blocks[ptr] = size;
                long total = Interlocked.Add(ref _bytes, (long)size);
                Console.WriteLine($"[GuestMemorySwap] {size / (1024 * 1024)} MB block backed by a swap file (total {total / (1024 * 1024)} MB)");

                address = ptr;
                return true;
            }
            finally
            {
                // The mapping keeps the (unlinked) file alive.
                close(fd);
            }
        }

        /// <summary>Called before a shared block is unmapped; true if it was a swap-file block.</summary>
        public static bool Release(nint address)
        {
            if (_blocks.TryRemove(address, out ulong size))
            {
                Interlocked.Add(ref _bytes, -(long)size);
                return true;
            }

            return false;
        }

        private static void LogFallbackOnce(string reason)
        {
            if (Interlocked.Exchange(ref _loggedFallback, 1) == 0)
            {
                Console.WriteLine($"[GuestMemorySwap] using normal memory: {reason}");
            }
        }
    }
}
