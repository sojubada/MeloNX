using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec.FFmpeg.Native
{
    static partial class FFmpegApi
    {
        public const string AvCodecLibraryName = "avcodec";
        public const string AvUtilLibraryName = "avutil";

        private static readonly Dictionary<string, (int, int)> _librariesWhitelist = new()
        {
            { AvCodecLibraryName, (59, 60) },
            { AvUtilLibraryName, (57, 58) },
        };

        private static string FormatLibraryNameForCurrentOs(string libraryName, int version)
        {
            if (OperatingSystem.IsWindows())
            {
                return $"{libraryName}-{version}.dll";
            }
            else if (OperatingSystem.IsLinux())
            {
                return $"lib{libraryName}.so.{version}";
            }
            else if (OperatingSystem.IsMacOS() || (OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()))
            {
                return $"lib{libraryName}.{version}.dylib";
            }
            else
            {
                throw new NotImplementedException($"Unsupported OS for FFmpeg: {RuntimeInformation.RuntimeIdentifier}");
            }
        }

        private static bool TryLoadWhitelistedLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath, out nint handle)
        {
            handle = nint.Zero;

            if (_librariesWhitelist.TryGetValue(libraryName, out (int, int) value))
            {
                (int minVersion, int maxVersion) = value;

                for (int version = maxVersion; version >= minVersion; version--)
                {
                    if (NativeLibrary.TryLoad(FormatLibraryNameForCurrentOs(libraryName, version), assembly, searchPath, out handle))
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        /// <summary>
        /// iOS/tvOS apps ship FFmpeg unversioned inside the bundle (Frameworks/libavcodec.dylib,
        /// or libavcodec.framework on iOS), so the versioned names above are never found and the
        /// default probing does not look in the bundle. Without this, the first in-game video
        /// (Nvdec H.264/VP8) fails to load FFmpeg and the decoder throws.
        /// </summary>
        private static bool TryLoadBundledLibrary(string libraryName, out nint handle)
        {
            handle = nint.Zero;

            if (!(OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()))
            {
                return false;
            }

            string exeDir = System.IO.Path.GetDirectoryName(Environment.ProcessPath ?? AppContext.BaseDirectory) ?? AppContext.BaseDirectory;
            string frameworks = System.IO.Path.Combine(exeDir, "Frameworks");

            string[] candidates =
            {
                System.IO.Path.Combine(frameworks, $"lib{libraryName}.dylib"),
                System.IO.Path.Combine(frameworks, $"lib{libraryName}.framework", $"lib{libraryName}"),
                $"@rpath/lib{libraryName}.dylib",
            };

            foreach (string candidate in candidates)
            {
                if (NativeLibrary.TryLoad(candidate, out handle))
                {
                    Console.WriteLine($"FFmpeg: loaded {candidate}");
                    return true;
                }
            }

            Console.WriteLine($"FFmpeg: lib{libraryName} not found in {frameworks}; in-game video will not decode");
            return false;
        }

        static FFmpegApi()
        {
            NativeLibrary.SetDllImportResolver(typeof(FFmpegApi).Assembly, (name, assembly, path) =>
            {

                if (name == AvUtilLibraryName && TryLoadWhitelistedLibrary(AvUtilLibraryName, assembly, path, out nint handle))
                {
                    return handle;
                }
                else if (name == AvCodecLibraryName && TryLoadWhitelistedLibrary(AvCodecLibraryName, assembly, path, out handle))
                {
                    return handle;
                }
                else if ((name == AvUtilLibraryName || name == AvCodecLibraryName) && TryLoadBundledLibrary(name, out handle))
                {
                    return handle;
                }

                return nint.Zero;
            });
        }

        public unsafe delegate void av_log_set_callback_callback(void* a0, AVLog level, [MarshalAs(UnmanagedType.LPUTF8Str)] string a2, byte* a3);

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial AVFrame* av_frame_alloc();

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial void av_frame_unref(AVFrame* frame);

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial void av_free(AVFrame* frame);

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial void av_log_set_level(AVLog level);

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial void av_log_set_callback(av_log_set_callback_callback callback);

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial AVLog av_log_get_level();

        [LibraryImport(AvUtilLibraryName)]
        internal static unsafe partial void av_log_format_line(void* ptr, AVLog level, [MarshalAs(UnmanagedType.LPUTF8Str)] string fmt, byte* vl, byte* line, int lineSize, int* printPrefix);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial AVCodec* avcodec_find_decoder(AVCodecID id);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial AVCodecContext* avcodec_alloc_context3(AVCodec* codec);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial int avcodec_open2(AVCodecContext* avctx, AVCodec* codec, void** options);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial int avcodec_close(AVCodecContext* avctx);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial void avcodec_free_context(AVCodecContext** avctx);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial AVPacket* av_packet_alloc();

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial void av_packet_unref(AVPacket* pkt);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial void av_packet_free(AVPacket** pkt);

        [LibraryImport(AvCodecLibraryName)]
        internal static unsafe partial int avcodec_version();
    }
}
