using Silk.NET.Vulkan;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Vulkan.MoltenVK
{
    internal static partial class MoltenVkMetalInterop
    {
        private const string ObjCRuntime = "/usr/lib/libobjc.A.dylib";

        [LibraryImport(ObjCRuntime, EntryPoint = "sel_registerName", StringMarshalling = StringMarshalling.Utf8)]
        private static partial nint RegisterSelector(string name);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        [return: MarshalAs(UnmanagedType.I1)]
        private static partial bool GetBool(nint receiver, nint selector);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        [return: MarshalAs(UnmanagedType.I1)]
        private static partial bool RespondsToSelector(nint receiver, nint selector, nint argument);

        [LibraryImport("libMoltenVK.dylib", EntryPoint = "vkGetMTLDeviceMVK")]
        private static partial void GetMetalDevice(nint physicalDevice, out nint metalDevice);

        [LibraryImport("libMoltenVK.dylib", EntryPoint = "vkGetMTLCommandQueueMVK")]
        private static partial void GetMetalCommandQueue(nint queue, out nint metalCommandQueue);

        [LibraryImport("libMoltenVK.dylib", EntryPoint = "vkGetMTLTextureMVK")]
        private static partial void GetMetalTexture(nint image, out nint metalTexture);

        public static nint GetMetalDevice(PhysicalDevice physicalDevice)
        {
            GetMetalDevice((nint)physicalDevice.Handle, out nint metalDevice);
            return metalDevice;
        }

        public static bool SupportsBcTextureCompression(PhysicalDevice physicalDevice)
        {
            nint metalDevice = GetMetalDevice(physicalDevice);
            nint selector = RegisterSelector("supportsBCTextureCompression");

            return metalDevice != 0 &&
                RespondsToSelector(metalDevice, RegisterSelector("respondsToSelector:"), selector) &&
                GetBool(metalDevice, selector);
        }

        public static nint GetMetalCommandQueue(Queue queue)
        {
            GetMetalCommandQueue((nint)queue.Handle, out nint metalCommandQueue);
            return metalCommandQueue;
        }

        public static nint GetMetalTexture(Image image)
        {
            GetMetalTexture((nint)image.Handle, out nint metalTexture);
            return metalTexture;
        }
    }
}
