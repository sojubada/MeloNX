using Ryujinx.Common;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    class MemoryAllocatorBlockList : IDisposable
    {
        private const ulong InvalidOffset = ulong.MaxValue;

        public class Block : IComparable<Block>
        {
            public DeviceMemory Memory { get; private set; }
            public nint HostPointer { get; private set; }
            public ulong Size { get; }
            public bool Dedicated { get; }
            public bool Mapped => HostPointer != nint.Zero;
            private readonly bool _importedHostPointer;
            private readonly struct Range : IComparable<Range>
            {
                public ulong Offset { get; }
                public ulong Size { get; }

                public Range(ulong offset, ulong size)
                {
                    Offset = offset;
                    Size = size;
                }

                public int CompareTo(Range other)
                {
                    return Offset.CompareTo(other.Offset);
                }
            }

            private readonly List<Range> _freeRanges;

            /// <summary>
            /// Guards <see cref="_freeRanges"/>. Held only for the range bookkeeping of a single
            /// block, so allocations that land on different blocks do not contend, and no driver
            /// call is ever made while it is held.
            /// </summary>
            private readonly Lock _rangeLock = new();

            public Block(DeviceMemory memory, nint hostPointer, ulong size, bool dedicated, bool importedHostPointer = false)
            {
                Memory = memory;
                HostPointer = hostPointer;
                Size = size;
                Dedicated = dedicated;
                _importedHostPointer = importedHostPointer;
                _freeRanges =
                [
                    new(0, size)
                ];
            }

            public ulong Allocate(ulong size, ulong alignment)
            {
                lock (_rangeLock)
                {
                    for (int i = 0; i < _freeRanges.Count; i++)
                    {
                        Range range = _freeRanges[i];

                        ulong alignedOffset = BitUtils.AlignUp(range.Offset, alignment);
                        ulong sizeDelta = alignedOffset - range.Offset;
                        ulong usableSize = range.Size - sizeDelta;

                        if (sizeDelta < range.Size && usableSize >= size)
                        {
                            _freeRanges.RemoveAt(i);

                            if (sizeDelta != 0)
                            {
                                InsertFreeRange(range.Offset, sizeDelta);
                            }

                            ulong endOffset = range.Offset + range.Size;
                            ulong remainingSize = endOffset - (alignedOffset + size);
                            if (remainingSize != 0)
                            {
                                InsertFreeRange(endOffset - remainingSize, remainingSize);
                            }

                            return alignedOffset;
                        }
                    }

                    return InvalidOffset;
                }
            }

            public void Free(ulong offset, ulong size)
            {
                lock (_rangeLock)
                {
                    InsertFreeRangeComingled(offset, size);
                }
            }

            private void InsertFreeRange(ulong offset, ulong size)
            {
                Range range = new(offset, size);
                int index = _freeRanges.BinarySearch(range);
                if (index < 0)
                {
                    index = ~index;
                }

                _freeRanges.Insert(index, range);
            }

            private void InsertFreeRangeComingled(ulong offset, ulong size)
            {
                ulong endOffset = offset + size;
                Range range = new(offset, size);
                int index = _freeRanges.BinarySearch(range);
                if (index < 0)
                {
                    index = ~index;
                }

                if (index < _freeRanges.Count && _freeRanges[index].Offset == endOffset)
                {
                    endOffset = _freeRanges[index].Offset + _freeRanges[index].Size;
                    _freeRanges.RemoveAt(index);
                }

                if (index > 0 && _freeRanges[index - 1].Offset + _freeRanges[index - 1].Size == offset)
                {
                    offset = _freeRanges[index - 1].Offset;
                    _freeRanges.RemoveAt(--index);
                }

                range = new Range(offset, endOffset - offset);

                _freeRanges.Insert(index, range);
            }

            public bool IsTotallyFree()
            {
                lock (_rangeLock)
                {
                    if (_freeRanges.Count == 1 && _freeRanges[0].Size == Size)
                    {
                        Debug.Assert(_freeRanges[0].Offset == 0);
                        return true;
                    }

                    return false;
                }
            }

            public int CompareTo(Block other)
            {
                return Size.CompareTo(other.Size);
            }

            public unsafe void Destroy(Vk api, Device device)
            {
                if (Mapped && !_importedHostPointer)
                {
                    api.UnmapMemory(device, Memory);
                    HostPointer = nint.Zero;
                }

                if (Memory.Handle != 0)
                {
                    api.FreeMemory(device, Memory, null);
                    Memory = default;
                }
            }
        }

        private readonly List<Block> _blocks;

        private readonly Vk _api;
        private readonly Device _device;

        public int MemoryTypeIndex { get; }
        public bool ForBuffer { get; }

        private readonly int _poolBlockSize;
        private readonly bool _fixedCapacity;

        private readonly ReaderWriterLockSlim _lock;

        public MemoryAllocatorBlockList(Vk api, Device device, int memoryTypeIndex, int poolBlockSize, bool forBuffer)
        {
            _blocks = [];
            _api = api;
            _device = device;
            MemoryTypeIndex = memoryTypeIndex;
            ForBuffer = forBuffer;
            _poolBlockSize = poolBlockSize;
            _lock = new(LockRecursionPolicy.NoRecursion);
        }

        public MemoryAllocatorBlockList(Vk api, Device device, int memoryTypeIndex, Block importedBlock)
            : this(api, device, memoryTypeIndex, 0, true)
        {
            _fixedCapacity = true;
            _blocks.Add(importedBlock);
        }

        public unsafe MemoryAllocation Allocate(ulong size, ulong alignment, bool map)
        {
            // Ensure we have a sane alignment value.
            if ((ulong)(int)alignment != alignment || (int)alignment <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(alignment), $"Invalid alignment 0x{alignment:X}.");
            }

            bool dedicated = !_fixedCapacity && size >= (ulong)_poolBlockSize / 2;


            if (!dedicated)
            {
                _lock.EnterReadLock();

                try
                {
                    for (int i = 0; i < _blocks.Count; i++)
                    {
                        Block block = _blocks[i];

                        if (!block.Dedicated && block.Mapped == map && block.Size >= size)
                        {
                            ulong offset = block.Allocate(size, alignment);
                            if (offset != InvalidOffset)
                            {
                                return new MemoryAllocation(this, block, block.Memory, GetHostPointer(block, offset), offset, size);
                            }
                        }
                    }
                }
                finally
                {
                    _lock.ExitReadLock();
                }
            }

            // Imported donor memory is a bounded arena. Exhaustion must fall back to the
            // normal allocator, never silently grow this pool using local memory.
            if (_fixedCapacity)
            {
                return default;
            }

            ulong blockSize = dedicated ? size : (ulong)_poolBlockSize;

            MemoryAllocateInfo memoryAllocateInfo = new()
            {
                SType = StructureType.MemoryAllocateInfo,
                AllocationSize = blockSize,
                MemoryTypeIndex = (uint)MemoryTypeIndex,
            };

            _api.AllocateMemory(_device, in memoryAllocateInfo, null, out DeviceMemory deviceMemory).ThrowOnError();

            nint hostPointer = nint.Zero;

            if (map)
            {
                void* pointer = null;
                _api.MapMemory(_device, deviceMemory, 0, blockSize, 0, ref pointer).ThrowOnError();
                hostPointer = (nint)pointer;
            }

            Block newBlock = new(deviceMemory, hostPointer, blockSize, dedicated);

            // Claim our range before publishing the block, so a concurrent allocation cannot take
            // the space this call already committed to.
            ulong newBlockOffset = newBlock.Allocate(size, alignment);
            Debug.Assert(newBlockOffset != InvalidOffset);

            _lock.EnterWriteLock();

            try
            {
                InsertBlock(newBlock);
            }
            finally
            {
                _lock.ExitWriteLock();
            }

            return new MemoryAllocation(this, newBlock, deviceMemory, GetHostPointer(newBlock, newBlockOffset), newBlockOffset, size);
        }

        private static nint GetHostPointer(Block block, ulong offset)
        {
            if (block.HostPointer == nint.Zero)
            {
                return nint.Zero;
            }

            return (nint)((nuint)block.HostPointer + offset);
        }

        public void Free(Block block, ulong offset, ulong size)
        {
            block.Free(offset, size);

            if (_fixedCapacity || !block.IsTotallyFree())
            {
                return;
            }

            bool destroy = false;

            _lock.EnterWriteLock();

            try
            {
                // Re-check while holding the list lock. The check above raced with allocations, and
                // the write lock is what guarantees nobody can find this block once it is removed.
                if (block.IsTotallyFree())
                {
                    for (int i = 0; i < _blocks.Count; i++)
                    {
                        if (_blocks[i] == block)
                        {
                            _blocks.RemoveAt(i);
                            destroy = true;
                            break;
                        }
                    }
                }
            }
            finally
            {
                _lock.ExitWriteLock();
            }

            if (destroy)
            {
                block.Destroy(_api, _device);
            }
        }

        private void InsertBlock(Block block)
        {
            int index = _blocks.BinarySearch(block);
            if (index < 0)
            {
                index = ~index;
            }

            _blocks.Insert(index, block);
        }

        public void Dispose()
        {
            for (int i = 0; i < _blocks.Count; i++)
            {
                _blocks[i].Destroy(_api, _device);
            }
        }
    }
}
