using Ryujinx.Common.Logging;
using Silk.NET.Vulkan;
using Silk.NET.Vulkan.Extensions.EXT;
using System;
using System.Collections.Generic;
using VkBuffer = Silk.NET.Vulkan.Buffer;

namespace Ryujinx.Graphics.Vulkan
{
    sealed class DonatedBufferAllocator : IDisposable
    {
        private const ulong MinimumBufferSize = 64 * 1024;
        private readonly object _lock = new();
        private readonly Vk _api;
        private readonly Device _device;
        private readonly VulkanPhysicalDevice _physicalDevice;
        private readonly MemoryAllocator _allocator;
        private readonly ExtExternalMemoryHost _hostApi;
        private readonly Dictionary<BufferUsageFlags, bool> _supportedUsages = [];
        private readonly nint _pointer;
        private readonly ulong _size;
        private readonly bool _claimed;
        private MemoryAllocatorBlockList _pool;
        private MemoryPropertyFlags _memoryFlags;
        private bool _disabled;
        private bool _disposed;

        public unsafe DonatedBufferAllocator(Vk api, Device device, VulkanPhysicalDevice physicalDevice,
            MemoryAllocator allocator, ExtExternalMemoryHost hostApi)
        {
            _api = api;
            _device = device;
            _physicalDevice = physicalDevice;
            _allocator = allocator;
            _hostApi = hostApi;

            if (!OperatingSystem.IsIOS() || hostApi == null || !DonatedBufferMemory.TryClaim(out nint pointer, out ulong size))
            {
                _disabled = true;
                return;
            }

            _claimed = true;

            PhysicalDeviceExternalMemoryHostPropertiesEXT hostProperties = new()
            {
                SType = StructureType.PhysicalDeviceExternalMemoryHostPropertiesExt,
            };
            PhysicalDeviceProperties2 properties = new()
            {
                SType = StructureType.PhysicalDeviceProperties2,
                PNext = &hostProperties,
            };
            api.GetPhysicalDeviceProperties2(physicalDevice.PhysicalDevice, &properties);

            ulong alignment = hostProperties.MinImportedHostPointerAlignment;
            ulong address = (ulong)(nuint)pointer;
            if (alignment == 0 || (alignment & (alignment - 1)) != 0 ||
                address > ulong.MaxValue - (alignment - 1))
            {
                Disable("invalid host-import alignment");
                return;
            }

            ulong padding = ((address + alignment - 1) & ~(alignment - 1)) - address;
            if (padding >= size || (size - padding) / alignment * alignment < MinimumBufferSize)
            {
                Disable("donated arena is too small for host-import alignment");
                return;
            }

            _pointer = pointer + (nint)padding;
            _size = (size - padding) / alignment * alignment;
        }

        private void Disable(string reason)
        {
            _disabled = true;
            Logger.Warning?.PrintMsg(LogClass.Gpu, $"Donated GPU buffers disabled: {reason}. Using normal allocations.");
        }

        private unsafe bool SupportsUsage(BufferUsageFlags usage)
        {
            if (!_supportedUsages.TryGetValue(usage, out bool supported))
            {
                PhysicalDeviceExternalBufferInfo info = new()
                {
                    SType = StructureType.PhysicalDeviceExternalBufferInfo,
                    Usage = usage,
                    HandleType = ExternalMemoryHandleTypeFlags.HostAllocationBitExt,
                };
                ExternalBufferProperties properties = new() { SType = StructureType.ExternalBufferProperties };
                _api.GetPhysicalDeviceExternalBufferProperties(_physicalDevice.PhysicalDevice, &info, &properties);
                ExternalMemoryProperties memory = properties.ExternalMemoryProperties;
                supported = memory.ExternalMemoryFeatures.HasFlag(ExternalMemoryFeatureFlags.ImportableBit) &&
                    !memory.ExternalMemoryFeatures.HasFlag(ExternalMemoryFeatureFlags.DedicatedOnlyBit) &&
                    memory.CompatibleHandleTypes.HasFlag(ExternalMemoryHandleTypeFlags.HostAllocationBitExt);
                _supportedUsages.Add(usage, supported);
                if (!supported)
                {
                    Logger.Info?.PrintMsg(LogClass.Gpu, $"Donated GPU buffers: host import unavailable for usage {usage}.");
                }
            }

            return supported;
        }

