using Silk.NET.Vulkan;
using System;

namespace Ryujinx.Graphics.Vulkan
{
    static class ResultExtensions
    {
        internal static int DeviceLostCount;

        extension(Result result)
        {
            public bool IsError => result < Result.Success;

            public void ThrowOnError()
            {
                // Only negative result codes are errors.
                if (result.IsError)
                {
                    // tvOS (MoltenVK with MVK_CONFIG_RESUME_LOST_DEVICE=1): one failed Metal
                    // command buffer reports VK_ERROR_DEVICE_LOST and the device carries on.
                    // Throwing here killed the app mid-game (device log); drop the frame instead.
                    if (result == Result.ErrorDeviceLost && OperatingSystem.IsTvOS())
                    {
                        if (System.Threading.Interlocked.Increment(ref ResultExtensions.DeviceLostCount) <= 10)
                        {
                            Ryujinx.Common.Logging.Logger.Warning?.Print(Ryujinx.Common.Logging.LogClass.Gpu,
                                "Vulkan device lost (Metal command buffer error); continuing");
                        }

                        return;
                    }

                    throw new VulkanException(result);
                }
            }
        }
    }

    class VulkanException : Exception
    {
        public VulkanException()
        {
        }

        public VulkanException(Result result) : base($"Unexpected API error \"{result}\".")
        {
        }

        public VulkanException(string message) : base(message)
        {
        }

        public VulkanException(string message, Exception innerException) : base(message, innerException)
        {
        }
    }
}
