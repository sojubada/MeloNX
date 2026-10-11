using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Texture.Encoders;
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Ryujinx.Graphics.Texture
{
    /// <summary>
    /// Converts BCn textures to the ETC2/EAC format of the same block size, one block at a time.
    /// </summary>
    public static class ETC2Transcoder
    {
        private const int TexelsPerBlock = 16;

        /// <summary>
        /// Blocks processed by each parallel work item. Small textures (and small mip levels) are
        /// done on the calling thread, as the scheduling overhead would dominate.
        /// </summary>
        private const int BlocksPerBatch = 256;

        private delegate void BlockTranscoder(ReadOnlySpan<ulong> input, Span<ulong> output);

        /// <summary>
        /// Transcodes BC1 data to ETC2 RGB8 with punchthrough alpha.
        /// </summary>
        public static MemoryOwner<byte> TranscodeBC1ToEtc2Pta(ReadOnlyMemory<byte> data)
        {
            return Transcode(data, 1, TranscodeBC1Blocks);
        }

        /// <summary>
        /// Transcodes BC4 data to EAC R11.
        /// </summary>
        public static MemoryOwner<byte> TranscodeBC4ToEacR11(ReadOnlyMemory<byte> data, bool signed)
        {
            return Transcode(data, 1, signed ? TranscodeBC4BlocksSigned : TranscodeBC4BlocksUnsigned);
        }

        /// <summary>
        /// Transcodes BC5 data to EAC RG11.
        /// </summary>
        public static MemoryOwner<byte> TranscodeBC5ToEacRG11(ReadOnlyMemory<byte> data, bool signed)
        {
            return Transcode(data, 2, signed ? TranscodeBC4BlocksSigned : TranscodeBC4BlocksUnsigned);
        }

        private delegate void RgbaBlockDecoder(Span<byte> output, ReadOnlySpan<byte> input);

        public static MemoryOwner<byte> TranscodeBC2ToEtc2Rgba(ReadOnlyMemory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            return TranscodeRgba(data, width, height, depth, levels, layers, BCnDecoder.DecodeBC2Block);
        }

        public static MemoryOwner<byte> TranscodeBC3ToEtc2Rgba(ReadOnlyMemory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            return TranscodeRgba(data, width, height, depth, levels, layers, BCnDecoder.DecodeBC3Block);
        }

        public static MemoryOwner<byte> TranscodeBC7ToEtc2Rgba(ReadOnlyMemory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            return TranscodeRgba(data, width, height, depth, levels, layers,
                static (output, input) => BC7Decoder.Decode(output, input, 4, 4));
        }

        // BC2/3/7 and ETC2 RGBA all use sixteen bytes per 4x4 block. Only a single decoded
        // block is needed per worker, even for large textures with many mip levels/layers.
        private static MemoryOwner<byte> TranscodeRgba(
            ReadOnlyMemory<byte> data, int width, int height, int depth, int levels, int layers, RgbaBlockDecoder decoder)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(width);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(height);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(depth);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(levels);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(layers);

            MemoryOwner<byte> output = MemoryOwner<byte>.Rent(data.Length);

            try
            {
                int offset = 0;

                for (int level = 0; level < levels; level++)
                {
                    int blocksWide = (width + 3) / 4;
                    int blocksHigh = (height + 3) / 4;
                    int blocksPerSlice = checked(blocksWide * blocksHigh);
                    int blockCount = checked(blocksPerSlice * depth * layers);
                    int size = checked(blockCount * 16);
                    ReadOnlyMemory<byte> source = data.Slice(offset, size);
                    Memory<byte> destination = output.Memory.Slice(offset, size);
                    int levelWidth = width;
                    int levelHeight = height;

                    void ProcessBatch(int batch)
                    {
                        int start = batch * BlocksPerBatch;
                        int count = Math.Min(BlocksPerBatch, blockCount - start);
                        TranscodeRgbaBlocks(source.Span.Slice(start * 16, count * 16),
                            destination.Span.Slice(start * 16, count * 16), decoder,
                            start, blocksWide, blocksPerSlice, levelWidth, levelHeight);
                    }

                    if (blockCount <= BlocksPerBatch)
                    {
                        ProcessBatch(0);
                    }
                    else
                    {
                        Parallel.For(0, (blockCount + BlocksPerBatch - 1) / BlocksPerBatch, ProcessBatch);
                    }

                    offset += size;
                    width = Math.Max(1, width >> 1);
                    height = Math.Max(1, height >> 1);
                    depth = Math.Max(1, depth >> 1);
                }

                data.Span[offset..].CopyTo(output.Span[offset..]);
                return output;
            }
            catch
            {
                output.Dispose();
                throw;
            }
        }

        private static void TranscodeRgbaBlocks(
            ReadOnlySpan<byte> input, Span<byte> output, RgbaBlockDecoder decoder,
            int firstBlock, int blocksWide, int blocksPerSlice, int width, int height)
        {
            Span<byte> rgba = stackalloc byte[64];
            Span<int> pr = stackalloc int[TexelsPerBlock];
            Span<int> pg = stackalloc int[TexelsPerBlock];
            Span<int> pb = stackalloc int[TexelsPerBlock];
            Span<int> pa = stackalloc int[TexelsPerBlock];
            Span<ulong> encoded = MemoryMarshal.Cast<byte, ulong>(output);

            for (int i = 0; i < input.Length / 16; i++)
            {
                decoder(rgba, input.Slice(i * 16, 16));
                int block = (firstBlock + i) % blocksPerSlice;
                int validWidth = Math.Min(4, width - (block % blocksWide) * 4);
                int validHeight = Math.Min(4, height - (block / blocksWide) * 4);

                // Replicate edge texels just like the full-image encoder. Encoded padding in
                // the guest block must not affect the quality of visible texels in small mips.
                for (int t = 0; t < TexelsPerBlock; t++)
                {
                    int pixel = (Math.Min(t / 4, validHeight - 1) * 4 + Math.Min(t % 4, validWidth - 1)) * 4;
                    pr[t] = rgba[pixel];
                    pg[t] = rgba[pixel + 1];
                    pb[t] = rgba[pixel + 2];
                    pa[t] = rgba[pixel + 3];
                }

                encoded[i * 2] = ETC2BlockEncoder.EncodeAlphaBlock(pa);
                encoded[i * 2 + 1] = ETC2BlockEncoder.EncodeRgbBlock(pr, pg, pb, true);
            }
        }

        private static MemoryOwner<byte> Transcode(ReadOnlyMemory<byte> data, int ulongsPerBlock, BlockTranscoder transcoder)
        {
            int blockCount = data.Length / (ulongsPerBlock * sizeof(ulong));
            int ulongCount = blockCount * ulongsPerBlock;

            MemoryOwner<byte> output = MemoryOwner<byte>.Rent(data.Length);
            Memory<byte> outputMemory = output.Memory;

            if (blockCount <= BlocksPerBatch)
            {
                transcoder(
                    MemoryMarshal.Cast<byte, ulong>(data.Span)[..ulongCount],
                    MemoryMarshal.Cast<byte, ulong>(outputMemory.Span)[..ulongCount]);
            }
            else
            {
                int batchCount = (blockCount + BlocksPerBatch - 1) / BlocksPerBatch;

                Parallel.For(0, batchCount, batch =>
                {
                    int start = batch * BlocksPerBatch * ulongsPerBlock;
                    int length = Math.Min(BlocksPerBatch * ulongsPerBlock, ulongCount - start);

                    transcoder(
                        MemoryMarshal.Cast<byte, ulong>(data.Span).Slice(start, length),
                        MemoryMarshal.Cast<byte, ulong>(outputMemory.Span).Slice(start, length));
                });
            }

            // Any trailing bytes that do not form a whole block are left as-is.
            data.Span[(ulongCount * sizeof(ulong))..].CopyTo(outputMemory.Span[(ulongCount * sizeof(ulong))..]);

            return output;
        }

        private static void TranscodeBC1Blocks(ReadOnlySpan<ulong> input, Span<ulong> output)
        {
            Span<int> pr = stackalloc int[TexelsPerBlock];
            Span<int> pg = stackalloc int[TexelsPerBlock];
            Span<int> pb = stackalloc int[TexelsPerBlock];
            Span<bool> transparent = stackalloc bool[TexelsPerBlock];
            Span<uint> palette = stackalloc uint[4];

            for (int i = 0; i < input.Length; i++)
            {
                ulong block = input[i];

                // Runs of identical blocks (flat areas, padding) are very common, and encoding is the slow part.
                if (i != 0 && block == input[i - 1])
                {
                    output[i] = output[i - 1];
                    continue;
                }

                uint c0 = (ushort)block;
                uint c1 = (ushort)(block >> 16);
                uint colorIndices = (uint)(block >> 32);

                // Same palette rules as BCnDecoder, alpha is 0 only for the transparent entry.
                palette[0] = ConvertRgb565ToRgb888(c0) | 0xff000000;
                palette[1] = ConvertRgb565ToRgb888(c1) | 0xff000000;

                if (c0 > c1)
                {
                    palette[2] = Lerp3(palette[0], palette[1]) | 0xff000000;
                    palette[3] = Lerp3(palette[1], palette[0]) | 0xff000000;
                }
                else
                {
                    palette[2] = Average(palette[0], palette[1]) | 0xff000000;
                    palette[3] = 0;
                }

                bool anyTransparent = false;

                for (int t = 0; t < TexelsPerBlock; t++, colorIndices >>= 2)
                {
                    uint color = palette[(int)(colorIndices & 3)];

                    pr[t] = (int)(color & 0xff);
                    pg[t] = (int)((color >> 8) & 0xff);
                    pb[t] = (int)((color >> 16) & 0xff);
                    transparent[t] = color == 0;
                    anyTransparent |= color == 0;
                }

                output[i] = anyTransparent
                    ? ETC2BlockEncoder.EncodePunchthroughBlock(pr, pg, pb, transparent)
                    : ETC2BlockEncoder.EncodeRgbBlock(pr, pg, pb, false);
            }
        }

        private static void TranscodeBC4BlocksUnsigned(ReadOnlySpan<ulong> input, Span<ulong> output)
        {
            TranscodeBC4Blocks(input, output, false);
        }

        private static void TranscodeBC4BlocksSigned(ReadOnlySpan<ulong> input, Span<ulong> output)
        {
            TranscodeBC4Blocks(input, output, true);
        }

        private static void TranscodeBC4Blocks(ReadOnlySpan<ulong> input, Span<ulong> output, bool signed)
        {
            Span<int> values = stackalloc int[TexelsPerBlock];
            Span<int> palette = stackalloc int[8];

            for (int i = 0; i < input.Length; i++)
            {
                ulong block = input[i];

                if (i != 0 && block == input[i - 1])
                {
                    output[i] = output[i - 1];
                    continue;
                }

                int v0 = signed ? (sbyte)block : (byte)block;
                int v1 = signed ? (sbyte)(block >> 8) : (byte)(block >> 8);

                // Same palette rules (and integer rounding) as BCnDecoder.
                palette[0] = v0;
                palette[1] = v1;

                if (v0 > v1)
                {
                    for (int k = 1; k < 7; k++)
                    {
                        palette[k + 1] = ((7 - k) * v0 + k * v1) / 7;
                    }
                }
                else
                {
                    for (int k = 1; k < 5; k++)
                    {
                        palette[k + 1] = ((5 - k) * v0 + k * v1) / 5;
                    }

                    palette[6] = signed ? -128 : 0;
                    palette[7] = signed ? 127 : 255;
                }

                ulong valueIndices = block >> 16;

                for (int t = 0; t < TexelsPerBlock; t++, valueIndices >>= 3)
                {
                    values[t] = palette[(int)(valueIndices & 7)];
                }

                output[i] = ETC2BlockEncoder.EncodeEacBlock(values, signed);
            }
        }

        private static uint ConvertRgb565ToRgb888(uint value)
        {
            uint b = (value & 0x1f) << 19;
            uint g = (value << 5) & 0xfc00;
            uint r = (value >> 8) & 0xf8;

            b |= b >> 5;
            g |= g >> 6;
            r |= r >> 5;

            return r | (g & 0xff00) | (b & 0xff0000);
        }

        /// <summary>
        /// Two thirds of <paramref name="near"/> plus one third of <paramref name="far"/>, per component.
        /// </summary>
        private static uint Lerp3(uint near, uint far)
        {
            uint r = (2 * (near & 0xff) + (far & 0xff)) / 3;
            uint g = (2 * ((near >> 8) & 0xff) + ((far >> 8) & 0xff)) / 3;
            uint b = (2 * ((near >> 16) & 0xff) + ((far >> 16) & 0xff)) / 3;

            return r | (g << 8) | (b << 16);
        }

        private static uint Average(uint color0, uint color1)
        {
            uint carry = color0 & color1;
            uint addHalve = ((color0 ^ color1) >> 1) & 0x7f7f7f;

            return (addHalve + carry) & 0xffffff;
        }
    }
}
