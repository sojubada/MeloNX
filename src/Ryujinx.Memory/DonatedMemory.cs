using Ryujinx.Common.Logging;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Ryujinx.Memory
{
    /// <summary>
    /// Guest RAM that lives on another process's jetsam ledger.
    /// </summary>
    [SupportedOSPlatform("ios")]
    public static unsafe class DonatedMemory
    {
        private readonly struct FreeRange
        {
            public ulong Offset { get; }
            public ulong Size { get; }

            public bool Dirty { get; }

            public ulong EndOffset => Offset + Size;

            public FreeRange(ulong offset, ulong size, bool dirty)
            {
                Offset = offset;
                Size = size;
                Dirty = dirty;
            }
        }

        private static readonly object _lock = new();
        private static readonly List<FreeRange> _freeRanges = [];
        private static readonly Dictionary<nint, ulong> _liveAllocations = [];

        private static nint _base;
        private static ulong _size;
        private static ulong _usedBytes;
        private static bool _exhaustionReported;

        private static ulong Granularity => MemoryBlock.GetPageSize();
        public static bool Available
        {
            get
            {
                lock (_lock)
                {
                    return _base != nint.Zero && _freeRanges.Count != 0;
                }
            }
        }

        public static ulong OfferedSize
        {
            get
            {
                lock (_lock)
                {
                    return _base != nint.Zero ? _size : 0;
                }
            }
        }

        public static ulong UsedBytes
        {
            get
            {
                lock (_lock)
                {
                    return _usedBytes;
                }
            }
        }

        /// <summary>
        /// Called by Swift once the donors are up and their memory is mapped.
        /// </summary>
        /// <param name="baseAddress">Base of the contiguous donated region</param>
        /// <param name="size">Size of the region in bytes</param>
        public static void Offer(nint baseAddress, ulong size)
        {
            lock (_lock)
            {
                Reset();

                if (baseAddress == nint.Zero || size < Granularity)
                {
                    return;
                }

                _base = baseAddress;
                _size = size & ~(Granularity - 1);

                // The donors' memory arrives straight from mach_vm_allocate and they never touch
                // it, so the region starts out zeroed.
                _freeRanges.Add(new FreeRange(0, _size, false));
            }
        }

        public static void Withdraw()
        {
            lock (_lock)
            {
                Reset();
            }
        }

        private static void Reset()
        {
            _base = nint.Zero;
            _size = 0;
            _usedBytes = 0;
            _exhaustionReported = false;
            _freeRanges.Clear();
            _liveAllocations.Clear();
        }

        /// <summary>
        /// Takes a piece of the donated region to back a shared memory block.
        /// </summary>
        /// <param name="size">Size the caller needs</param>
        /// <param name="baseAddress">Base of the memory handed out</param>
        /// <returns>True if the region had room and <paramref name="baseAddress"/> was set</returns>
        public static bool TryAllocate(ulong size, out nint baseAddress)
        {
            baseAddress = nint.Zero;

            if (size == 0)
            {
                return false;
            }

            ulong granularity = Granularity;
            ulong alignedSize = (size + (granularity - 1)) & ~(granularity - 1);

            if (alignedSize < size)
            {
                return false;
            }

            lock (_lock)
            {
                if (_base == nint.Zero || alignedSize > _size)
                {
                    return false;
                }

                int bestIndex = -1;
                ulong bestSize = ulong.MaxValue;

                for (int i = 0; i < _freeRanges.Count; i++)
                {
                    ulong rangeSize = _freeRanges[i].Size;

                    if (rangeSize >= alignedSize && rangeSize < bestSize)
                    {
                        bestIndex = i;
                        bestSize = rangeSize;

                        if (rangeSize == alignedSize)
                        {
                            break;
                        }
                    }
                }

                if (bestIndex < 0)
                {
                    if (!_exhaustionReported)
                    {
                        _exhaustionReported = true;

                        Logger.Warning?.Print(LogClass.Cpu,
                            $"Donated memory is full ({_usedBytes / (1024 * 1024)} MB of " +
                            $"{_size / (1024 * 1024)} MB in use, largest free range too small for " +
                            $"{alignedSize / 1024} KB). Further guest memory will count against this process.");
                    }

                    return false;
                }

                FreeRange range = _freeRanges[bestIndex];

                if (range.Size == alignedSize)
                {
                    _freeRanges.RemoveAt(bestIndex);
                }
                else
                {
                    _freeRanges[bestIndex] = new FreeRange(
                        range.Offset + alignedSize,
                        range.Size - alignedSize,
                        range.Dirty);
                }

                baseAddress = _base + (nint)range.Offset;

                if (range.Dirty)
                {
                    NativeMemory.Clear((void *)baseAddress, (nuint)alignedSize);
                }

                _liveAllocations[baseAddress] = alignedSize;
                _usedBytes += alignedSize;

                return true;
            }
        }


        public static bool Owns(nint address)
        {
            lock (_lock)
            {
                return _base != nint.Zero && _liveAllocations.ContainsKey(address);
            }
        }

        public static bool Free(nint address)
        {
            lock (_lock)
            {
                if (_base == nint.Zero || !_liveAllocations.Remove(address, out ulong size))
                {
                    return false;
                }

                _usedBytes -= size;

                InsertFreeLocked((ulong)(address - _base), size, true);

                return true;
            }
        }

        private static void InsertFreeLocked(ulong offset, ulong size, bool dirty)
        {
            int index = 0;

            while (index < _freeRanges.Count && _freeRanges[index].Offset < offset)
            {
                index++;
            }

            _freeRanges.Insert(index, new FreeRange(offset, size, dirty));

            if (index + 1 < _freeRanges.Count &&
                _freeRanges[index].EndOffset == _freeRanges[index + 1].Offset &&
                _freeRanges[index + 1].Dirty == dirty)
            {
                _freeRanges[index] = new FreeRange(offset, size + _freeRanges[index + 1].Size, dirty);
                _freeRanges.RemoveAt(index + 1);
            }

            if (index > 0 &&
                _freeRanges[index - 1].EndOffset == _freeRanges[index].Offset &&
                _freeRanges[index - 1].Dirty == dirty)
            {
                _freeRanges[index - 1] = new FreeRange(
                    _freeRanges[index - 1].Offset,
                    _freeRanges[index - 1].Size + _freeRanges[index].Size,
                    dirty);

                _freeRanges.RemoveAt(index);
            }
        }
    }
}
