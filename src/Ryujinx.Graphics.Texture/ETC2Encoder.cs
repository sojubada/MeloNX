using Ryujinx.Common;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Texture.Encoders;
using System;

namespace Ryujinx.Graphics.Texture
{
    public static class ETC2Encoder
    {
        private const int BlockWidth = 4;
        private const int BlockHeight = 4;

        /// <summary>
        /// Encodes a RGBA8 image into the ETC2 RGB8 format, discarding the alpha channel.
        /// </summary>
        public static MemoryOwner<byte> EncodeRgb(Memory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            return Encode(data, width, height, depth, levels, layers, false);
        }

        /// <summary>
        /// Encodes a RGBA8 image into the ETC2 RGBA8 format, with the alpha channel stored on a EAC block.
        /// </summary>
        public static MemoryOwner<byte> EncodeRgba(Memory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            return Encode(data, width, height, depth, levels, layers, true);
        }

        private static MemoryOwner<byte> Encode(Memory<byte> data, int width, int height, int depth, int levels, int layers, bool withAlpha)
        {
            int blockSize = withAlpha ? 16 : 8;
            int size = 0;

            for (int l = 0; l < levels; l++)
            {
                int w = BitUtils.DivRoundUp(Math.Max(1, width >> l), BlockWidth);
                int h = BitUtils.DivRoundUp(Math.Max(1, height >> l), BlockHeight);

                size += w * h * blockSize * Math.Max(1, depth >> l) * layers;
            }

            MemoryOwner<byte> output = MemoryOwner<byte>.Rent(size);
            Memory<byte> outputMemory = output.Memory;

            int imageBaseIOffs = 0;
            int imageBaseOOffs = 0;

            for (int l = 0; l < levels; l++)
            {
                int w = BitUtils.DivRoundUp(width, BlockWidth);
                int h = BitUtils.DivRoundUp(height, BlockHeight);

                for (int l2 = 0; l2 < layers; l2++)
                {
                    for (int z = 0; z < depth; z++)
                    {
                        ETC2BlockEncoder.Encode(
                            outputMemory[imageBaseOOffs..],
                            data[imageBaseIOffs..],
                            width,
                            height,
                            withAlpha,
                            true);

                        imageBaseIOffs += width * height * 4;
                        imageBaseOOffs += w * h * blockSize;
                    }
                }

                width = Math.Max(1, width >> 1);
                height = Math.Max(1, height >> 1);
                depth = Math.Max(1, depth >> 1);
            }

            return output;
        }
    }
}
