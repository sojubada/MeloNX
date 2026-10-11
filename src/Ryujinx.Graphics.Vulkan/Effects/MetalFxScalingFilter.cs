using Ryujinx.Common.Callbacks;
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan.MoltenVK;
using Silk.NET.Vulkan;
using System;
using System.Runtime.InteropServices;
using Extent2D = Ryujinx.Graphics.GAL.Extents2D;
using Format = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan.Effects
{
    internal sealed class MetalFxScalingFilter : IDisposable
    {
        private const string ProbeCallback = "MetalFxProbe";
        private const string ConfigureCallback = "MetalFxConfigure";
        private const string EncodeCallback = "MetalFxEncode";
        private const string ResetCallback = "MetalFxReset";
        private const int MaxOutputDimension = 8192;
        private const float HostResolutionFactor = 4.0f;

        [StructLayout(LayoutKind.Sequential)]
        private struct MetalFxInteropRequest
        {
            public nint Device;
            public nint CommandQueue;
            public nint InputTexture;
            public nint DestinationTexture;
            public int InputWidth;
            public int InputHeight;
            public int OutputWidth;
            public int OutputHeight;
            public int RenderWidth;
            public int RenderHeight;
            public int DestinationX;
            public int DestinationY;
            public int Result;
        }

        private readonly VulkanRenderer _renderer;
        private readonly nint _metalDevice;
        private readonly nint _metalCommandQueue;

        private TextureView _inputTexture;
        private MetalFxInteropRequest _pendingRequest;
        private bool _hasPendingRequest;
        private bool _available;
        private float _upscaleFactor = 2.0f;

        private bool _hasLoggedConfiguration;
        private int _loggedSourceWidth;
        private int _loggedSourceHeight;
        private int _loggedOutputWidth;
        private int _loggedOutputHeight;
        private int _loggedRenderWidth;
        private int _loggedRenderHeight;
        private GAL.Format _loggedSourceFormat;
        private GAL.Format _loggedInputFormat;
        private Format _loggedOutputFormat;

        private bool _hasRejectedConfiguration;
        private int _rejectedInputWidth;
        private int _rejectedInputHeight;
        private int _rejectedOutputWidth;
        private int _rejectedOutputHeight;
        private int _rejectedRenderWidth;
        private int _rejectedRenderHeight;
        private GAL.Format _rejectedInputFormat;
        private Format _rejectedOutputFormat;

        public float UpscaleFactor
        {
            get => _upscaleFactor;
            set
            {
                float clampedFactor = float.IsFinite(value)
                    ? Math.Clamp(value, 1.0f, HostResolutionFactor)
                    : 2.0f;
                float upscaleFactor = clampedFactor > 3.0f
                    ? HostResolutionFactor
                    : MathF.Round(clampedFactor * 10.0f) / 10.0f;

                if (_upscaleFactor != upscaleFactor)
                {
                    _upscaleFactor = upscaleFactor;
                    _hasLoggedConfiguration = false;
                    _hasRejectedConfiguration = false;
                }
            }
        }

        public MetalFxScalingFilter(VulkanRenderer renderer, PhysicalDevice physicalDevice)
        {
            _renderer = renderer;

            try
            {
                _metalDevice = MoltenVkMetalInterop.GetMetalDevice(physicalDevice);
                _metalCommandQueue = MoltenVkMetalInterop.GetMetalCommandQueue(renderer.Queue);

                MetalFxInteropRequest request = new()
                {
                    Device = _metalDevice,
                };

                _available = _metalDevice != nint.Zero &&
                    _metalCommandQueue != nint.Zero &&
                    Invoke(ProbeCallback, ref request);
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(LogClass.Gpu, $"MetalFX initialization failed: {exception.Message}");
                _available = false;
            }

            if (_available)
            {
                Logger.Info?.Print(LogClass.Gpu, "MetalFX spatial scaler is available.");
            }
            else
            {
                Logger.Warning?.Print(LogClass.Gpu, "MetalFX spatial scaling is unavailable; falling back to bilinear scaling.");
            }
        }

        public bool Prepare(
            TextureView sourceTexture,
            CommandBufferScoped cbs,
            Image destinationImage,
            Format destinationFormat,
            Extent2D source,
            Extent2D destination)
        {
            _hasPendingRequest = false;

            if (!_available)
            {
                return false;
            }

            int sourceWidth = Math.Abs(source.X2 - source.X1);
            int sourceHeight = Math.Abs(source.Y2 - source.Y1);
            int outputWidth = Math.Abs(destination.X2 - destination.X1);
            int outputHeight = Math.Abs(destination.Y2 - destination.Y1);

            if (outputWidth == 0 ||
                outputHeight == 0 ||
                outputWidth > MaxOutputDimension ||
                outputHeight > MaxOutputDimension)
            {
                _hasLoggedConfiguration = false;
                return false;
            }

            if (sourceWidth == 0 ||
                sourceHeight == 0 ||
                sourceWidth > MaxOutputDimension ||
                sourceHeight > MaxOutputDimension ||
                _upscaleFactor <= 1.0f)
            {
                _hasLoggedConfiguration = false;
                return false;
            }

            int renderWidth;
            int renderHeight;

            if (_upscaleFactor >= HostResolutionFactor)
            {
                renderWidth = outputWidth;
                renderHeight = outputHeight;
            }
            else
            {
                float maximumFactor = MathF.Min(
                    (float)MaxOutputDimension / sourceWidth,
                    (float)MaxOutputDimension / sourceHeight);
                float effectiveUpscaleFactor = MathF.Min(_upscaleFactor, maximumFactor);
                renderWidth = Math.Min(
                    MaxOutputDimension,
                    (int)MathF.Ceiling(sourceWidth * effectiveUpscaleFactor));
                renderHeight = Math.Min(
                    MaxOutputDimension,
                    (int)MathF.Ceiling(sourceHeight * effectiveUpscaleFactor));
            }

            if (renderWidth < sourceWidth ||
                renderHeight < sourceHeight ||
                (renderWidth == sourceWidth && renderHeight == sourceHeight))
            {
                _hasLoggedConfiguration = false;
                return false;
            }

            GAL.Format inputFormat = FormatTable.GetFormat(destinationFormat);

            if (IsRejectedConfiguration(
                sourceWidth,
                sourceHeight,
                outputWidth,
                outputHeight,
                renderWidth,
                renderHeight,
                inputFormat,
                destinationFormat))
            {
                return false;
            }

            if (_inputTexture == null ||
                _inputTexture.Width != sourceWidth ||
                _inputTexture.Height != sourceHeight ||
                _inputTexture.Info.Format != inputFormat)
            {
                _inputTexture?.Dispose();

                TextureCreateInfo info = new(
                    sourceWidth,
                    sourceHeight,
                    1,
                    1,
                    1,
                    1,
                    1,
                    4,
                    inputFormat,
                    DepthStencilMode.Depth,
                    Target.Texture2D,
                    SwizzleComponent.Red,
                    SwizzleComponent.Green,
                    SwizzleComponent.Blue,
                    SwizzleComponent.Alpha);

                _inputTexture = _renderer.CreateTexture(info) as TextureView;
            }

            if (_inputTexture == null)
            {
                return false;
            }

            Image inputImage = _inputTexture.GetImage().Get(cbs).Value;
            nint inputMetalTexture = MoltenVkMetalInterop.GetMetalTexture(inputImage);
            nint destinationMetalTexture = MoltenVkMetalInterop.GetMetalTexture(destinationImage);

            if (inputMetalTexture == nint.Zero || destinationMetalTexture == nint.Zero)
            {
                return false;
            }

            MetalFxInteropRequest request = new()
            {
                Device = _metalDevice,
                CommandQueue = _metalCommandQueue,
                InputTexture = inputMetalTexture,
                DestinationTexture = destinationMetalTexture,
                InputWidth = sourceWidth,
                InputHeight = sourceHeight,
                OutputWidth = outputWidth,
                OutputHeight = outputHeight,
                RenderWidth = renderWidth,
                RenderHeight = renderHeight,
                DestinationX = Math.Min(destination.X1, destination.X2),
                DestinationY = Math.Min(destination.Y1, destination.Y2),
            };

            if (!Invoke(ConfigureCallback, ref request))
            {
                RejectConfiguration(
                    sourceWidth,
                    sourceHeight,
                    outputWidth,
                    outputHeight,
                    renderWidth,
                    renderHeight,
                    inputFormat,
                    destinationFormat);

                return false;
            }

            _hasRejectedConfiguration = false;

            Extent2D inputDestination = new(
                destination.X1 <= destination.X2 ? 0 : sourceWidth,
                destination.Y1 <= destination.Y2 ? 0 : sourceHeight,
                destination.X1 <= destination.X2 ? sourceWidth : 0,
                destination.Y1 <= destination.Y2 ? sourceHeight : 0);

            if (sourceTexture.Info.Target.IsMultisample)
            {
                _renderer.HelperShader.BlitColor(
                    _renderer,
                    cbs,
                    sourceTexture,
                    _inputTexture,
                    source,
                    inputDestination,
                    true,
                    true);
            }
            else
            {
                _renderer.HelperShader.PresentCopy(
                    _renderer,
                    cbs,
                    sourceTexture,
                    _inputTexture.GetImageViewForAttachment(),
                    source,
                    inputDestination,
                    true);
            }

            _pendingRequest = request;
            _hasPendingRequest = true;

            LogConfiguration(
                sourceWidth,
                sourceHeight,
                outputWidth,
                outputHeight,
                renderWidth,
                renderHeight,
                sourceTexture.Info.Format,
                inputFormat,
                destinationFormat);

            return true;
        }

        private bool IsRejectedConfiguration(
            int inputWidth,
            int inputHeight,
            int outputWidth,
            int outputHeight,
            int renderWidth,
            int renderHeight,
            GAL.Format inputFormat,
            Format outputFormat)
        {
            return _hasRejectedConfiguration &&
                _rejectedInputWidth == inputWidth &&
                _rejectedInputHeight == inputHeight &&
                _rejectedOutputWidth == outputWidth &&
                _rejectedOutputHeight == outputHeight &&
                _rejectedRenderWidth == renderWidth &&
                _rejectedRenderHeight == renderHeight &&
                _rejectedInputFormat == inputFormat &&
                _rejectedOutputFormat == outputFormat;
        }

        private void RejectConfiguration(
            int inputWidth,
            int inputHeight,
            int outputWidth,
            int outputHeight,
            int renderWidth,
            int renderHeight,
            GAL.Format inputFormat,
            Format outputFormat)
        {
            _hasRejectedConfiguration = true;
            _rejectedInputWidth = inputWidth;
            _rejectedInputHeight = inputHeight;
            _rejectedOutputWidth = outputWidth;
            _rejectedOutputHeight = outputHeight;
            _rejectedRenderWidth = renderWidth;
            _rejectedRenderHeight = renderHeight;
            _rejectedInputFormat = inputFormat;
            _rejectedOutputFormat = outputFormat;
            _hasLoggedConfiguration = false;

            Logger.Warning?.Print(
                LogClass.Gpu,
                $"MetalFX rejected input {inputWidth}x{inputHeight} ({inputFormat}) and " +
                $"output {renderWidth}x{renderHeight} for presentation " +
                $"{outputWidth}x{outputHeight} ({outputFormat}); using bilinear scaling.");
        }

        private void LogConfiguration(
            int sourceWidth,
            int sourceHeight,
            int outputWidth,
            int outputHeight,
            int renderWidth,
            int renderHeight,
            GAL.Format sourceFormat,
            GAL.Format inputFormat,
            Format outputFormat)
        {
            if (_hasLoggedConfiguration &&
                _loggedSourceWidth == sourceWidth &&
                _loggedSourceHeight == sourceHeight &&
                _loggedOutputWidth == outputWidth &&
                _loggedOutputHeight == outputHeight &&
                _loggedRenderWidth == renderWidth &&
                _loggedRenderHeight == renderHeight &&
                _loggedSourceFormat == sourceFormat &&
                _loggedInputFormat == inputFormat &&
                _loggedOutputFormat == outputFormat)
            {
                return;
            }

            _hasLoggedConfiguration = true;
            _loggedSourceWidth = sourceWidth;
            _loggedSourceHeight = sourceHeight;
            _loggedOutputWidth = outputWidth;
            _loggedOutputHeight = outputHeight;
            _loggedRenderWidth = renderWidth;
            _loggedRenderHeight = renderHeight;
            _loggedSourceFormat = sourceFormat;
            _loggedInputFormat = inputFormat;
            _loggedOutputFormat = outputFormat;

            float scaleX = (float)renderWidth / sourceWidth;
            float scaleY = (float)renderHeight / sourceHeight;

            Logger.Info?.Print(
                LogClass.Gpu,
                $"MetalFX active: source {sourceWidth}x{sourceHeight}, output {renderWidth}x{renderHeight}, " +
                $"presentation {outputWidth}x{outputHeight}, upscale {scaleX:0.##}x{scaleY:0.##}.");
        }

        public bool Encode()
        {
            if (!_hasPendingRequest)
            {
                return false;
            }

            _hasPendingRequest = false;

            if (Invoke(EncodeCallback, ref _pendingRequest))
            {
                return true;
            }

            _available = false;
            CallbackRegistry.Invoke(ResetCallback);
            Logger.Error?.Print(LogClass.Gpu, "MetalFX failed to encode a frame; disabling it for the current session.");
            return false;
        }

        private static unsafe bool Invoke(string callbackName, ref MetalFxInteropRequest request)
        {
            request.Result = 0;

            fixed (MetalFxInteropRequest* requestPointer = &request)
            {
                return CallbackRegistry.Invoke(callbackName, (nint)requestPointer, sizeof(MetalFxInteropRequest)) &&
                    request.Result != 0;
            }
        }

        public void Dispose()
        {
            _inputTexture?.Dispose();
            _inputTexture = null;
            _hasPendingRequest = false;

            CallbackRegistry.Invoke(ResetCallback);
        }
    }
}
