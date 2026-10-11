using System;
using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Ryujinx.Graphics.Texture.Encoders
{
    /// <summary>
    /// Encoder for the ETC2 RGB8 and RGBA8 (ETC2 + EAC alpha) compressed formats.
    /// </summary>
    static class ETC2BlockEncoder
    {
        private const int BlockWidth = 4;
        private const int BlockHeight = 4;

        private static readonly int[][] _etc1Lut =
        [
            [2, 8, -2, -8],
            [5, 17, -5, -17],
            [9, 29, -9, -29],
            [13, 42, -13, -42],
            [18, 60, -18, -60],
            [24, 80, -24, -80],
            [33, 106, -33, -106],
            [47, 183, -47, -183]
        ];

        private static readonly int[] _etc2Lut =
        [
            3, 6, 11, 16, 23, 32, 41, 64
        ];

        private static readonly int[][] _etc2AlphaLut =
        [
            [-3, -6, -9, -15, 2, 5, 8, 14],
            [-3, -7, -10, -13, 2, 6, 9, 12],
            [-2, -5, -8, -13, 1, 4, 7, 12],
            [-2, -4, -6, -13, 1, 3, 5, 12],
            [-3, -6, -8, -12, 2, 5, 7, 11],
            [-3, -7, -9, -11, 2, 6, 8, 10],
            [-4, -7, -8, -11, 3, 6, 7, 10],
            [-3, -5, -8, -11, 2, 4, 7, 10],
            [-2, -6, -8, -10, 1, 5, 7, 9],
            [-2, -5, -8, -10, 1, 4, 7, 9],
            [-2, -4, -8, -10, 1, 3, 7, 9],
            [-2, -5, -7, -10, 1, 4, 6, 9],
            [-3, -4, -7, -10, 2, 3, 6, 9],
            [-1, -2, -3, -10, 0, 1, 2, 9],
            [-4, -6, -8, -9, 3, 5, 7, 8],
            [-3, -5, -7, -9, 2, 4, 6, 8]
        ];

        // Bit of the colour block that selects the differential mode, or that flags a punchthrough block as opaque.
        private const uint DifferentialOrOpaqueBit = 1u << 25;

        // Index that decodes as a transparent texel on non-opaque punchthrough blocks.
        private const byte PunchthroughTransparentIndex = 2;

        // Table index and modifier index that encode a value exactly (modifier 0), used for constant alpha.
        private const int AlphaConstantTable = 13;
        private const byte AlphaConstantIndex = 4;

        // Pixels belonging to each sub-block, in raster order, for both flip values.
        // Index is (flip << 1) | subBlock.
        private static readonly byte[][] _subBlockPixels =
        [
            [0, 1, 4, 5, 8, 9, 12, 13],
            [2, 3, 6, 7, 10, 11, 14, 15],
            [0, 1, 2, 3, 4, 5, 6, 7],
            [8, 9, 10, 11, 12, 13, 14, 15]
        ];

        public static void Encode(Memory<byte> outputStorage, ReadOnlyMemory<byte> data, int width, int height, bool withAlpha, bool multithreaded)
        {
            int widthInBlocks = (width + BlockWidth - 1) / BlockWidth;
            int heightInBlocks = (height + BlockHeight - 1) / BlockHeight;

            if (multithreaded)
            {
                Parallel.For(0, heightInBlocks, (yInBlocks) =>
                {
                    EncodeRow(
                        MemoryMarshal.Cast<byte, ulong>(outputStorage.Span),
                        data.Span,
                        yInBlocks,
                        widthInBlocks,
                        width,
                        height,
                        withAlpha);
                });
            }
            else
            {
                Span<ulong> output = MemoryMarshal.Cast<byte, ulong>(outputStorage.Span);

                for (int yInBlocks = 0; yInBlocks < heightInBlocks; yInBlocks++)
                {
                    EncodeRow(output, data.Span, yInBlocks, widthInBlocks, width, height, withAlpha);
                }
            }
        }

        private static void EncodeRow(
            Span<ulong> output,
            ReadOnlySpan<byte> data,
            int yInBlocks,
            int widthInBlocks,
            int width,
            int height,
            bool withAlpha)
        {
            ReadOnlySpan<uint> dataUint = MemoryMarshal.Cast<byte, uint>(data);

            Span<int> pr = stackalloc int[BlockWidth * BlockHeight];
            Span<int> pg = stackalloc int[BlockWidth * BlockHeight];
            Span<int> pb = stackalloc int[BlockWidth * BlockHeight];
            Span<int> pa = stackalloc int[BlockWidth * BlockHeight];

            int ulongsPerBlock = withAlpha ? 2 : 1;
            int y = yInBlocks * BlockHeight;

            for (int xInBlocks = 0; xInBlocks < widthInBlocks; xInBlocks++)
            {
                int x = xInBlocks * BlockWidth;

                GatherBlock(dataUint, pr, pg, pb, pa, x, y, width, height);

                int offset = (yInBlocks * widthInBlocks + xInBlocks) * ulongsPerBlock;

                if (withAlpha)
                {
                    output[offset++] = EncodeAlphaBlock(pa);
                }

                output[offset] = EncodeRgbBlock(pr, pg, pb, true);
            }
        }

        private static void GatherBlock(
            ReadOnlySpan<uint> data,
            Span<int> pr,
            Span<int> pg,
            Span<int> pb,
            Span<int> pa,
            int x,
            int y,
            int width,
            int height)
        {
            // Blocks that are partially outside of the image have their last valid row/column
            // replicated, so that the out of bounds texels never pull the endpoints away.
            for (int py = 0; py < BlockHeight; py++)
            {
                int sy = Math.Min(y + py, height - 1);

                for (int px = 0; px < BlockWidth; px++)
                {
                    int sx = Math.Min(x + px, width - 1);

                    uint color = data[sy * width + sx];
                    int i = py * BlockWidth + px;

                    pr[i] = (int)(color & 0xff);
                    pg[i] = (int)((color >> 8) & 0xff);
                    pb[i] = (int)((color >> 16) & 0xff);
                    pa[i] = (int)(color >> 24);
                }
            }
        }

        #region Colour

        /// <summary>
        /// Encodes a fully opaque block.
        /// </summary>
        /// <param name="allowIndividual">
        /// False for ETC2 punchthrough blocks, where the bit that selects the individual mode is
        /// instead the "opaque" flag, and must be set
        /// </param>
        public static ulong EncodeRgbBlock(ReadOnlySpan<int> pr, ReadOnlySpan<int> pg, ReadOnlySpan<int> pb, bool allowIndividual)
        {
            Span<byte> indices = stackalloc byte[BlockWidth * BlockHeight];
            Span<byte> bestIndices = stackalloc byte[BlockWidth * BlockHeight];

            int bestError = int.MaxValue;
            uint bestLow = 0;

            // ETC1 "individual" and "differential" modes, for both sub-block orientations.
            for (int flip = 0; flip < 2; flip++)
            {
                ReadOnlySpan<byte> sub0 = _subBlockPixels[(flip << 1) | 0];
                ReadOnlySpan<byte> sub1 = _subBlockPixels[(flip << 1) | 1];

                (int ar0, int ag0, int ab0) = Average(pr, pg, pb, sub0);
                (int ar1, int ag1, int ab1) = Average(pr, pg, pb, sub1);

                int error;
                int table0;
                int table1;

                if (allowIndividual)
                {
                    // Individual mode, two independent RGB444 base colors.
                    int ir0 = Quantize4(ar0), ig0 = Quantize4(ag0), ib0 = Quantize4(ab0);
                    int ir1 = Quantize4(ar1), ig1 = Quantize4(ag1), ib1 = Quantize4(ab1);

                    error =
                        FindBestTable(pr, pg, pb, sub0, Expand4(ir0), Expand4(ig0), Expand4(ib0), indices, out table0) +
                        FindBestTable(pr, pg, pb, sub1, Expand4(ir1), Expand4(ig1), Expand4(ib1), indices, out table1);

                    if (error < bestError)
                    {
                        bestError = error;
                        bestLow =
                            (uint)((ir0 << 4) | ir1) |
                            ((uint)((ig0 << 4) | ig1) << 8) |
                            ((uint)((ib0 << 4) | ib1) << 16) |
                            ((uint)table0 << 29) |
                            ((uint)table1 << 26) |
                            (uint)flip << 24;

                        indices.CopyTo(bestIndices);
                    }
                }

                // Differential mode, a RGB555 base color plus a 3 bits signed delta per component.
                int dr0 = Quantize5(ar0), dg0 = Quantize5(ag0), db0 = Quantize5(ab0);
                int dr1 = ClampDelta(dr0, Quantize5(ar1));
                int dg1 = ClampDelta(dg0, Quantize5(ag1));
                int db1 = ClampDelta(db0, Quantize5(ab1));

                error =
                    FindBestTable(pr, pg, pb, sub0, Expand5(dr0), Expand5(dg0), Expand5(db0), indices, out table0) +
                    FindBestTable(pr, pg, pb, sub1, Expand5(dr1), Expand5(dg1), Expand5(db1), indices, out table1);

                if (error < bestError)
                {
                    bestError = error;
                    bestLow =
                        (uint)((dr0 << 3) | ((dr1 - dr0) & 7)) |
                        ((uint)((dg0 << 3) | ((dg1 - dg0) & 7)) << 8) |
                        ((uint)((db0 << 3) | ((db1 - db0) & 7)) << 16) |
                        ((uint)table0 << 29) |
                        ((uint)table1 << 26) |
                        (1u << 25) |
                        (uint)flip << 24;

                    indices.CopyTo(bestIndices);
                }

                if (bestError == 0)
                {
                    return bestLow | ((ulong)PackIndices(bestIndices) << 32);
                }
            }

            // ETC2 T and H modes, which can represent two clusters of colors with a sharp transition
            // between them. Those are a much better fit than ETC1 for the kind of content that BCn
            // textures usually hold, since a BCn block is itself built from two endpoint colors.
            if (Cluster(pr, pg, pb, default, out int cr0, out int cg0, out int cb0, out int cr1, out int cg1, out int cb1))
            {
                EncodeModeT(pr, pg, pb, default, cr0, cg0, cb0, cr1, cg1, cb1, indices, ref bestError, ref bestLow, bestIndices);
                EncodeModeT(pr, pg, pb, default, cr1, cg1, cb1, cr0, cg0, cb0, indices, ref bestError, ref bestLow, bestIndices);
                EncodeModeH(pr, pg, pb, default, cr0, cg0, cb0, cr1, cg1, cb1, indices, ref bestError, ref bestLow, bestIndices);
            }
            else
            {
                // The block is a single flat color. The T mode can hold it without any modifier applied,
                // which the ETC1 modes can't do, as their smallest modifier is not zero.
                EncodeModeT(pr, pg, pb, default, pr[0], pg[0], pb[0], pr[0], pg[0], pb[0], indices, ref bestError, ref bestLow, bestIndices);
            }

            if (bestError == 0)
            {
                return bestLow | ((ulong)PackIndices(bestIndices) << 32);
            }

            ulong planarBlock = EncodeModePlanar(pr, pg, pb, out int planarError);

            if (planarError < bestError)
            {
                return planarBlock;
            }

            return bestLow | ((ulong)PackIndices(bestIndices) << 32);
        }

        /// <summary>
        /// Finds the modifier table that minimizes the error for a sub-block with a fixed base color.
        /// </summary>
        /// <returns>Sum of squared differences for the best table</returns>
        private static int FindBestTable(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<byte> pixels,
            int br,
            int bg,
            int bb,
            Span<byte> indices,
            out int bestTable)
        {
            int bestError = int.MaxValue;

            bestTable = 0;

            Span<byte> current = stackalloc byte[8];
            Span<int> modifiedR = stackalloc int[4];
            Span<int> modifiedG = stackalloc int[4];
            Span<int> modifiedB = stackalloc int[4];

            for (int t = 0; t < 8; t++)
            {
                int[] lut = _etc1Lut[t];

                for (int k = 0; k < 4; k++)
                {
                    modifiedR[k] = Saturate(br + lut[k]);
                    modifiedG[k] = Saturate(bg + lut[k]);
                    modifiedB[k] = Saturate(bb + lut[k]);
                }

                int error = 0;

                for (int p = 0; p < pixels.Length; p++)
                {
                    int i = pixels[p];
                    int pixelError = int.MaxValue;
                    int pixelIndex = 0;

                    for (int k = 0; k < 4; k++)
                    {
                        int d = Distance(modifiedR[k], modifiedG[k], modifiedB[k], pr[i], pg[i], pb[i]);

                        if (d < pixelError)
                        {
                            pixelError = d;
                            pixelIndex = k;
                        }
                    }

                    current[p] = (byte)pixelIndex;
                    error += pixelError;

                    if (error >= bestError)
                    {
                        break;
                    }
                }

                if (error < bestError)
                {
                    bestError = error;
                    bestTable = t;

                    for (int p = 0; p < pixels.Length; p++)
                    {
                        indices[pixels[p]] = current[p];
                    }
                }
            }

            return bestError;
        }

        private static void EncodeModeT(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> transparent,
            int r0,
            int g0,
            int b0,
            int r1,
            int g1,
            int b1,
            Span<byte> indices,
            ref int bestError,
            ref uint bestLow,
            Span<byte> bestIndices)
        {
            int q0R = Quantize4(r0), q0G = Quantize4(g0), q0B = Quantize4(b0);
            int q1R = Quantize4(r1), q1G = Quantize4(g1), q1B = Quantize4(b1);

            int e0R = Expand4(q0R), e0G = Expand4(q0G), e0B = Expand4(q0B);
            int e1R = Expand4(q1R), e1G = Expand4(q1G), e1B = Expand4(q1B);

            Span<int> paletteR = stackalloc int[4];
            Span<int> paletteG = stackalloc int[4];
            Span<int> paletteB = stackalloc int[4];

            for (int di = 0; di < 8; di++)
            {
                int d = _etc2Lut[di];

                paletteR[0] = e0R; paletteG[0] = e0G; paletteB[0] = e0B;
                paletteR[1] = Saturate(e1R + d); paletteG[1] = Saturate(e1G + d); paletteB[1] = Saturate(e1B + d);
                paletteR[2] = e1R; paletteG[2] = e1G; paletteB[2] = e1B;
                paletteR[3] = Saturate(e1R - d); paletteG[3] = Saturate(e1G - d); paletteB[3] = Saturate(e1B - d);

                int error = SelectPaletteIndices(pr, pg, pb, transparent, paletteR, paletteG, paletteB, indices, bestError);

                if (error < bestError)
                {
                    bestError = error;
                    bestLow = PackModeT(q0R, q0G, q0B, q1R, q1G, q1B, di);
                    indices.CopyTo(bestIndices);
                }
            }
        }

        private static void EncodeModeH(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> transparent,
            int r0,
            int g0,
            int b0,
            int r1,
            int g1,
            int b1,
            Span<byte> indices,
            ref int bestError,
            ref uint bestLow,
            Span<byte> bestIndices)
        {
            int q0R = Quantize4(r0), q0G = Quantize4(g0), q0B = Quantize4(b0);
            int q1R = Quantize4(r1), q1G = Quantize4(g1), q1B = Quantize4(b1);

            int packed0 = (q0R << 8) | (q0G << 4) | q0B;
            int packed1 = (q1R << 8) | (q1G << 4) | q1B;

            // The low bit of the distance index is not stored, it is recovered by the decoder from the
            // ordering of the two base colors. Equal colors can only ever produce a set bit, and the
            // mode is degenerate in that case anyway.
            if (packed0 == packed1)
            {
                return;
            }

            Span<int> paletteR = stackalloc int[4];
            Span<int> paletteG = stackalloc int[4];
            Span<int> paletteB = stackalloc int[4];

            for (int di = 0; di < 8; di++)
            {
                // Pick the color ordering that makes the decoder recover the wanted low bit.
                bool swap = (packed0 > packed1) != ((di & 1) != 0);

                int aR = swap ? q1R : q0R, aG = swap ? q1G : q0G, aB = swap ? q1B : q0B;
                int bR = swap ? q0R : q1R, bG = swap ? q0G : q1G, bB = swap ? q0B : q1B;

                int eaR = Expand4(aR), eaG = Expand4(aG), eaB = Expand4(aB);
                int ebR = Expand4(bR), ebG = Expand4(bG), ebB = Expand4(bB);

                int d = _etc2Lut[di];

                paletteR[0] = Saturate(eaR + d); paletteG[0] = Saturate(eaG + d); paletteB[0] = Saturate(eaB + d);
                paletteR[1] = Saturate(eaR - d); paletteG[1] = Saturate(eaG - d); paletteB[1] = Saturate(eaB - d);
                paletteR[2] = Saturate(ebR + d); paletteG[2] = Saturate(ebG + d); paletteB[2] = Saturate(ebB + d);
                paletteR[3] = Saturate(ebR - d); paletteG[3] = Saturate(ebG - d); paletteB[3] = Saturate(ebB - d);

                int error = SelectPaletteIndices(pr, pg, pb, transparent, paletteR, paletteG, paletteB, indices, bestError);

                if (error < bestError)
                {
                    bestError = error;
                    bestLow = PackModeH(aR, aG, aB, bR, bG, bB, di);
                    indices.CopyTo(bestIndices);
                }
            }
        }

        private static ulong EncodeModePlanar(ReadOnlySpan<int> pr, ReadOnlySpan<int> pg, ReadOnlySpan<int> pb, out int error)
        {
            FitPlane(pr, out int or, out int hr, out int vr);
            FitPlane(pg, out int og, out int hg, out int vg);
            FitPlane(pb, out int ob, out int hb, out int vb);

            int q0R = Quantize6(or), q0G = Quantize7(og), q0B = Quantize6(ob);
            int qhR = Quantize6(hr), qhG = Quantize7(hg), qhB = Quantize6(hb);
            int qvR = Quantize6(vr), qvG = Quantize7(vg), qvB = Quantize6(vb);

            int e0R = Expand6(q0R), e0G = Expand7(q0G), e0B = Expand6(q0B);
            int ehR = Expand6(qhR), ehG = Expand7(qhG), ehB = Expand6(qhB);
            int evR = Expand6(qvR), evG = Expand7(qvG), evB = Expand6(qvB);

            error = 0;

            for (int y = 0; y < BlockHeight; y++)
            {
                for (int x = 0; x < BlockWidth; x++)
                {
                    int i = y * BlockWidth + x;

                    int r = Saturate(((x * (ehR - e0R)) + (y * (evR - e0R)) + (e0R * 4) + 2) >> 2);
                    int g = Saturate(((x * (ehG - e0G)) + (y * (evG - e0G)) + (e0G * 4) + 2) >> 2);
                    int b = Saturate(((x * (ehB - e0B)) + (y * (evB - e0B)) + (e0B * 4) + 2) >> 2);

                    error += Distance(r, g, b, pr[i], pg[i], pb[i]);
                }
            }

            return PackModePlanar(q0R, q0G, q0B, qhR, qhG, qhB, qvR, qvG, qvB);
        }

        /// <summary>
        /// Assigns each texel of the block to the closest entry of a four colors palette.
        /// </summary>
        /// <returns>Sum of squared differences, which may be truncated if it exceeds <paramref name="errorLimit"/></returns>
        private static int SelectPaletteIndices(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> transparent,
            ReadOnlySpan<int> paletteR,
            ReadOnlySpan<int> paletteG,
            ReadOnlySpan<int> paletteB,
            Span<byte> indices,
            int errorLimit)
        {
            int error = 0;
            bool punchthrough = !transparent.IsEmpty;

            for (int i = 0; i < BlockWidth * BlockHeight; i++)
            {
                if (punchthrough && transparent[i])
                {
                    indices[i] = PunchthroughTransparentIndex;
                    continue;
                }

                int pixelError = int.MaxValue;
                int pixelIndex = 0;

                for (int k = 0; k < 4; k++)
                {
                    if (punchthrough && k == PunchthroughTransparentIndex)
                    {
                        continue;
                    }

                    int d = Distance(paletteR[k], paletteG[k], paletteB[k], pr[i], pg[i], pb[i]);

                    if (d < pixelError)
                    {
                        pixelError = d;
                        pixelIndex = k;
                    }
                }

                indices[i] = (byte)pixelIndex;
                error += pixelError;

                if (error >= errorLimit)
                {
                    return int.MaxValue;
                }
            }

            return error;
        }

        /// <summary>
        /// Splits the block texels in two groups, along the component with the widest range,
        /// and returns the average color of each group.
        /// </summary>
        /// <remarks>Texels flagged on <paramref name="skip"/>, if not empty, are ignored.</remarks>
        /// <returns>True if the block could be split in two non-empty groups, false otherwise</returns>
        private static bool Cluster(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> skip,
            out int r0,
            out int g0,
            out int b0,
            out int r1,
            out int g1,
            out int b1)
        {
            r0 = g0 = b0 = r1 = g1 = b1 = 0;

            Span<int> min = [255, 255, 255];
            Span<int> max = [0, 0, 0];

            for (int i = 0; i < BlockWidth * BlockHeight; i++)
            {
                if (!skip.IsEmpty && skip[i])
                {
                    continue;
                }

                min[0] = Math.Min(min[0], pr[i]); max[0] = Math.Max(max[0], pr[i]);
                min[1] = Math.Min(min[1], pg[i]); max[1] = Math.Max(max[1], pg[i]);
                min[2] = Math.Min(min[2], pb[i]); max[2] = Math.Max(max[2], pb[i]);
            }

            int component = 0;

            for (int c = 1; c < 3; c++)
            {
                if (max[c] - min[c] > max[component] - min[component])
                {
                    component = c;
                }
            }

            if (max[component] - min[component] <= 0)
            {
                return false;
            }

            int threshold = (min[component] + max[component] + 1) >> 1;

            int sr0 = 0, sg0 = 0, sb0 = 0, count0 = 0;
            int sr1 = 0, sg1 = 0, sb1 = 0, count1 = 0;

            for (int i = 0; i < BlockWidth * BlockHeight; i++)
            {
                if (!skip.IsEmpty && skip[i])
                {
                    continue;
                }

                int value = component == 0 ? pr[i] : component == 1 ? pg[i] : pb[i];

                if (value < threshold)
                {
                    sr0 += pr[i]; sg0 += pg[i]; sb0 += pb[i]; count0++;
                }
                else
                {
                    sr1 += pr[i]; sg1 += pg[i]; sb1 += pb[i]; count1++;
                }
            }

            if (count0 == 0 || count1 == 0)
            {
                return false;
            }

            r0 = sr0 / count0; g0 = sg0 / count0; b0 = sb0 / count0;
            r1 = sr1 / count1; g1 = sg1 / count1; b1 = sb1 / count1;

            return true;
        }

        /// <summary>
        /// Least squares fit of the plane that the planar mode interpolates, for a single component.
        /// </summary>
        private static void FitPlane(ReadOnlySpan<int> p, out int origin, out int horizontal, out int vertical)
        {
            int sum = 0, sumX = 0, sumY = 0;

            for (int y = 0; y < BlockHeight; y++)
            {
                for (int x = 0; x < BlockWidth; x++)
                {
                    int value = p[y * BlockWidth + x];

                    sum += value;
                    sumX += x * value;
                    sumY += y * value;
                }
            }

            // Solution of the normal equations for p(x, y) = o + x * dh + y * dv over the 4x4 grid.
            float slopeSum = (sumX + sumY - 3 * sum) / 20f;
            float slopeDiff = (sumX - sumY) / 20f;

            float dh = (slopeSum + slopeDiff) * 0.5f;
            float dv = (slopeSum - slopeDiff) * 0.5f;
            float o = (sum - 24f * slopeSum) / 16f;

            origin = Saturate((int)MathF.Round(o));
            horizontal = Saturate((int)MathF.Round(o + dh * 4f));
            vertical = Saturate((int)MathF.Round(o + dv * 4f));
        }

        private static uint PackModeT(int r0, int g0, int b0, int r1, int g1, int b1, int distanceIndex)
        {
            // The two low bits of the first red component land on the differential delta, and the two
            // high bits on the low bits of the differential base. The remaining base and delta bits are
            // free, and are picked so that the sum overflows the 5 bits range, which is what selects
            // the T mode on the decoder.
            int low = r0 & 3;
            int high = (r0 >> 2) & 3;
            int deltaHigh = low + high >= 4 ? 0 : 1;
            int baseHigh = low + high >= 4 ? 7 : 0;

            return (uint)low |
                ((uint)deltaHigh << 2) |
                ((uint)high << 3) |
                ((uint)baseHigh << 5) |
                ((uint)b0 << 8) |
                ((uint)g0 << 12) |
                ((uint)g1 << 16) |
                ((uint)r1 << 20) |
                ((uint)(distanceIndex & 1) << 24) |
                (1u << 25) |
                ((uint)((distanceIndex >> 1) & 3) << 26) |
                ((uint)b1 << 28);
        }

        private static uint PackModeH(int r0, int g0, int b0, int r1, int g1, int b1, int distanceIndex)
        {
            // Red must not overflow the 5 bits range (that would select the T mode), while green must
            // overflow it, as that is what selects the H mode.
            int redBaseHigh = r0 < 4 ? 1 : 0;

            int greenBaseLow = ((g0 & 1) << 1) | ((b0 >> 3) & 1);
            int greenDeltaLow = (b0 >> 1) & 3;
            int greenDeltaHigh = greenBaseLow + greenDeltaLow >= 4 ? 0 : 1;
            int greenBaseHigh = greenBaseLow + greenDeltaLow >= 4 ? 7 : 0;

            return (uint)((g0 >> 1) & 7) |
                ((uint)r0 << 3) |
                ((uint)redBaseHigh << 7) |
                ((uint)((b0 >> 1) & 3) << 8) |
                ((uint)greenDeltaHigh << 10) |
                ((uint)((b0 >> 3) & 1) << 11) |
                ((uint)(g0 & 1) << 12) |
                ((uint)greenBaseHigh << 13) |
                ((uint)((g1 >> 1) & 7) << 16) |
                ((uint)r1 << 19) |
                ((uint)(b0 & 1) << 23) |
                ((uint)((distanceIndex >> 1) & 1) << 24) |
                (1u << 25) |
                ((uint)((distanceIndex >> 2) & 1) << 26) |
                ((uint)b1 << 27) |
                ((uint)(g1 & 1) << 31);
        }

        private static ulong PackModePlanar(int r0, int g0, int b0, int rh, int gh, int bh, int rv, int gv, int bv)
        {
            // Red and green must not overflow the 5 bits range, while blue must, as that is what
            // selects the planar mode on the decoder.
            int redBaseHigh = (r0 >> 2) < 4 ? 1 : 0;
            int greenBaseHigh = ((g0 >> 2) & 0xf) < 4 ? 1 : 0;

            int blueBaseLow = (b0 >> 3) & 3;
            int blueDeltaLow = (b0 >> 1) & 3;
            int blueDeltaHigh = blueBaseLow + blueDeltaLow >= 4 ? 0 : 1;
            int blueBaseHigh = blueBaseLow + blueDeltaLow >= 4 ? 7 : 0;

            return ((ulong)(uint)((g0 >> 6) & 1)) |
                ((ulong)(uint)(r0 & 0x3f) << 1) |
                ((ulong)(uint)redBaseHigh << 7) |
                ((ulong)(uint)((b0 >> 5) & 1) << 8) |
                ((ulong)(uint)(g0 & 0x3f) << 9) |
                ((ulong)(uint)greenBaseHigh << 15) |
                ((ulong)(uint)((b0 >> 1) & 3) << 16) |
                ((ulong)(uint)blueDeltaHigh << 18) |
                ((ulong)(uint)((b0 >> 3) & 3) << 19) |
                ((ulong)(uint)blueBaseHigh << 21) |
                ((ulong)(uint)(rh & 1) << 24) |
                (1UL << 25) |
                ((ulong)(uint)((rh >> 1) & 0x1f) << 26) |
                ((ulong)(uint)(b0 & 1) << 31) |
                ((ulong)(uint)((bh >> 5) & 1) << 32) |
                ((ulong)(uint)(gh & 0x7f) << 33) |
                ((ulong)(uint)((rv >> 3) & 7) << 40) |
                ((ulong)(uint)(bh & 0x1f) << 43) |
                ((ulong)(uint)((gv >> 2) & 0x1f) << 48) |
                ((ulong)(uint)(rv & 7) << 53) |
                ((ulong)(uint)(bv & 0x3f) << 56) |
                ((ulong)(uint)(gv & 3) << 62);
        }

        /// <summary>
        /// Packs the per-texel 2 bits indices into the upper half of a colour block.
        /// </summary>
        private static uint PackIndices(ReadOnlySpan<byte> indices)
        {
            uint lsb = 0;
            uint msb = 0;

            for (int y = 0; y < BlockHeight; y++)
            {
                for (int x = 0; x < BlockWidth; x++)
                {
                    int bit = x * BlockHeight + y;
                    uint index = indices[y * BlockWidth + x];

                    lsb |= (index & 1) << bit;
                    msb |= ((index >> 1) & 1) << bit;
                }
            }

            return ((msb >> 8) & 0xff) | ((msb & 0xff) << 8) | (((lsb >> 8) & 0xff) << 16) | ((lsb & 0xff) << 24);
        }

        #endregion

        #region Alpha

        internal static ulong EncodeAlphaBlock(ReadOnlySpan<int> pa)
        {
            int min = 255;
            int max = 0;

            for (int i = 0; i < BlockWidth * BlockHeight; i++)
            {
                min = Math.Min(min, pa[i]);
                max = Math.Max(max, pa[i]);
            }

            if (min == max)
            {
                Span<byte> constantIndices = stackalloc byte[BlockWidth * BlockHeight];
                constantIndices.Fill(AlphaConstantIndex);

                return PackAlphaBlock(min, 1, AlphaConstantTable, constantIndices);
            }

            Span<byte> indices = stackalloc byte[BlockWidth * BlockHeight];
            Span<byte> bestIndices = stackalloc byte[BlockWidth * BlockHeight];
            Span<int> values = stackalloc int[8];

            int bestError = int.MaxValue;
            int bestBase = 0;
            int bestMultiplier = 1;
            int bestTable = 0;

            for (int t = 0; t < 16; t++)
            {
                int[] lut = _etc2AlphaLut[t];

                int lutMin = lut[3];
                int lutMax = lut[7];

                int multiplier = Math.Clamp((max - min + (lutMax - lutMin) / 2) / (lutMax - lutMin), 1, 15);
                int alphaBase = Math.Clamp((min - lutMin * multiplier + max - lutMax * multiplier) / 2, 0, 255);

                for (int k = 0; k < 8; k++)
                {
                    values[k] = Saturate(alphaBase + lut[k] * multiplier);
                }

                int error = 0;

                for (int i = 0; i < BlockWidth * BlockHeight; i++)
                {
                    int pixelError = int.MaxValue;
                    int pixelIndex = 0;

                    for (int k = 0; k < 8; k++)
                    {
                        int d = pa[i] - values[k];
                        d *= d;

                        if (d < pixelError)
                        {
                            pixelError = d;
                            pixelIndex = k;
                        }
                    }

                    indices[i] = (byte)pixelIndex;
                    error += pixelError;

                    if (error >= bestError)
                    {
                        break;
                    }
                }

                if (error < bestError)
                {
                    bestError = error;
                    bestBase = alphaBase;
                    bestMultiplier = multiplier;
                    bestTable = t;

                    indices.CopyTo(bestIndices);

                    if (error == 0)
                    {
                        break;
                    }
                }
            }

            return PackAlphaBlock(bestBase, bestMultiplier, bestTable, bestIndices);
        }

        private static ulong PackAlphaBlock(int alphaBase, int multiplier, int table, ReadOnlySpan<byte> indices)
        {
            ulong block = ((ulong)(byte)alphaBase << 56) | ((ulong)(byte)((multiplier << 4) | table) << 48);

            for (int y = 0; y < BlockHeight; y++)
            {
                for (int x = 0; x < BlockWidth; x++)
                {
                    int i = x * BlockHeight + y;

                    block |= (ulong)indices[y * BlockWidth + x] << ((15 - i) * 3);
                }
            }

            // The block is defined in big endian bit order, but it is stored as a little endian value.
            return BinaryPrimitives.ReverseEndianness(block);
        }

        #endregion

        #region Punchthrough

        /// <summary>
        /// Encodes a non-opaque ETC2 punchthrough block, for a block with at least one transparent texel.
        /// </summary>
        /// <remarks>
        /// Transparent texels decode as (0, 0, 0, 0), which is also what BC1 decodes its transparent
        /// texels to. Opaque blocks must be encoded with <see cref="EncodeRgbBlock"/> instead, with the
        /// individual mode disabled.
        /// </remarks>
        public static ulong EncodePunchthroughBlock(ReadOnlySpan<int> pr, ReadOnlySpan<int> pg, ReadOnlySpan<int> pb, ReadOnlySpan<bool> transparent)
        {
            Span<byte> indices = stackalloc byte[BlockWidth * BlockHeight];
            Span<byte> bestIndices = stackalloc byte[BlockWidth * BlockHeight];

            int firstOpaque = transparent.IndexOf(false);

            if (firstOpaque < 0)
            {
                // Differential mode with zero colors and deltas, every texel transparent.
                bestIndices.Fill(PunchthroughTransparentIndex);

                return (ulong)PackIndices(bestIndices) << 32;
            }

            int bestError = int.MaxValue;
            uint bestLow = 0;

            // Differential mode. The modifier of index 0 becomes zero, and index 2 is transparent.
            for (int flip = 0; flip < 2; flip++)
            {
                ReadOnlySpan<byte> sub0 = _subBlockPixels[(flip << 1) | 0];
                ReadOnlySpan<byte> sub1 = _subBlockPixels[(flip << 1) | 1];

                bool has0 = AverageOpaque(pr, pg, pb, transparent, sub0, out int ar0, out int ag0, out int ab0);
                bool has1 = AverageOpaque(pr, pg, pb, transparent, sub1, out int ar1, out int ag1, out int ab1);

                if (!has0)
                {
                    (ar0, ag0, ab0) = (ar1, ag1, ab1);
                }
                else if (!has1)
                {
                    (ar1, ag1, ab1) = (ar0, ag0, ab0);
                }

                int dr0 = Quantize5(ar0), dg0 = Quantize5(ag0), db0 = Quantize5(ab0);
                int dr1 = ClampDelta(dr0, Quantize5(ar1));
                int dg1 = ClampDelta(dg0, Quantize5(ag1));
                int db1 = ClampDelta(db0, Quantize5(ab1));

                int error =
                    FindBestTablePunchthrough(pr, pg, pb, transparent, sub0, Expand5(dr0), Expand5(dg0), Expand5(db0), indices, out int table0) +
                    FindBestTablePunchthrough(pr, pg, pb, transparent, sub1, Expand5(dr1), Expand5(dg1), Expand5(db1), indices, out int table1);

                if (error < bestError)
                {
                    bestError = error;
                    bestLow =
                        (uint)((dr0 << 3) | ((dr1 - dr0) & 7)) |
                        ((uint)((dg0 << 3) | ((dg1 - dg0) & 7)) << 8) |
                        ((uint)((db0 << 3) | ((db1 - db0) & 7)) << 16) |
                        ((uint)table0 << 29) |
                        ((uint)table1 << 26) |
                        (uint)flip << 24;

                    indices.CopyTo(bestIndices);
                }
            }

            if (bestError != 0)
            {
                // T and H modes, with palette entry 2 being transparent. The planar mode is always opaque.
                if (Cluster(pr, pg, pb, transparent, out int cr0, out int cg0, out int cb0, out int cr1, out int cg1, out int cb1))
                {
                    EncodeModeT(pr, pg, pb, transparent, cr0, cg0, cb0, cr1, cg1, cb1, indices, ref bestError, ref bestLow, bestIndices);
                    EncodeModeT(pr, pg, pb, transparent, cr1, cg1, cb1, cr0, cg0, cb0, indices, ref bestError, ref bestLow, bestIndices);
                    EncodeModeH(pr, pg, pb, transparent, cr0, cg0, cb0, cr1, cg1, cb1, indices, ref bestError, ref bestLow, bestIndices);
                }
                else
                {
                    int r = pr[firstOpaque], g = pg[firstOpaque], b = pb[firstOpaque];

                    EncodeModeT(pr, pg, pb, transparent, r, g, b, r, g, b, indices, ref bestError, ref bestLow, bestIndices);
                }
            }

            // Clearing the bit is what marks the block as non-opaque.
            return (bestLow & ~DifferentialOrOpaqueBit) | ((ulong)PackIndices(bestIndices) << 32);
        }

        private static int FindBestTablePunchthrough(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> transparent,
            ReadOnlySpan<byte> pixels,
            int br,
            int bg,
            int bb,
            Span<byte> indices,
            out int bestTable)
        {
            int bestError = int.MaxValue;

            bestTable = 0;

            Span<byte> current = stackalloc byte[8];

            for (int t = 0; t < 8; t++)
            {
                int large = _etc1Lut[t][1];

                int upR = Saturate(br + large), upG = Saturate(bg + large), upB = Saturate(bb + large);
                int downR = Saturate(br - large), downG = Saturate(bg - large), downB = Saturate(bb - large);

                int error = 0;

                for (int p = 0; p < pixels.Length; p++)
                {
                    int i = pixels[p];

                    if (transparent[i])
                    {
                        current[p] = PunchthroughTransparentIndex;
                        continue;
                    }

                    int d0 = Distance(br, bg, bb, pr[i], pg[i], pb[i]);
                    int d1 = Distance(upR, upG, upB, pr[i], pg[i], pb[i]);
                    int d3 = Distance(downR, downG, downB, pr[i], pg[i], pb[i]);

                    int pixelIndex = 0;
                    int pixelError = d0;

                    if (d1 < pixelError)
                    {
                        pixelError = d1;
                        pixelIndex = 1;
                    }

                    if (d3 < pixelError)
                    {
                        pixelError = d3;
                        pixelIndex = 3;
                    }

                    current[p] = (byte)pixelIndex;
                    error += pixelError;

                    if (error >= bestError)
                    {
                        break;
                    }
                }

                if (error < bestError)
                {
                    bestError = error;
                    bestTable = t;

                    for (int p = 0; p < pixels.Length; p++)
                    {
                        indices[pixels[p]] = current[p];
                    }

                    if (error == 0)
                    {
                        break;
                    }
                }
            }

            return bestError;
        }

        private static bool AverageOpaque(
            ReadOnlySpan<int> pr,
            ReadOnlySpan<int> pg,
            ReadOnlySpan<int> pb,
            ReadOnlySpan<bool> transparent,
            ReadOnlySpan<byte> pixels,
            out int r,
            out int g,
            out int b)
        {
            int sr = 0, sg = 0, sb = 0, count = 0;

            for (int p = 0; p < pixels.Length; p++)
            {
                int i = pixels[p];

                if (!transparent[i])
                {
                    sr += pr[i];
                    sg += pg[i];
                    sb += pb[i];
                    count++;
                }
            }

            if (count == 0)
            {
                r = g = b = 0;

                return false;
            }

            r = sr / count;
            g = sg / count;
            b = sb / count;

            return true;
        }

        #endregion

        #region EAC

        // Candidate value range of each EAC variant, in its 11 bits representation.
        private const int EacUnsignedMax = 2047;
        private const int EacSignedMax = 1023;

        /// <summary>
        /// Encodes a single channel of a EAC R11 or RG11 block, from 8 bits normalized values.
        /// </summary>
        /// <param name="values">Texel values, 0 to 255 when unsigned, -128 to 127 when signed</param>
        /// <param name="signed">True to encode a signed normalized block, false for unsigned</param>
        public static ulong EncodeEacBlock(ReadOnlySpan<int> values, bool signed)
        {
            Span<int> targets = stackalloc int[BlockWidth * BlockHeight];

            int min = int.MaxValue;
            int max = int.MinValue;

            // Work on the 11 bits representation the hardware decodes to, so that the endpoints of the
            // normalized range are hit exactly.
            for (int i = 0; i < targets.Length; i++)
            {
                int target = signed
                    ? (Math.Max(values[i], -127) * EacSignedMax + (values[i] < 0 ? -63 : 63)) / 127
                    : (values[i] * EacUnsignedMax + 127) / 255;

                targets[i] = target;
                min = Math.Min(min, target);
                max = Math.Max(max, target);
            }

            int offset = signed ? 0 : 4;
            int lowLimit = signed ? -EacSignedMax : 0;
            int highLimit = signed ? EacSignedMax : EacUnsignedMax;
            int baseMin = signed ? -127 : 0;
            int baseMax = signed ? 127 : 255;

            Span<byte> indices = stackalloc byte[BlockWidth * BlockHeight];
            Span<byte> bestIndices = stackalloc byte[BlockWidth * BlockHeight];
            Span<int> palette = stackalloc int[8];

            int bestError = int.MaxValue;
            int bestBase = 0;
            int bestMultiplier = 1;
            int bestTable = 0;

            for (int t = 0; t < 16; t++)
            {
                int[] lut = _etc2AlphaLut[t];

                int lutMin = lut[3];
                int lutMax = lut[7];
                int lutRange = (lutMax - lutMin) * 8;

                int multiplier = Math.Clamp((max - min + lutRange / 2) / lutRange, 1, 15);
                int center = (min - lutMin * multiplier * 8 + max - lutMax * multiplier * 8) / 2 - offset;
                int eacBase = Math.Clamp((int)MathF.Round(center / 8f), baseMin, baseMax);

                for (int k = 0; k < 8; k++)
                {
                    palette[k] = Math.Clamp(eacBase * 8 + offset + lut[k] * multiplier * 8, lowLimit, highLimit);
                }

                int error = 0;

                for (int i = 0; i < targets.Length; i++)
                {
                    int target = targets[i];
                    int pixelError = int.MaxValue;
                    int pixelIndex = 0;

                    for (int k = 0; k < 8; k++)
                    {
                        int d = target - palette[k];
                        d *= d;

                        if (d < pixelError)
                        {
                            pixelError = d;
                            pixelIndex = k;
                        }
                    }

                    indices[i] = (byte)pixelIndex;
                    error += pixelError;

                    if (error >= bestError)
                    {
                        break;
                    }
                }

                if (error < bestError)
                {
                    bestError = error;
                    bestBase = eacBase;
                    bestMultiplier = multiplier;
                    bestTable = t;

                    indices.CopyTo(bestIndices);

                    if (error == 0)
                    {
                        break;
                    }
                }
            }

            if (bestError != 0)
            {
                // The base and multiplier above are only estimated from the value range. With the texel to
                // modifier assignment known, a least squares fit gives a better pair, which is kept if the
                // re-assigned indices end up with a lower error.
                int[] lut = _etc2AlphaLut[bestTable];

                float sumX = 0, sumY = 0, sumXX = 0, sumXY = 0;

                for (int i = 0; i < targets.Length; i++)
                {
                    float x = lut[bestIndices[i]] * 8;
                    float y = targets[i] - offset;

                    sumX += x;
                    sumY += y;
                    sumXX += x * x;
                    sumXY += x * y;
                }

                float n = targets.Length;
                float variance = n * sumXX - sumX * sumX;

                if (variance > 0)
                {
                    float slope = (n * sumXY - sumX * sumY) / variance;
                    int multiplier = Math.Clamp((int)MathF.Round(slope), 1, 15);
                    int eacBase = Math.Clamp((int)MathF.Round((sumY - multiplier * sumX) / (n * 8)), baseMin, baseMax);

                    if (multiplier != bestMultiplier || eacBase != bestBase)
                    {
                        for (int k = 0; k < 8; k++)
                        {
                            palette[k] = Math.Clamp(eacBase * 8 + offset + lut[k] * multiplier * 8, lowLimit, highLimit);
                        }

                        int error = 0;

                        for (int i = 0; i < targets.Length && error < bestError; i++)
                        {
                            int target = targets[i];
                            int pixelError = int.MaxValue;
                            int pixelIndex = 0;

                            for (int k = 0; k < 8; k++)
                            {
                                int d = target - palette[k];
                                d *= d;

                                if (d < pixelError)
                                {
                                    pixelError = d;
                                    pixelIndex = k;
                                }
                            }

                            indices[i] = (byte)pixelIndex;
                            error += pixelError;
                        }

                        if (error < bestError)
                        {
                            bestBase = eacBase;
                            bestMultiplier = multiplier;

                            indices.CopyTo(bestIndices);
                        }
                    }
                }
            }

            return PackAlphaBlock(bestBase, bestMultiplier, bestTable, bestIndices);
        }

        #endregion

        #region Utilities

        private static (int, int, int) Average(ReadOnlySpan<int> pr, ReadOnlySpan<int> pg, ReadOnlySpan<int> pb, ReadOnlySpan<byte> pixels)
        {
            int r = 0, g = 0, b = 0;

            for (int p = 0; p < pixels.Length; p++)
            {
                int i = pixels[p];

                r += pr[i];
                g += pg[i];
                b += pb[i];
            }

            return (r / pixels.Length, g / pixels.Length, b / pixels.Length);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Distance(int r0, int g0, int b0, int r1, int g1, int b1)
        {
            int dr = r0 - r1;
            int dg = g0 - g1;
            int db = b0 - b1;

            return dr * dr + dg * dg + db * db;
        }

        /// <summary>
        /// Clamps the second endpoint of a differential mode block so that the difference with the
        /// first one fits on the 3 bits signed delta, and stays inside the 5 bits unsigned range.
        /// </summary>
        private static int ClampDelta(int first, int second)
        {
            return Math.Clamp(Math.Clamp(second, first - 4, first + 3), 0, 31);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Quantize4(int value) => (value * 15 + 127) / 255;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Quantize5(int value) => (value * 31 + 127) / 255;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Quantize6(int value) => (value * 63 + 127) / 255;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Quantize7(int value) => (value * 127 + 127) / 255;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Expand4(int value) => (value << 4) | value;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Expand5(int value) => (value << 3) | (value >> 2);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Expand6(int value) => (value << 2) | (value >> 4);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Expand7(int value) => (value << 1) | (value >> 6);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static int Saturate(int value) => value > 255 ? 255 : value < 0 ? 0 : value;

        #endregion
    }
}
