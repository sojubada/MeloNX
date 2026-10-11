using System;

namespace Ryujinx.Memory
{
    public static class MemoryManagement
    {
        public static nint Allocate(ulong size, bool forJit)
        {
            if (OperatingSystem.IsWindows())
            {
                return MemoryManagementWindows.Allocate((nint)size);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                return MemoryManagementUnix.Allocate(size, forJit);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static nint Reserve(ulong size, bool forJit, bool viewCompatible)
        {
            if (OperatingSystem.IsWindows())
            {
                return MemoryManagementWindows.Reserve((nint)size, viewCompatible);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                return MemoryManagementUnix.Reserve(size, forJit);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void Commit(nint address, ulong size, bool forJit)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.Commit(address, (nint)size);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.Commit(address, size, forJit);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void Decommit(nint address, ulong size)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.Decommit(address, (nint)size);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.Decommit(address, size);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        /// <summary>
        /// Attempts to decommit a range, returning false instead of throwing when the platform refuses.
        /// </summary>
        public static bool TryDecommit(nint address, ulong size)
        {
            try
            {
                if (OperatingSystem.IsWindows())
                {
                    MemoryManagementWindows.Decommit(address, (nint)size);

                    return true;
                }
                else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
                {
                    return MemoryManagementUnix.TryDecommit(address, size);
                }
            }
            catch (SystemException)
            {
                return false;
            }

            return false;
        }

        /// <summary>
        /// Drops the physical pages backing a range without changing its protection or commit state, so the range stays usable. Returns false if the platform refuses.
        /// </summary>
        public static bool TryDiscard(nint address, ulong size)
        {
            try
            {
                if (OperatingSystem.IsWindows())
                {
                    return MemoryManagementWindows.TryDiscardPages(address, (nint)size);
                }
                else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
                {
                    return MemoryManagementUnix.TryDiscardPages(address, size);
                }
            }
            catch (SystemException)
            {
                return false;
            }

            return false;
        }

        /// <summary>
        /// Announces that a range previously passed to <see cref="TryDiscard"/> is about to be used again, so it stops being counted as reclaimable. Contents are left alone.
        /// </summary>
        public static bool TryUndiscard(nint address, ulong size)
        {
            try
            {
                if (OperatingSystem.IsWindows())
                {
                    // MEM_RESET_UNDO exists, but it can fail simply because the pages are already
                    // gone, and nothing here depends on the outcome.
                    return true;
                }
                else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
                {
                    return MemoryManagementUnix.TryReuseDiscardedPages(address, size);
                }
            }
            catch (SystemException)
            {
                return false;
            }

            return false;
        }

        public static void MapView(nint sharedMemory, ulong srcOffset, nint address, ulong size, MemoryBlock owner)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.MapView(sharedMemory, srcOffset, address, (nint)size, owner);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.MapView(sharedMemory, srcOffset, address, size);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void UnmapView(nint sharedMemory, nint address, ulong size, MemoryBlock owner)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.UnmapView(sharedMemory, address, (nint)size, owner);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.UnmapView(address, size);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void Reprotect(nint address, ulong size, MemoryPermission permission, bool forView, bool throwOnFail)
        {
            bool result;

            if (OperatingSystem.IsWindows())
            {
                result = MemoryManagementWindows.Reprotect(address, (nint)size, permission, forView);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                result = MemoryManagementUnix.Reprotect(address, size, permission);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            if (!result && throwOnFail)
            {
                throw new MemoryProtectionException(permission);
            }
        }

        public static bool Free(nint address, ulong size)
        {
            if (OperatingSystem.IsWindows())
            {
                return MemoryManagementWindows.Free(address, (nint)size);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                return MemoryManagementUnix.Free(address);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static nint CreateSharedMemory(ulong size, bool reserve)
        {
            if (OperatingSystem.IsWindows())
            {
                return MemoryManagementWindows.CreateSharedMemory((nint)size, reserve);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                return MemoryManagementUnix.CreateSharedMemory(size, reserve);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void DestroySharedMemory(nint handle)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.DestroySharedMemory(handle);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.DestroySharedMemory(handle);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static nint MapSharedMemory(nint handle, ulong size)
        {
            if (OperatingSystem.IsWindows())
            {
                return MemoryManagementWindows.MapSharedMemory(handle);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                return MemoryManagementUnix.MapSharedMemory(handle, size);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        public static void UnmapSharedMemory(nint address, ulong size)
        {
            if (OperatingSystem.IsWindows())
            {
                MemoryManagementWindows.UnmapSharedMemory(address);
            }
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                MemoryManagementUnix.UnmapSharedMemory(address, size);
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }
    }
}
