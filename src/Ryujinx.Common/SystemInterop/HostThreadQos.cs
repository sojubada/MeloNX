using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Common.SystemInterop
{
    /// <summary>
    /// Darwin thread QoS for the emulator's own threads (iOS/tvOS).
    ///
    /// Threads started by .NET get the default QoS, so the scheduler is free to put
    /// guest CPU and GPU threads on the efficiency cores (the A15 has 2 performance
    /// + 4 efficiency cores). User-interactive QoS for the threads a frame waits on,
    /// and a lower one for background shader compiles, keeps the performance cores
    /// for the game. No-op elsewhere or if the call fails.
    /// </summary>
    public static partial class HostThreadQos
    {
        private const int QosClassUserInteractive = 0x21;
        private const int QosClassUserInitiated = 0x19;
        private const int QosClassUtility = 0x11;

        [LibraryImport("libc")]
        private static partial int pthread_set_qos_class_self_np(int qosClass, int relativePriority);

        /// <summary>Guest CPU threads, the GPU thread and the render loop.</summary>
        public static void UserInteractive() => Set(QosClassUserInteractive);

        /// <summary>Work a frame may be waiting on (on-demand shader compiles).</summary>
        public static void UserInitiated() => Set(QosClassUserInitiated);

        /// <summary>Background work (shader precompiles).</summary>
        public static void Utility() => Set(QosClassUtility);

        private static void Set(int qos)
        {
            if (!OperatingSystem.IsIOS() && !OperatingSystem.IsTvOS())
            {
                return;
            }

            try
            {
                pthread_set_qos_class_self_np(qos, 0);
            }
            catch
            {
                // Not fatal: the thread keeps the default QoS.
            }
        }
    }
}
