using Ryujinx.Common;
using Ryujinx.Common.Memory;
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Ryujinx.Graphics.Texture.Astc
{
    /// <summary>
    /// Fast ASTC 4x4 LDR encoder, used to re-compress textures that were decompressed on the CPU.
    /// </summary>
    public static class AstcEncoder
    {
        private const int BlockWidth = 4;
        private const int BlockHeight = 4;
        private const int BlockSize = 16;
        private const int TexelCount = BlockWidth * BlockHeight;

        // Block header: 11 bits of block mode, 2 bits of partition count and 4 bits of endpoint mode.
        private const int HeaderBits = 17;

        private const int CemRgbDirect = 8;
        private const int CemRgbaDirect = 12;

        /// <summary>
        /// Quantization level of a sequence of integers encoded with the ASTC integer sequence encoding.
        /// </summary>
        private sealed class Quantization
        {
            public readonly int MaxValue;
            public readonly IntegerEncoded Encoding;

            /// <summary>Unquantized value for each encoded value.</summary>
            public readonly int[] Unquantized;

            /// <summary>Encoded value with the closest unquantized value, for each color value.</summary>
            public readonly byte[] Quantize;

            public Quantization(int maxValue, bool weight)
            {
                MaxValue = maxValue;
                Encoding = IntegerEncoded.CreateEncoding(maxValue);
                Unquantized = new int[maxValue + 1];

                for (int i = 0; i <= maxValue; i++)
                {
                    Unquantized[i] = weight ? UnquantizeWeight(Encoding, i) : UnquantizeColor(Encoding, i);
                }

                if (weight)
                {
                    return;
                }

                Quantize = new byte[256];

                for (int v = 0; v < Quantize.Length; v++)
                {
                    int best = 0;
                    int bestDiff = int.MaxValue;

                    for (int i = 0; i <= maxValue; i++)
                    {
                        int diff = Math.Abs(Unquantized[i] - v);

                        if (diff < bestDiff)
                        {
                            best = i;
                            bestDiff = diff;
                        }
                    }

                    Quantize[v] = (byte)best;
                }
            }
        }

        /// <summary>
        /// A block encoding configuration: endpoint mode, weight planes and quantization levels.
        /// </summary>
        private sealed class BlockConfig
        {
            public readonly int Cem;
            public readonly int Components;
            public readonly bool DualPlane;
            public readonly int WeightBits;
            public readonly ushort BlockMode;
            public readonly Quantization Weights;
            public readonly Quantization Endpoints;

            public BlockConfig(int cem, int weightMaxValue, bool dualPlane)
            {
                Cem = cem;
                Components = cem == CemRgbaDirect ? 4 : 3;
                DualPlane = dualPlane;
                Weights = new Quantization(weightMaxValue, weight: true);
                WeightBits = Weights.Encoding.GetBitLength(dualPlane ? TexelCount * 2 : TexelCount);

                // Dual plane blocks also store the channel using the second plane, with 2 bits.
                int colorBits = 128 - HeaderBits - WeightBits - (dualPlane ? 2 : 0);

                Endpoints = new Quantization(GetEndpointMaxValue(Components * 2, colorBits), weight: false);
                BlockMode = GetBlockMode(weightMaxValue, dualPlane);
            }
        }

        private static readonly BlockConfig[] _rgbConfigs;
        private static readonly BlockConfig[] _rgbaConfigs;

        private static readonly byte[] _tritPacking;
        private static readonly byte[] _quintPacking;

        static AstcEncoder()
        {
            // Invert the decoder tables, preferring the smallest encoding for each set of values so that
            // trailing zero values of a partial group only need zero bits, which may then be omitted.
            _tritPacking = new byte[3 * 3 * 3 * 3 * 3];

            for (int packed = 255; packed >= 0; packed--)
            {
                ReadOnlySpan<byte> t = IntegerEncoded.GetTritEncoding(packed);
                _tritPacking[t[0] + 3 * t[1] + 9 * t[2] + 27 * t[3] + 81 * t[4]] = (byte)packed;
            }

            _quintPacking = new byte[5 * 5 * 5];

            for (int packed = 127; packed >= 0; packed--)
            {
                ReadOnlySpan<byte> q = IntegerEncoded.GetQuintEncoding(packed);
                _quintPacking[q[0] + 5 * q[1] + 25 * q[2]] = (byte)packed;
            }

            // Single plane with 8, 12 and 16 weight levels, and dual plane with 3 and 4 weight levels.
            // Fewer weight levels leave more bits for the endpoints.
            _rgbConfigs = CreateConfigs(CemRgbDirect);
            _rgbaConfigs = CreateConfigs(CemRgbaDirect);
        }

        private static BlockConfig[] CreateConfigs(int cem)
        {
            return
            [
                new(cem, 7, false),
                new(cem, 11, false),
                new(cem, 15, false),
                new(cem, 2, true),
                new(cem, 3, true),
            ];
        }

        /// <summary>
        /// Encodes a RGBA8 image into the ASTC 4x4 format.
        /// </summary>
        public static MemoryOwner<byte> Encode4x4(Memory<byte> data, int width, int height, int depth, int levels, int layers)
        {
            int size = 0;

            for (int l = 0; l < levels; l++)
            {
                int w = BitUtils.DivRoundUp(Math.Max(1, width >> l), BlockWidth);
                int h = BitUtils.DivRoundUp(Math.Max(1, height >> l), BlockHeight);

                size += w * h * BlockSize * Math.Max(1, depth >> l) * layers;
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
                        EncodeImage(outputMemory[imageBaseOOffs..], data[imageBaseIOffs..], width, height);

                        imageBaseIOffs += width * height * 4;
                        imageBaseOOffs += w * h * BlockSize;
                    }
                }

                width = Math.Max(1, width >> 1);
                height = Math.Max(1, height >> 1);
                depth = Math.Max(1, depth >> 1);
            }

            return output;
        }

        private static void EncodeImage(Memory<byte> outputStorage, ReadOnlyMemory<byte> data, int width, int height)
        {
            int widthInBlocks = BitUtils.DivRoundUp(width, BlockWidth);
            int heightInBlocks = BitUtils.DivRoundUp(height, BlockHeight);

            Parallel.For(0, heightInBlocks, yInBlocks =>
            {
                Span<ulong> output = MemoryMarshal.Cast<byte, ulong>(outputStorage.Span);
                ReadOnlySpan<byte> input = data.Span;
                Span<byte> texels = stackalloc byte[TexelCount * 4];

                for (int xInBlocks = 0; xInBlocks < widthInBlocks; xInBlocks++)
                {
                    int x = xInBlocks * BlockWidth;
                    int y = yInBlocks * BlockHeight;

                    // Texels outside the image are filled by clamping, so they do not affect the result.
                    for (int ty = 0; ty < BlockHeight; ty++)
                    {
                        int sy = Math.Min(y + ty, height - 1);

                        for (int tx = 0; tx < BlockWidth; tx++)
                        {
                            int sx = Math.Min(x + tx, width - 1);

                            input.Slice((sy * width + sx) * 4, 4).CopyTo(texels.Slice((ty * BlockWidth + tx) * 4, 4));
                        }
                    }

                    EncodeBlock(texels, out ulong low, out ulong high);

                    int offset = (yInBlocks * widthInBlocks + xInBlocks) * 2;
                    output[offset] = low;
                    output[offset + 1] = high;
                }
            });
        }

        private static void EncodeBlock(ReadOnlySpan<byte> texels, out ulong low, out ulong high)
        {
            bool solid = true;
            bool opaque = true;

            for (int i = 0; i < TexelCount; i++)
            {
                solid &= texels.Slice(i * 4, 4).SequenceEqual(texels[..4]);
                opaque &= texels[i * 4 + 3] == 0xFF;
            }

            if (solid)
            {
                EncodeVoidExtent(texels, out low, out high);

                return;
            }

            BlockConfig[] configs = opaque ? _rgbConfigs : _rgbaConfigs;
            int components = opaque ? 3 : 4;

            // Weights of the first plane, followed by weights of the second plane, if any.
            Span<float> endpoints = stackalloc float[8];
            Span<byte> weights = stackalloc byte[TexelCount * 2];
            Span<int> quantized = stackalloc int[8];

            Span<byte> bestWeights = stackalloc byte[TexelCount * 2];
            Span<int> bestQuantized = stackalloc int[8];
            BlockConfig bestConfig = null;
            int bestPlaneChannel = -1;
            long bestError = long.MaxValue;

            foreach (BlockConfig config in configs)
            {
                int firstChannel = config.DualPlane ? 0 : -1;
                int lastChannel = config.DualPlane ? components - 1 : -1;

                for (int planeChannel = firstChannel; planeChannel <= lastChannel; planeChannel++)
                {
                    ComputeEndpoints(texels, components, planeChannel, endpoints);

                    // Refine the endpoints from the weights chosen for the previous endpoints, keeping the best.
                    for (int iteration = 0; iteration < 3; iteration++)
                    {
                        QuantizeEndpoints(config, endpoints, quantized);

                        long error = ComputeWeights(texels, config, planeChannel, quantized, weights);

                        if (error < bestError)
                        {
                            bestError = error;
                            bestConfig = config;
                            bestPlaneChannel = planeChannel;
                            weights.CopyTo(bestWeights);
                            quantized.CopyTo(bestQuantized);
                        }

                        if (error == 0 || !RefineEndpoints(texels, config, planeChannel, weights, endpoints))
                        {
                            break;
                        }
                    }

                    if (bestError == 0)
                    {
                        break;
                    }
                }
            }

            PackBlock(bestConfig, bestPlaneChannel, bestQuantized, bestWeights, out low, out high);
        }

        private static void EncodeVoidExtent(ReadOnlySpan<byte> texels, out ulong low, out ulong high)
        {
            // Void extent block mode (0x1FC), LDR, with all extent coordinates set to ones (no extent).
            low = 0xFFFFFFFFFFFFFDFCUL;
            high = 0;

            for (int c = 0; c < 4; c++)
            {
                high |= (ulong)(texels[c] * 0x101) << (c * 16);
            }
        }

        /// <summary>
        /// Finds initial endpoints. The channels sharing the first weight plane use the extremes of the
        /// texels along their principal axis, while the channel on the second plane uses its range.
        /// </summary>
        /// <param name="texels">RGBA8 texels of the block</param>
        /// <param name="components">Number of components encoded on the block</param>
        /// <param name="planeChannel">Channel using the second weight plane, or -1 for single plane blocks</param>
        /// <param name="endpoints">Output endpoints</param>
        private static void ComputeEndpoints(ReadOnlySpan<byte> texels, int components, int planeChannel, Span<float> endpoints)
        {
            Span<float> mean = stackalloc float[4];

            for (int i = 0; i < TexelCount; i++)
            {
                for (int c = 0; c < components; c++)
                {
                    mean[c] += texels[i * 4 + c];
                }
            }

            for (int c = 0; c < components; c++)
            {
                mean[c] /= TexelCount;
            }

            Span<float> cov = stackalloc float[16];

            for (int i = 0; i < TexelCount; i++)
            {
                for (int a = 0; a < components; a++)
                {
                    float da = texels[i * 4 + a] - mean[a];

                    for (int b = 0; b < components; b++)
                    {
                        cov[a * 4 + b] += da * (texels[i * 4 + b] - mean[b]);
                    }
                }
            }

            // Power iteration for the principal axis, starting from the bounding box diagonal.
            Span<float> axis = stackalloc float[4];
            Span<float> next = stackalloc float[4];
            Span<byte> min = stackalloc byte[4];
            Span<byte> max = stackalloc byte[4];

            for (int c = 0; c < components; c++)
            {
                min[c] = 255;
                max[c] = 0;

                for (int i = 0; i < TexelCount; i++)
                {
                    min[c] = Math.Min(min[c], texels[i * 4 + c]);
                    max[c] = Math.Max(max[c], texels[i * 4 + c]);
                }

                axis[c] = c == planeChannel ? 0 : max[c] - min[c];
            }

            for (int iteration = 0; iteration < 8; iteration++)
            {
                float length = 0;

                for (int a = 0; a < components; a++)
                {
                    next[a] = 0;

                    if (a == planeChannel)
                    {
                        continue;
                    }

                    for (int b = 0; b < components; b++)
                    {
                        if (b != planeChannel)
                        {
                            next[a] += cov[a * 4 + b] * axis[b];
                        }
                    }

                    length = Math.Max(length, Math.Abs(next[a]));
                }

                if (length == 0)
                {
                    break;
                }

                for (int c = 0; c < components; c++)
                {
                    axis[c] = next[c] / length;
                }
            }

            float axisLengthSq = 0;

            for (int c = 0; c < components; c++)
            {
                axisLengthSq += axis[c] * axis[c];
            }

            if (axisLengthSq == 0)
            {
                for (int c = 0; c < components; c++)
                {
                    axis[c] = c == planeChannel ? 0 : 1;
                    axisLengthSq += axis[c];
                }
            }

            float minT = float.MaxValue, maxT = float.MinValue;

            for (int i = 0; i < TexelCount; i++)
            {
                float t = 0;

                for (int c = 0; c < components; c++)
                {
                    t += (texels[i * 4 + c] - mean[c]) * axis[c];
                }

                minT = Math.Min(minT, t);
                maxT = Math.Max(maxT, t);
            }

            for (int c = 0; c < 4; c++)
            {
                if (c >= components)
                {
                    endpoints[c] = endpoints[4 + c] = 255;
                }
                else if (c == planeChannel)
                {
                    endpoints[c] = min[c];
                    endpoints[4 + c] = max[c];
                }
                else
                {
                    endpoints[c] = mean[c] + axis[c] * minT / axisLengthSq;
                    endpoints[4 + c] = mean[c] + axis[c] * maxT / axisLengthSq;
                }
            }
        }

        /// <summary>
        /// Quantizes the endpoints, ordered so that the decoder does not apply blue contraction.
        /// </summary>
        private static void QuantizeEndpoints(BlockConfig config, ReadOnlySpan<float> endpoints, Span<int> quantized)
        {
            Quantization quant = config.Endpoints;

            for (int c = 0; c < config.Components; c++)
            {
                quantized[c * 2] = quant.Quantize[Math.Clamp((int)MathF.Round(endpoints[c]), 0, 255)];
                quantized[c * 2 + 1] = quant.Quantize[Math.Clamp((int)MathF.Round(endpoints[4 + c]), 0, 255)];
            }

            int sum0 = 0;
            int sum1 = 0;

            for (int c = 0; c < 3; c++)
            {
                sum0 += quant.Unquantized[quantized[c * 2]];
                sum1 += quant.Unquantized[quantized[c * 2 + 1]];
            }

            // If the second endpoint sum is smaller, the decoder swaps the endpoints and applies blue
            // contraction, so swap them here instead. The weights are computed after this.
            if (sum1 < sum0)
            {
                for (int c = 0; c < config.Components; c++)
                {
                    (quantized[c * 2], quantized[c * 2 + 1]) = (quantized[c * 2 + 1], quantized[c * 2]);
                }
            }
        }

        /// <summary>
        /// Chooses the weights with the lowest error for each texel, and returns the total block error.
        /// </summary>
        private static long ComputeWeights(
            ReadOnlySpan<byte> texels,
            BlockConfig config,
            int planeChannel,
            ReadOnlySpan<int> quantized,
            Span<byte> weights)
        {
            Span<int> e0 = stackalloc int[4];
            Span<int> e1 = stackalloc int[4];

            for (int c = 0; c < 4; c++)
            {
                if (c < config.Components)
                {
                    e0[c] = config.Endpoints.Unquantized[quantized[c * 2]] * 0x101;
                    e1[c] = config.Endpoints.Unquantized[quantized[c * 2 + 1]] * 0x101;
                }
                else
                {
                    e0[c] = e1[c] = 0xFFFF;
                }
            }

            long totalError = 0;
            int[] levels = config.Weights.Unquantized;
            int planes = config.DualPlane ? 2 : 1;

            for (int i = 0; i < TexelCount; i++)
            {
                for (int plane = 0; plane < planes; plane++)
                {
                    int bestError = int.MaxValue;
                    int best = 0;

                    for (int w = 0; w < levels.Length; w++)
                    {
                        int weight = levels[w];
                        int error = 0;

                        for (int c = 0; c < 4; c++)
                        {
                            if ((c == planeChannel ? 1 : 0) != plane)
                            {
                                continue;
                            }

                            int value = (e0[c] * (64 - weight) + e1[c] * weight + 32) >> 6;
                            int diff = ((value + 128) / 257) - texels[i * 4 + c];
                            error += diff * diff;
                        }

                        if (error < bestError)
                        {
                            bestError = error;
                            best = w;
                        }
                    }

                    weights[plane * TexelCount + i] = (byte)best;
                    totalError += bestError;
                }
            }

            return totalError;
        }

        /// <summary>
        /// Computes the least squares endpoints for the given texel weights.
        /// </summary>
        /// <returns>True if any endpoint was updated, false if all weights of each plane are equal</returns>
        private static bool RefineEndpoints(
            ReadOnlySpan<byte> texels,
            BlockConfig config,
            int planeChannel,
            ReadOnlySpan<byte> weights,
            Span<float> endpoints)
        {
            bool updated = false;

            Span<float> ax = stackalloc float[4];
            Span<float> bx = stackalloc float[4];

            for (int plane = 0; plane < (config.DualPlane ? 2 : 1); plane++)
            {
                float aa = 0, ab = 0, bb = 0;

                ax.Clear();
                bx.Clear();

                for (int i = 0; i < TexelCount; i++)
                {
                    float t = config.Weights.Unquantized[weights[plane * TexelCount + i]] / 64f;
                    float s = 1 - t;

                    aa += s * s;
                    ab += s * t;
                    bb += t * t;

                    for (int c = 0; c < config.Components; c++)
                    {
                        ax[c] += s * texels[i * 4 + c];
                        bx[c] += t * texels[i * 4 + c];
                    }
                }

                float det = aa * bb - ab * ab;

                if (MathF.Abs(det) < 1e-6f)
                {
                    continue;
                }

                float invDet = 1 / det;

                for (int c = 0; c < config.Components; c++)
                {
                    if ((c == planeChannel ? 1 : 0) == plane)
                    {
                        endpoints[c] = (bb * ax[c] - ab * bx[c]) * invDet;
                        endpoints[4 + c] = (aa * bx[c] - ab * ax[c]) * invDet;
                    }
                }

                updated = true;
            }

            return updated;
        }

        private static void PackBlock(
            BlockConfig config,
            int planeChannel,
            ReadOnlySpan<int> quantized,
            ReadOnlySpan<byte> weights,
            out ulong low,
            out ulong high)
        {
            BitWriter block = new();

            block.Write(config.BlockMode, 11);
            block.Write(0, 2); // Single partition.
            block.Write(config.Cem, 4);

            WriteIntegerSequence(ref block, config.Endpoints.Encoding, quantized[..(config.Components * 2)]);

            // The second plane channel is stored right below the weights.
            if (config.DualPlane)
            {
                block.Truncate(128 - config.WeightBits - 2);
                block.Write(planeChannel, 2);
            }

            // Weights of both planes are interleaved for each texel.
            int planes = config.DualPlane ? 2 : 1;
            Span<int> weightValues = stackalloc int[TexelCount * planes];

            for (int i = 0; i < TexelCount; i++)
            {
                for (int plane = 0; plane < planes; plane++)
                {
                    weightValues[i * planes + plane] = weights[plane * TexelCount + i];
                }
            }

            // Weights are stored bit reversed, starting from the top of the block.
            BitWriter weightBits = new();

            WriteIntegerSequence(ref weightBits, config.Weights.Encoding, weightValues);

            low = block.Low | ReverseBits(weightBits.High);
            high = block.High | ReverseBits(weightBits.Low);
        }

        private static void WriteIntegerSequence(ref BitWriter writer, IntegerEncoded encoding, ReadOnlySpan<int> values)
        {
            int bits = encoding.NumberBits;
            int totalBits = encoding.GetBitLength(values.Length);
            int start = writer.Position;

            Span<int> m = stackalloc int[5];

            switch (encoding.GetEncoding())
            {
                case IntegerEncoded.EIntegerEncoding.JustBits:
                    foreach (int value in values)
                    {
                        writer.Write(value, bits);
                    }

                    break;

                case IntegerEncoded.EIntegerEncoding.Trit:
                    for (int i = 0; i < values.Length; i += 5)
                    {
                        int index = 0;

                        for (int j = 0, scale = 1; j < 5; j++, scale *= 3)
                        {
                            int value = i + j < values.Length ? values[i + j] : 0;

                            m[j] = value & ((1 << bits) - 1);
                            index += (value >> bits) * scale;
                        }

                        int packed = _tritPacking[index];

                        writer.Write(m[0], bits);
                        writer.Write(packed, 2);
                        writer.Write(m[1], bits);
                        writer.Write(packed >> 2, 2);
                        writer.Write(m[2], bits);
                        writer.Write(packed >> 4, 1);
                        writer.Write(m[3], bits);
                        writer.Write(packed >> 5, 2);
                        writer.Write(m[4], bits);
                        writer.Write(packed >> 7, 1);
                    }

                    break;

                case IntegerEncoded.EIntegerEncoding.Quint:
                    for (int i = 0; i < values.Length; i += 3)
                    {
                        int index = 0;

                        for (int j = 0, scale = 1; j < 3; j++, scale *= 5)
                        {
                            int value = i + j < values.Length ? values[i + j] : 0;

                            m[j] = value & ((1 << bits) - 1);
                            index += (value >> bits) * scale;
                        }

                        int packed = _quintPacking[index];

                        writer.Write(m[0], bits);
                        writer.Write(packed, 3);
                        writer.Write(m[1], bits);
                        writer.Write(packed >> 3, 2);
                        writer.Write(m[2], bits);
                        writer.Write(packed >> 5, 2);
                    }

                    break;
            }

            // Partial groups are written in full, drop the bits past the end of the sequence.
            writer.Truncate(start + totalBits);
        }

        private struct BitWriter
        {
            public ulong Low;
            public ulong High;
            public int Position;

            public void Write(int value, int count)
            {
                for (int i = 0; i < count; i++, Position++)
                {
                    if (((value >> i) & 1) == 0 || Position >= 128)
                    {
                        continue;
                    }

                    if (Position < 64)
                    {
                        Low |= 1UL << Position;
                    }
                    else
                    {
                        High |= 1UL << (Position - 64);
                    }
                }
            }

            /// <summary>
            /// Moves the write position, clearing any bits that were written at or past it.
            /// </summary>
            public void Truncate(int position)
            {
                if (position < 64)
                {
                    Low &= (1UL << position) - 1;
                    High = 0;
                }
                else if (position < 128)
                {
                    High &= (1UL << (position - 64)) - 1;
                }

                Position = position;
            }
        }

        private static ulong ReverseBits(ulong value)
        {
            value = ((value >> 1) & 0x5555555555555555UL) | ((value & 0x5555555555555555UL) << 1);
            value = ((value >> 2) & 0x3333333333333333UL) | ((value & 0x3333333333333333UL) << 2);
            value = ((value >> 4) & 0x0F0F0F0F0F0F0F0FUL) | ((value & 0x0F0F0F0F0F0F0F0FUL) << 4);

            return System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(value);
        }

        /// <summary>
        /// Gets the block mode for a 4x4 weight grid.
        /// </summary>
        private static ushort GetBlockMode(int weightMaxValue, bool dualPlane)
        {
            (int r, int h) = weightMaxValue switch
            {
                1 => (2, 0),
                2 => (3, 0),
                3 => (4, 0),
                4 => (5, 0),
                5 => (6, 0),
                7 => (7, 0),
                9 => (2, 1),
                11 => (3, 1),
                15 => (4, 1),
                19 => (5, 1),
                23 => (6, 1),
                31 => (7, 1),
                _ => throw new ArgumentOutOfRangeException(nameof(weightMaxValue)),
            };

            // Layout 0 of the block mode table: width = B + 4, height = A + 2.
            const int A = 2;
            const int B = 0;

            return (ushort)(((r >> 1) & 1) | (((r >> 2) & 1) << 1) | ((r & 1) << 4) | (A << 5) | (B << 7) | (h << 9) | ((dualPlane ? 1 : 0) << 10));
        }

        /// <summary>
        /// Gets the largest endpoint range that fits on the available bits, as chosen by the decoder.
        /// </summary>
        private static int GetEndpointMaxValue(int valueCount, int availableBits)
        {
            for (int range = 255; range > 0; range--)
            {
                IntegerEncoded encoding = IntegerEncoded.CreateEncoding(range);

                if (encoding.GetBitLength(valueCount) <= availableBits)
                {
                    // The range may not be representable, use the largest value of the encoding instead.
                    return encoding.GetEncoding() switch
                    {
                        IntegerEncoded.EIntegerEncoding.Trit => (3 << encoding.NumberBits) - 1,
                        IntegerEncoded.EIntegerEncoding.Quint => (5 << encoding.NumberBits) - 1,
                        _ => (1 << encoding.NumberBits) - 1,
                    };
                }
            }

            throw new ArgumentException("Not enough bits for the color endpoints.");
        }

        /// <summary>
        /// Unquantizes a weight to the [0, 64] range, as specified on section C.2.17 of the ASTC spec.
        /// </summary>
        private static int UnquantizeWeight(IntegerEncoded encoding, int value)
        {
            int bitLength = encoding.NumberBits;
            int bitValue = value & ((1 << bitLength) - 1);
            int d = value >> bitLength;

            int result;

            if (encoding.GetEncoding() == IntegerEncoded.EIntegerEncoding.JustBits)
            {
                result = Bits.Replicate(bitValue, bitLength, 6);
            }
            else
            {
                int a = (bitValue & 1) != 0 ? 0x7F : 0;
                int b = 0;
                int c;

                if (encoding.GetEncoding() == IntegerEncoded.EIntegerEncoding.Trit)
                {
                    switch (bitLength)
                    {
                        case 1:
                            c = 50;
                            break;
                        case 2:
                            c = 23;
                            int b2 = (bitValue >> 1) & 1;
                            b = (b2 << 6) | (b2 << 2) | b2;
                            break;
                        default:
                            c = 11;
                            int cb = (bitValue >> 1) & 3;
                            b = (cb << 5) | cb;
                            break;
                    }
                }
                else
                {
                    switch (bitLength)
                    {
                        case 1:
                            c = 28;
                            break;
                        default:
                            c = 13;
                            int b2 = (bitValue >> 1) & 1;
                            b = (b2 << 6) | (b2 << 1);
                            break;
                    }
                }

                result = d * c + b;
                result ^= a;
                result = (a & 0x20) | (result >> 2);
            }

            return result > 32 ? result + 1 : result;
        }

        /// <summary>
        /// Unquantizes a color endpoint value to the [0, 255] range, as specified on section C.2.13 of the ASTC spec.
        /// </summary>
        private static int UnquantizeColor(IntegerEncoded encoding, int value)
        {
            int bitLength = encoding.NumberBits;
            int bitValue = value & ((1 << bitLength) - 1);
            int d = value >> bitLength;

            if (encoding.GetEncoding() == IntegerEncoded.EIntegerEncoding.JustBits)
            {
                return Bits.Replicate(bitValue, bitLength, 8);
            }

            int a = (bitValue & 1) != 0 ? 0x1FF : 0;
            int b;
            int c;

            if (encoding.GetEncoding() == IntegerEncoded.EIntegerEncoding.Trit)
            {
                switch (bitLength)
                {
                    case 1:
                        c = 204;
                        b = 0;
                        break;
                    case 2:
                        c = 93;
                        int b2 = (bitValue >> 1) & 1;
                        b = (b2 << 8) | (b2 << 4) | (b2 << 2) | (b2 << 1);
                        break;
                    case 3:
                        c = 44;
                        int cb = (bitValue >> 1) & 3;
                        b = (cb << 7) | (cb << 2) | cb;
                        break;
                    case 4:
                        c = 22;
                        int dcb = (bitValue >> 1) & 7;
                        b = (dcb << 6) | dcb;
                        break;
                    case 5:
                        c = 11;
                        int edcb = (bitValue >> 1) & 0xF;
                        b = (edcb << 5) | (edcb >> 2);
                        break;
                    default:
                        c = 5;
                        int fedcb = (bitValue >> 1) & 0x1F;
                        b = (fedcb << 4) | (fedcb >> 4);
                        break;
                }
            }
            else
            {
                switch (bitLength)
                {
                    case 1:
                        c = 113;
                        b = 0;
                        break;
                    case 2:
                        c = 54;
                        int b2 = (bitValue >> 1) & 1;
                        b = (b2 << 8) | (b2 << 3) | (b2 << 2);
                        break;
                    case 3:
                        c = 26;
                        int cb = (bitValue >> 1) & 3;
                        b = (cb << 7) | (cb << 1) | (cb >> 1);
                        break;
                    case 4:
                        c = 13;
                        int dcb = (bitValue >> 1) & 7;
                        b = (dcb << 6) | (dcb >> 1);
                        break;
                    default:
                        c = 6;
                        int edcb = (bitValue >> 1) & 0xF;
                        b = (edcb << 5) | (edcb >> 3);
                        break;
                }
            }

            int t = d * c + b;
            t ^= a;

            return (a & 0x80) | (t >> 2);
        }
    }
}
