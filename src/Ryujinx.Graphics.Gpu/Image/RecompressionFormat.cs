namespace Ryujinx.Graphics.Gpu.Image
{
    /// <summary>
    /// Format that a texture decompressed on the CPU can be re-compressed to before being uploaded.
    /// </summary>
    enum RecompressionFormat
    {
        /// <summary>
        /// The decompressed data is uploaded as-is.
        /// </summary>
        None,

        /// <summary>
        /// The decompressed data is re-compressed to BC7.
        /// </summary>
        Bc7,

        /// <summary>
        /// The decompressed data is re-compressed to ETC2 RGBA8.
        /// </summary>
        Etc2Rgba,

        /// <summary>
        /// The decompressed data is re-compressed to ASTC 4x4.
        /// </summary>
        Astc4x4,
    }
}
