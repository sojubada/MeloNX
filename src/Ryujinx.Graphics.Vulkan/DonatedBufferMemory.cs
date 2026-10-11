using System;

namespace Ryujinx.Graphics.Vulkan
{
    public static class DonatedBufferMemory
    {
        private static readonly object _lock = new();
        private static nint _address;
        private static ulong _size;
        private static bool _claimed;

        public static bool Offer(nint address, ulong size)
        {
            lock (_lock)
            {
                if (_claimed || address == 0 || size == 0 || size > (ulong)nint.MaxValue ||
                    (ulong)(nuint)address > ulong.MaxValue - size)
                {
                    return false;
                }

                _address = address;
                _size = size;
                return true;
            }
        }

        public static bool Withdraw()
        {
            lock (_lock)
            {
                if (_claimed)
                {
                    return false;
                }

                _address = 0;
                _size = 0;
                return true;
            }
        }

        internal static bool TryClaim(out nint address, out ulong size)
        {
            lock (_lock)
            {
                address = 0;
                size = 0;
                if (_claimed || _address == 0)
                {
                    return false;
                }

                _claimed = true;
                address = _address;
                size = _size;
                return true;
            }
        }

        internal static void Release()
        {
            lock (_lock)
            {
                _claimed = false;
            }
        }
    }
}
