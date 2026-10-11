using NUnit.Framework;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Texture;
using System;

namespace Ryujinx.Tests.Graphics
{
    public class ETC2TranscoderTests
    {
        [TestCase(2, 1, 1, 1, 1, 1)]
        [TestCase(3, 1, 1, 1, 1, 1)]
        [TestCase(7, 1, 1, 1, 1, 1)]
        [TestCase(2, 7, 5, 3, 3, 2)]
        [TestCase(3, 7, 5, 3, 3, 2)]
        [TestCase(7, 7, 5, 3, 3, 2)]
        [TestCase(2, 68, 65, 1, 2, 1)]
        [TestCase(3, 68, 65, 1, 2, 1)]
        [TestCase(7, 68, 65, 1, 2, 1)]
        public void MatchesFullDecodeAndEncode(int format, int width, int height, int depth, int levels, int layers)
        {
            int size = 0;
            for (int level = 0; level < levels; level++)
            {
                size += ((Math.Max(1, width >> level) + 3) / 4) *
                    ((Math.Max(1, height >> level) + 3) / 4) *
                    Math.Max(1, depth >> level) * layers * 16;
            }

            byte[] source = new byte[size];
            new Random(12345).NextBytes(source);

            // Exercise every BC7 mode, including the invalid mode's transparent-black result.
            if (format == 7)
            {
                for (int block = 0; block < size / 16; block++)
                {
                    int mode = block % 9;
                    source[block * 16] = mode == 8 ? (byte)0 :
                        (byte)((source[block * 16] & (0xff << (mode + 1))) | (1 << mode));
                }
            }

            using MemoryOwner<byte> decoded = format switch
            {
                2 => BCnDecoder.DecodeBC2(source, width, height, depth, levels, layers),
                3 => BCnDecoder.DecodeBC3(source, width, height, depth, levels, layers),
                _ => BCnDecoder.DecodeBC7(source, width, height, depth, levels, layers),
            };
            using MemoryOwner<byte> expected = ETC2Encoder.EncodeRgba(decoded.Memory, width, height, depth, levels, layers);
            using MemoryOwner<byte> actual = format switch
            {
                2 => ETC2Transcoder.TranscodeBC2ToEtc2Rgba(source, width, height, depth, levels, layers),
                3 => ETC2Transcoder.TranscodeBC3ToEtc2Rgba(source, width, height, depth, levels, layers),
                _ => ETC2Transcoder.TranscodeBC7ToEtc2Rgba(source, width, height, depth, levels, layers),
            };

            Assert.That(actual.Length, Is.EqualTo(size));
            Assert.That(actual.Span.SequenceEqual(expected.Span), Is.True,
                "Block transcoding must match full decoding/re-encoding, including partial edge blocks and mip/layer ordering.");
        }
    }
}
