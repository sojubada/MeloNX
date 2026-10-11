using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Silk.NET.Vulkan;
using System;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    internal sealed class PipelineCacheManager : IDisposable
    {
        private const int SaveInterval = 64;
        private const long MinimumSaveIntervalMs = 15_000;
        private const long TotalCacheBudget = 256L * 1024 * 1024;
        private const long MainCacheBudget = TotalCacheBudget / 2;
        private const long MinimumCacheBudget = 16L * 1024 * 1024;
        private const long InitialBytesPerPipeline = 128 * 1024;

        private sealed class CacheState
        {
            public PipelineCache Cache;
            public readonly string Path;
            public readonly string Description;
            public readonly long Budget;

            public int PipelineCount;
            public int SavedPipelineCount;
            public long LastSaveTimestamp;
            public bool Frozen;

            private long _measuredBytes;
            private int _measuredPipelineCount;
            private long _bytesPerPipeline = InitialBytesPerPipeline;

            public CacheState(PipelineCache cache, string path, string description, long budget, long loadedBytes)
            {
                Cache = cache;
                Path = path;
                Description = description;
                Budget = budget;
                _measuredBytes = loadedBytes;
            }

            public long EstimatedBytes => _measuredBytes + Math.Max(0, PipelineCount - _measuredPipelineCount) * _bytesPerPipeline;

            public void OnMeasured(long bytes)
            {
                int added = PipelineCount - _measuredPipelineCount;

                if (added > 0 && bytes > _measuredBytes)
                {
                    _bytesPerPipeline = Math.Max(1, (bytes - _measuredBytes) / added);
                }

                _measuredBytes = bytes;
                _measuredPipelineCount = PipelineCount;
            }

            public void OnRecreated(PipelineCache cache)
            {
                Cache = cache;
                PipelineCount = 0;
                SavedPipelineCount = 0;
                _measuredBytes = 0;
                _measuredPipelineCount = 0;
            }
        }

        private sealed unsafe class MappedSnapshot : IDisposable
        {
            private readonly MemoryMappedFile _file;
            private readonly MemoryMappedViewAccessor _view;
            private readonly byte* _base;

            /// <summary>
            /// Size of the snapshot in bytes, which is also the size of the mapping.
            /// </summary>
            public long Length { get; }

            /// <summary>
            /// Start of the snapshot's contents.
            /// </summary>
            public void* Pointer => _base + _view.PointerOffset;

            private MappedSnapshot(MemoryMappedFile file, MemoryMappedViewAccessor view, byte* pointer, long length)
            {
                _file = file;
                _view = view;
                _base = pointer;
                Length = length;
            }

            /// <summary>
            /// Maps an existing snapshot read only.
            /// </summary>
            /// <param name="path">Path of the snapshot</param>
            /// <param name="length">Its length, which must be greater than zero</param>
            /// <returns>The mapping</returns>
            public static MappedSnapshot Open(string path, long length)
            {
                MemoryMappedFile file = MemoryMappedFile.CreateFromFile(
                    path, FileMode.Open, null, length, MemoryMappedFileAccess.Read);

                MemoryMappedViewAccessor view = null;
                byte* pointer = null;

                try
                {
                    view = file.CreateViewAccessor(0, length, MemoryMappedFileAccess.Read);
                    view.SafeMemoryMappedViewHandle.AcquirePointer(ref pointer);

                    return new MappedSnapshot(file, view, pointer, length);
                }
                catch
                {
                    if (pointer != null)
                    {
                        view.SafeMemoryMappedViewHandle.ReleasePointer();
                    }

                    view?.Dispose();
                    file.Dispose();

                    throw;
                }
            }

            public void Dispose()
            {
                _view.SafeMemoryMappedViewHandle.ReleasePointer();
                _view.Dispose();
                _file.Dispose();
            }
        }

        private readonly Vk _api;
        private readonly Device _device;
        private readonly Lock _mainCacheLock;
        private readonly PipelineCacheCreateFlags _createFlags;
        private readonly CacheState _mainState;
        private readonly CacheState[] _workerStates;
        private readonly string _cacheDirectory;

        private bool _disposed;
        private int _warnedMainCacheOverBudget;

        public PipelineCache MainCache => _mainState.Cache;
        public bool SupportsNonBlockingPipelineCreation { get; }

        public PipelineCacheManager(
            Vk api,
            VulkanPhysicalDevice physicalDevice,
            Device device,
            int workerCount,
            Lock mainCacheLock)
        {
            _api = api;
            _device = device;
            _mainCacheLock = mainCacheLock;
            SupportsNonBlockingPipelineCreation = physicalDevice.SupportsPipelineCreationCacheControl(api);
            _createFlags = SupportsNonBlockingPipelineCreation
                ? PipelineCacheCreateFlags.ExternallySynchronizedBitExt
                : 0;
            _workerStates = new CacheState[workerCount];

            long workerBudget = Math.Max(MinimumCacheBudget, (TotalCacheBudget - MainCacheBudget) / Math.Max(1, workerCount));

            PhysicalDeviceProperties properties = physicalDevice.PhysicalDeviceProperties;
            string cacheKey = $"{properties.VendorID:X8}-{properties.DeviceID:X8}-{properties.DriverVersion:X8}";

            string mainCachePath = null;
            string[] workerCachePaths = new string[workerCount];

            if (!string.IsNullOrEmpty(AppDataManager.BaseDirPath))
            {
                _cacheDirectory = Path.Combine(AppDataManager.BaseDirPath, "cache", "vulkan");
                mainCachePath = Path.Combine(_cacheDirectory, $"pipeline-{cacheKey}.vkpc");

                for (int index = 0; index < workerCount; index++)
                {
                    workerCachePaths[index] = Path.Combine(_cacheDirectory, $"pipeline-{cacheKey}.worker{index}.vkpc");
                }
            }

            long mainSnapshotBytes;
            PipelineCache mainCache;

            using (MappedSnapshot mainSnapshot = OpenSnapshot(mainCachePath, MainCacheBudget))
            {
                mainSnapshotBytes = mainSnapshot?.Length ?? 0;
                mainCache = CreateCache(mainSnapshot, "main");
            }

            _mainState = new(
                mainCache,
                mainCachePath,
                "main",
                MainCacheBudget,
                mainSnapshotBytes);

            int loadedWorkerCaches = 0;
            
            for (int index = 0; index < workerCount; index++)
            {
                using MappedSnapshot workerSnapshot = OpenSnapshot(workerCachePaths[index], workerBudget);

                if (workerSnapshot != null)
                {
                    loadedWorkerCaches++;
                }

                string description = $"worker {index}";

                _workerStates[index] = new(
                    CreateCache(workerSnapshot, description),
                    workerCachePaths[index],
                    description,
                    workerBudget,
                    workerSnapshot?.Length ?? 0);
            }

            Logger.Notice.PrintMsg(
                LogClass.Gpu,
                $"Vulkan pipeline cache initialized: {FormatSize(mainSnapshotBytes)} main data, " +
                $"{loadedWorkerCaches}/{workerCount} worker snapshots recovered. " +
                $"Budget {FormatSize(MainCacheBudget)} main, {FormatSize(workerBudget)} per worker.");
        }

        public PipelineCache GetWorkerCache(int workerIndex)
        {
            return _workerStates[workerIndex].Cache;
        }

        public bool IsMainCache(PipelineCache cache)
        {
            return cache.Handle == MainCache.Handle;
        }


        public void NotifyWorkerPipelineCreated(int workerIndex)
        {
            if (_disposed)
            {
                return;
            }

            CacheState state = _workerStates[workerIndex];

            state.PipelineCount++;

            Maintain(state, force: false);
        }


        public void NotifyMainPipelineCreated()
        {
            if (_disposed)
            {
                return;
            }

            Interlocked.Increment(ref _mainState.PipelineCount);

            if (_mainState.EstimatedBytes >= _mainState.Budget &&
                Interlocked.Exchange(ref _warnedMainCacheOverBudget, 1) == 0)
            {
                Logger.Warning?.PrintMsg(
                    LogClass.Gpu,
                    $"The Vulkan main pipeline cache has passed its {FormatSize(_mainState.Budget)} budget " +
                    $"(estimated {FormatSize(_mainState.EstimatedBytes)}); it will not be persisted until it fits.");
            }
        }

        public void MergeAndSave()
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            lock (_mainCacheLock)
            {
                PipelineCache[] workerCaches = new PipelineCache[_workerStates.Length];

                for (int index = 0; index < _workerStates.Length; index++)
                {
                    workerCaches[index] = _workerStates[index].Cache;
                }

                if (MergeInto(_mainState.Cache, workerCaches))
                {
                    Maintain(_mainState, force: true, allowRecycle: false);
                }
            }

            foreach (CacheState state in _workerStates)
            {
                Maintain(state, force: true, allowRecycle: false);
            }
        }


        private void Maintain(CacheState state, bool force, bool allowRecycle = true)
        {
            if (state.Frozen)
            {
                return;
            }

            if (!force)
            {
                if (state.EstimatedBytes < state.Budget)
                {
                    if (string.IsNullOrEmpty(state.Path))
                    {
                        return;
                    }

                    if (state.PipelineCount - state.SavedPipelineCount < SaveInterval)
                    {
                        return;
                    }

                    long now = Environment.TickCount64;

                    if (state.LastSaveTimestamp != 0 && now - state.LastSaveTimestamp < MinimumSaveIntervalMs)
                    {
                        return;
                    }
                }
            }

            state.SavedPipelineCount = state.PipelineCount;
            state.LastSaveTimestamp = Environment.TickCount64;

            long size = GetCacheDataSize(state);

            if (size < 0)
            {
                return;
            }

            state.OnMeasured(size);

            if (size > state.Budget)
            {
                if (allowRecycle)
                {
                    Recycle(state, size);
                }
                else
                {
                    Logger.Info?.PrintMsg(
                        LogClass.Gpu,
                        $"Not persisting the Vulkan {state.Description} pipeline cache at {FormatSize(size)}, " +
                        $"over its {FormatSize(state.Budget)} budget; the previous snapshot stands.");
                }

                return;
            }

            SaveCache(state, size, force);
        }

        private unsafe void Recycle(CacheState state, long size)
        {
            PipelineCache replacement;

            try
            {
                replacement = CreateCache(null, state.Description);
            }
            catch (VulkanException exception)
            {
                Logger.Warning?.PrintMsg(
                    LogClass.Gpu,
                    $"Could not recycle the Vulkan {state.Description} pipeline cache ({exception.Message}); " +
                    "leaving it alone from here on.");

                state.Frozen = true;

                return;
            }

            PipelineCache outgrown = state.Cache;

            state.OnRecreated(replacement);

            _api.DestroyPipelineCache(_device, outgrown, null);

            Logger.Info?.PrintMsg(
                LogClass.Gpu,
                $"Recycled the Vulkan {state.Description} pipeline cache at {FormatSize(size)}, " +
                $"over its {FormatSize(state.Budget)} budget.");
        }

        private unsafe bool MergeInto(PipelineCache destination, ReadOnlySpan<PipelineCache> sources)
        {
            if (sources.IsEmpty)
            {
                return true;
            }

            Result result;

            fixed (PipelineCache* sourceCaches = sources)
            {
                result = _api.MergePipelineCaches(_device, destination, (uint)sources.Length, sourceCaches);
            }

            if (result.IsError)
            {
                Logger.Warning?.PrintMsg(LogClass.Gpu, $"Vulkan pipeline cache merge failed: {result}.");
                return false;
            }

            return true;
        }

        /// <summary>
        /// Maps a snapshot from disk, or returns null if there is none to use.
        /// </summary>
        /// <param name="path">Snapshot path, or null if snapshots are not being kept</param>
        /// <param name="budget">Largest snapshot worth loading</param>
        private MappedSnapshot OpenSnapshot(string path, long budget)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                return null;
            }

            try
            {
                FileInfo info = new(path);

                if (info.Length == 0 || info.Length > budget)
                {
                    Logger.Warning?.PrintMsg(
                        LogClass.Gpu,
                        $"Ignoring Vulkan pipeline cache of {FormatSize(info.Length)}, outside its " +
                        $"{FormatSize(budget)} budget: {path}");
                    return null;
                }

                return MappedSnapshot.Open(path, info.Length);
            }
            catch (IOException exception)
            {
                Logger.Warning?.PrintMsg(LogClass.Gpu, $"Failed to read Vulkan pipeline cache: {exception.Message}");
            }
            catch (UnauthorizedAccessException exception)
            {
                Logger.Warning?.PrintMsg(LogClass.Gpu, $"Failed to read Vulkan pipeline cache: {exception.Message}");
            }

            return null;
        }

        private unsafe PipelineCache CreateCache(MappedSnapshot snapshot, string description)
        {
            PipelineCache pipelineCache;
            PipelineCacheCreateInfo createInfo = new()
            {
                SType = StructureType.PipelineCacheCreateInfo,
                Flags = _createFlags,
                InitialDataSize = (nuint)(snapshot?.Length ?? 0),
                PInitialData = snapshot != null ? snapshot.Pointer : null,
            };

            Result result = _api.CreatePipelineCache(_device, in createInfo, null, out pipelineCache);

            if (!result.IsError)
            {
                return pipelineCache;
            }

            if (snapshot != null)
            {
                Logger.Warning?.PrintMsg(
                    LogClass.Gpu,
                    $"Vulkan {description} pipeline cache data was rejected ({result}); starting it empty.");

                createInfo.InitialDataSize = 0;
                createInfo.PInitialData = null;

                _api.CreatePipelineCache(_device, in createInfo, null, out pipelineCache).ThrowOnError();

                return pipelineCache;
            }

            result.ThrowOnError();
            return default;
        }


        private unsafe long GetCacheDataSize(CacheState state)
        {
            nuint dataSize = 0;
            Result result = _api.GetPipelineCacheData(_device, state.Cache, &dataSize, null);

            if (result.IsError || dataSize == 0 || dataSize > int.MaxValue)
            {
                Logger.Warning?.PrintMsg(
                    LogClass.Gpu,
                    $"Unable to size the Vulkan {state.Description} pipeline cache: {result}, {dataSize} bytes.");

                return -1;
            }

            return (long)dataSize;
        }

        private unsafe void SaveCache(CacheState state, long size, bool final)
        {
            if (string.IsNullOrEmpty(state.Path))
            {
                return;
            }

            string temporaryPath = state.Path + ".tmp";
            long written;

            try
            {
                Directory.CreateDirectory(_cacheDirectory);

                using (FileStream stream = new(temporaryPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
                {
                    stream.SetLength(size);

                    using MemoryMappedFile file = MemoryMappedFile.CreateFromFile(
                        stream, null, size, MemoryMappedFileAccess.ReadWrite, HandleInheritability.None, leaveOpen: true);
                    using MemoryMappedViewAccessor view = file.CreateViewAccessor(0, size, MemoryMappedFileAccess.ReadWrite);

                    byte* pointer = null;

                    view.SafeMemoryMappedViewHandle.AcquirePointer(ref pointer);

                    try
                    {
                        nuint dataSize = (nuint)size;
                        Result result = _api.GetPipelineCacheData(
                            _device, state.Cache, &dataSize, pointer + view.PointerOffset);

                        if (result != Result.Success)
                        {
                            Logger.Warning?.PrintMsg(
                                LogClass.Gpu,
                                $"Unable to read Vulkan pipeline cache for persistence: {result}.");

                            Delete(temporaryPath);

                            return;
                        }

                        written = (long)dataSize;
                    }
                    finally
                    {
                        view.SafeMemoryMappedViewHandle.ReleasePointer();
                    }

                    view.Flush();
                }

                if (written != size)
                {
                    using FileStream stream = new(temporaryPath, FileMode.Open, FileAccess.Write, FileShare.None);

                    stream.SetLength(written);
                }

                File.Move(temporaryPath, state.Path, overwrite: true);

                string message =
                    $"Vulkan {state.Description} pipeline cache {(final ? "saved" : "checkpointed")}: {FormatSize(written)}.";

                if (final)
                {
                    Logger.Notice.PrintMsg(LogClass.Gpu, message);
                }
                else
                {
                    Logger.Info?.PrintMsg(LogClass.Gpu, message);
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Logger.Warning?.PrintMsg(LogClass.Gpu, $"Failed to persist Vulkan pipeline cache: {exception.Message}");

                Delete(temporaryPath);
            }
        }

        /// <summary>
        /// Removes a half written snapshot, so the next attempt is not confused by it. Best
        /// effort: if it cannot be removed it is overwritten anyway, being a fixed path.
        /// </summary>
        private static void Delete(string path)
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Nothing to be done about it, and nothing depends on it having worked.
            }
        }

        private static string FormatSize(long size)
        {
            return size >= 1024 * 1024
                ? $"{size / (1024.0 * 1024.0):F2} MiB"
                : $"{size / 1024.0:F2} KiB";
        }

        public unsafe void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;

            foreach (CacheState state in _workerStates)
            {
                _api.DestroyPipelineCache(_device, state.Cache, null);
            }

            _api.DestroyPipelineCache(_device, _mainState.Cache, null);
        }
    }
}
