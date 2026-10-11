using Ryujinx.Common.Logging;
using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.SupervisorCall;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Ryujinx.HLE.HOS.Kernel
{
    class KernelContext : IDisposable
    {
        public long PrivilegedProcessLowestId { get; set; } = 1;
        public long PrivilegedProcessHighestId { get; set; } = 8;

        public bool EnableVersionChecks { get; set; }

        public bool KernelInitialized { get; }

        public bool Running { get; private set; }

        public Switch Device { get; }
        public MemoryBlock Memory { get; }
        public ITickSource TickSource { get; }
        public Syscall Syscall { get; }
        public SyscallHandler SyscallHandler { get; }

        public KResourceLimit ResourceLimit { get; }

        public KMemoryManager MemoryManager { get; }

        public KMemoryBlockSlabManager LargeMemoryBlockSlabManager { get; }
        public KMemoryBlockSlabManager SmallMemoryBlockSlabManager { get; }

        public KSlabHeap UserSlabHeapPages { get; }

        public KCriticalSection CriticalSection { get; }
        public KScheduler[] Schedulers { get; }
        public KPriorityQueue PriorityQueue { get; }
        public KTimeManager TimeManager { get; }
        public KSynchronization Synchronization { get; }
        public KContextIdManager ContextIdManager { get; }

        public ConcurrentDictionary<ulong, KProcess> Processes { get; }
        public ConcurrentDictionary<string, KAutoObject> AutoObjectNames { get; }

        public bool ThreadReselectionRequested { get; set; }

        private ulong _kipId;
        private ulong _processId;
        private ulong _threadUid;

        public KernelContext(
            ITickSource tickSource,
            Switch device,
            MemoryBlock memory,
            MemorySize memorySize,
            MemoryArrange memoryArrange)
        {
            TickSource = tickSource;
            Device = device;
            Memory = memory;
            KScheduler.CpuCoresCount = device.CpuCoresCount;

            Running = true;

            Syscall = new Syscall(this);

            SyscallHandler = new SyscallHandler(this);

            ResourceLimit = new KResourceLimit(this);

            KernelInit.InitializeResourceLimit(ResourceLimit, memorySize);

            MemoryManager = new KMemoryManager(this, memorySize, memoryArrange);

            LargeMemoryBlockSlabManager = new KMemoryBlockSlabManager(KernelConstants.MemoryBlockAllocatorSize * 2);
            SmallMemoryBlockSlabManager = new KMemoryBlockSlabManager(KernelConstants.MemoryBlockAllocatorSize);

            UserSlabHeapPages = new KSlabHeap(
                KernelConstants.UserSlabHeapBase,
                KernelConstants.UserSlabHeapItemSize,
                KernelConstants.UserSlabHeapSize);

            CommitMemory(KernelConstants.UserSlabHeapBase - DramMemoryMap.DramBase, KernelConstants.UserSlabHeapSize);

            CriticalSection = new KCriticalSection(this);
            Schedulers = new KScheduler[KScheduler.CpuCoresCount];
            PriorityQueue = new KPriorityQueue();
            TimeManager = new KTimeManager(this);
            Synchronization = new KSynchronization(this);
            ContextIdManager = new KContextIdManager();

            for (int core = 0; core < KScheduler.CpuCoresCount; core++)
            {
                Schedulers[core] = new KScheduler(this, core);
            }

            StartPreemptionThread();

            KernelInitialized = true;

            Processes = new ConcurrentDictionary<ulong, KProcess>();
            AutoObjectNames = new ConcurrentDictionary<string, KAutoObject>();

            _kipId = KernelConstants.InitialKipId;
            _processId = KernelConstants.InitialProcessId;
        }

        private void StartPreemptionThread()
        {
            void PreemptionThreadStart()
            {
                KScheduler.PreemptionThreadLoop(this);
            }

            new Thread(PreemptionThreadStart) { Name = "HLE.PreemptionThread" }.Start();
        }

        public void CommitMemory(ulong address, ulong size)
        {
            ulong alignment = MemoryBlock.GetPageSize();
            ulong endAddress = address + size;

            address &= ~(alignment - 1);
            endAddress = (endAddress + (alignment - 1)) & ~(alignment - 1);

            Memory.Commit(address, endAddress - address);
        }

        /// <summary>
        /// Releases the host pages backing a range of guest physical memory that is no longer in use.
        /// </summary>
        /// <param name="address">Offset into the backing memory of the range to release</param>
        /// <param name="size">Size of the range to release</param>
        /// <returns>Number of bytes actually released</returns>
        public ulong DecommitMemory(ulong address, ulong size)
        {
            if (!MemoryReclaim.GuestPhysicalEnabled)
            {
                return 0;
            }

            ulong alignment = MemoryBlock.GetPageSize();
            ulong endAddress = address + size;

            address = (address + (alignment - 1)) & ~(alignment - 1);
            endAddress &= ~(alignment - 1);

            if (endAddress <= address)
            {
                return 0;
            }

            ulong alignedSize = endAddress - address;

            if (alignedSize < MemoryReclaim.GuestPhysicalMinimumSize)
            {
                return 0;
            }

            if (!Memory.TryDecommit(address, alignedSize))
            {
                return 0;
            }

            MemoryReclaim.AddGuestPhysicalBytes(alignedSize);

            Logger.Debug?.Print(LogClass.Kernel,
                $"Released 0x{alignedSize:X} bytes of guest physical memory at 0x{address:X} " +
                $"(0x{MemoryReclaim.GuestPhysicalBytes:X} total)");

            return alignedSize;
        }

        public ulong NewThreadUid()
        {
            return Interlocked.Increment(ref _threadUid) - 1;
        }

        public ulong NewKipId()
        {
            return Interlocked.Increment(ref _kipId) - 1;
        }

        public ulong NewProcessId()
        {
            return Interlocked.Increment(ref _processId) - 1;
        }

        public void Dispose()
        {
            Running = false;

            for (int i = 0; i < KScheduler.CpuCoresCount; i++)
            {
                Schedulers[i].Dispose();
            }

            TimeManager.Dispose();
        }
    }
}
