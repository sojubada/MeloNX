using NUnit.Framework;
using Ryujinx.Audio.Common;

namespace Ryujinx.Tests.Audio.Common
{
    class AudioBufferTests
    {
        [Test]
        public void HostTagsAreUniqueWhenGuestBufferAddressIsReused()
        {
            AudioBuffer first = new() { DataPointer = 0x1000 };
            AudioBuffer second = new() { DataPointer = 0x1000 };

            Assert.That(second.HostTag, Is.Not.EqualTo(first.HostTag));
        }
    }
}