        private unsafe bool InitializePool(MemoryRequirements requirements, MemoryPropertyFlags flags)
        {
            MemoryHostPointerPropertiesEXT properties = new()
            {
                SType = StructureType.MemoryHostPointerPropertiesExt,
            };
            Result result = _hostApi.GetMemoryHostPointerProperties(_device,
                ExternalMemoryHandleTypeFlags.HostAllocationBitExt, (void*)_pointer, &properties);
            if (result != Result.Success)
            {
                Disable($"host pointer query returned {result}");
                return false;
            }

            uint typeBits = requirements.MemoryTypeBits & properties.MemoryTypeBits;


            flags |= MemoryPropertyFlags.HostVisibleBit | MemoryPropertyFlags.HostCoherentBit;
            int index = _allocator.FindSuitableMemoryTypeIndex(typeBits, flags | MemoryPropertyFlags.HostCachedBit);
            if (index < 0)
            {
                index = _allocator.FindSuitableMemoryTypeIndex(typeBits, flags);
            }
            if (index < 0)
            {
                return false;
            }

            ImportMemoryHostPointerInfoEXT import = new()
            {
                SType = StructureType.ImportMemoryHostPointerInfoExt,
                HandleType = ExternalMemoryHandleTypeFlags.HostAllocationBitExt,
                PHostPointer = (void*)_pointer,
            };
            MemoryAllocateInfo allocation = new()
            {
                SType = StructureType.MemoryAllocateInfo,
                PNext = &import,
                AllocationSize = _size,
                MemoryTypeIndex = (uint)index,
            };
            result = _api.AllocateMemory(_device, in allocation, null, out DeviceMemory memory);
            if (result != Result.Success)
            {
                Disable($"arena import returned {result}");
                return false;
            }

            _memoryFlags = _physicalDevice.PhysicalDeviceMemoryProperties.MemoryTypes[index].PropertyFlags;
            _pool = new MemoryAllocatorBlockList(_api, _device, index,
                new MemoryAllocatorBlockList.Block(memory, _pointer, _size, false, importedHostPointer: true));
            Logger.Info?.PrintMsg(LogClass.Gpu, $"Donated GPU buffer pool imported: {_size / (1024 * 1024)} MiB. Physical footprint savings require device measurement.");
            return true;
        }

        public unsafe bool TryCreate(int size, BufferUsageFlags usage, MemoryPropertyFlags flags,
            out VkBuffer buffer, out MemoryAllocation allocation)
        {
            buffer = default;
            allocation = default;
            if (size < (int)MinimumBufferSize)
            {
                return false;
            }

            lock (_lock)
            {
                if (_disabled || _disposed || (ulong)size > _size || !SupportsUsage(usage))
                {
                    return false;
                }

                ExternalMemoryBufferCreateInfo external = new()
                {
                    SType = StructureType.ExternalMemoryBufferCreateInfo,
                    HandleTypes = ExternalMemoryHandleTypeFlags.HostAllocationBitExt,
                };
                BufferCreateInfo info = new()
                {
                    SType = StructureType.BufferCreateInfo,
                    PNext = &external,
                    Size = (ulong)size,
                    Usage = usage,
                    SharingMode = SharingMode.Exclusive,
                };
                Result result = _api.CreateBuffer(_device, in info, null, out VkBuffer candidate);
                if (result != Result.Success)
                {
                    Disable($"external buffer creation returned {result}");
                    return false;
                }

                bool success = false;
                MemoryAllocation candidateAllocation = default;
                try
                {
                    MemoryDedicatedRequirements dedicated = new() { SType = StructureType.MemoryDedicatedRequirements };
                    MemoryRequirements2 requirements2 = new()
                    {
                        SType = StructureType.MemoryRequirements2,
                        PNext = &dedicated,
                    };
                    BufferMemoryRequirementsInfo2 bufferInfo = new()
                    {
                        SType = StructureType.BufferMemoryRequirementsInfo2,
                        Buffer = candidate,
                    };
                    _api.GetBufferMemoryRequirements2(_device, &bufferInfo, &requirements2);
                    MemoryRequirements requirements = requirements2.MemoryRequirements;
                    if (dedicated.RequiresDedicatedAllocation || requirements.Size > _size ||
                        (_pool == null && !InitializePool(requirements, flags)) ||
                        (requirements.MemoryTypeBits & (1u << _pool.MemoryTypeIndex)) == 0 ||
                        !_memoryFlags.HasFlag(flags))
                    {
                        return false;
                    }

                    candidateAllocation = _pool.Allocate(requirements.Size, requirements.Alignment, map: true);
                    if (candidateAllocation.Memory.Handle == 0)
                    {
                        return false;
                    }

                    result = _api.BindBufferMemory(_device, candidate, candidateAllocation.Memory, candidateAllocation.Offset);
                    if (result != Result.Success)
                    {
                        Disable($"buffer binding returned {result}");
                        return false;
                    }

                    buffer = candidate;
                    allocation = candidateAllocation;
                    success = true;
                    return true;
                }
                finally
                {
                    if (!success)
                    {
                        _api.DestroyBuffer(_device, candidate, null);
                        if (candidateAllocation.Memory.Handle != 0)
                        {
                            candidateAllocation.Dispose();
                        }
                    }
                }
            }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;
                _pool?.Dispose();
                if (_claimed)
                {
                    DonatedBufferMemory.Release();
                    Logger.Info?.PrintMsg(LogClass.Gpu, "Donated GPU buffer pool released.");
                }
            }
        }
    }
}
