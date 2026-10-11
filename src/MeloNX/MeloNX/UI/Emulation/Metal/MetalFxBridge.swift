//
//  MetalFxBridge.swift
//  MeloNX
//

import Foundation
import Metal
import MetalFX
import MetalPerformanceShaders

@available(iOS 16.0, *)
private struct MetalFxInteropRequest {
    var device: UnsafeMutableRawPointer?
    var commandQueue: UnsafeMutableRawPointer?
    var inputTexture: UnsafeMutableRawPointer?
    var destinationTexture: UnsafeMutableRawPointer?
    var inputWidth: Int32
    var inputHeight: Int32
    var outputWidth: Int32
    var outputHeight: Int32
    var renderWidth: Int32
    var renderHeight: Int32
    var destinationX: Int32
    var destinationY: Int32
    var result: Int32
}

@available(iOS 16.0, *)
private final class MetalFxSpatialState {
    private struct Configuration: Equatable {
        let deviceRegistryID: UInt64
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let renderWidth: Int
        let renderHeight: Int
        let inputPixelFormat: UInt
        let outputPixelFormat: UInt
    }
    
    private let configuration: Configuration
    private let scaler: any MTLFXSpatialScaler
    private let outputTexture: any MTLTexture
    private let presentationTexture: (any MTLTexture)?
    private let presentationScaler: MPSImageLanczosScale?
    
    init?(device: any MTLDevice, inputTexture: any MTLTexture, destinationTexture: any MTLTexture, inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int, renderWidth: Int, renderHeight: Int) {
        guard inputWidth > 0,
              inputHeight > 0,
              outputWidth > 0,
              outputHeight > 0,
              renderWidth >= inputWidth,
              renderHeight >= inputHeight,
              renderWidth > inputWidth || renderHeight > inputHeight,
              inputTexture.device.registryID == device.registryID,
              destinationTexture.device.registryID == device.registryID,
              inputTexture.textureType == .type2D,
              inputTexture.sampleCount == 1,
              inputTexture.width == inputWidth,
              inputTexture.height == inputHeight,
              destinationTexture.textureType == .type2D,
              destinationTexture.sampleCount == 1 else {
            return nil
        }
        
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = renderWidth
        descriptor.outputHeight = renderHeight
        descriptor.colorTextureFormat = inputTexture.pixelFormat
        descriptor.outputTextureFormat = destinationTexture.pixelFormat
        descriptor.colorProcessingMode = .perceptual
        
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            return nil
        }
        
        let requiredInputUsage = scaler.colorTextureUsage.rawValue
        guard inputTexture.usage.rawValue & requiredInputUsage == requiredInputUsage else {
            return nil
        }
        
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: destinationTexture.pixelFormat, width: renderWidth, height: renderHeight, mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
        
        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            return nil
        }
        
        outputTexture.label = "MeloNX MetalFX spatial output"
        
        var presentationTexture: (any MTLTexture)?
        var presentationScaler: MPSImageLanczosScale?
        
        if renderWidth != outputWidth || renderHeight != outputHeight {
            let presentationDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: destinationTexture.pixelFormat, width: outputWidth, height: outputHeight, mipmapped: false)
            presentationDescriptor.storageMode = .private
            presentationDescriptor.usage = .shaderWrite
            
            guard let texture = device.makeTexture(descriptor: presentationDescriptor) else {
                return nil
            }
            
            texture.label = "MeloNX MetalFX presentation"
            presentationTexture = texture
            presentationScaler = MPSImageLanczosScale(device: device)
        }
        
        configuration = .init(
            deviceRegistryID: device.registryID,
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            renderWidth: renderWidth,
            renderHeight: renderHeight,
            inputPixelFormat: inputTexture.pixelFormat.rawValue,
            outputPixelFormat: destinationTexture.pixelFormat.rawValue
        )
        
        self.scaler = scaler
        self.outputTexture = outputTexture
        self.presentationTexture = presentationTexture
        self.presentationScaler = presentationScaler
    }
    
    func matches(
        device: any MTLDevice,
        inputTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        renderWidth: Int,
        renderHeight: Int
    ) -> Bool {
        configuration == .init(
            deviceRegistryID: device.registryID,
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            renderWidth: renderWidth,
            renderHeight: renderHeight,
            inputPixelFormat: inputTexture.pixelFormat.rawValue,
            outputPixelFormat: destinationTexture.pixelFormat.rawValue
        )
    }
    
    func encode(
        commandQueue: any MTLCommandQueue,
        inputTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        destinationX: Int,
        destinationY: Int
    ) -> Bool {
        guard commandQueue.device.registryID == configuration.deviceRegistryID,
              inputTexture.device.registryID == configuration.deviceRegistryID,
              destinationTexture.device.registryID == configuration.deviceRegistryID,
              inputTexture.width == configuration.inputWidth,
              inputTexture.height == configuration.inputHeight,
              inputTexture.pixelFormat.rawValue == configuration.inputPixelFormat,
              destinationTexture.pixelFormat.rawValue == configuration.outputPixelFormat,
              destinationX >= 0,
              destinationY >= 0,
              destinationX + configuration.outputWidth <= destinationTexture.width,
              destinationY + configuration.outputHeight <= destinationTexture.height,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        
        commandBuffer.label = "MeloNX MetalFX spatial upscale"
        
        scaler.inputContentWidth = configuration.inputWidth
        scaler.inputContentHeight = configuration.inputHeight
        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)
        
        let copySource: any MTLTexture
        
        if let presentationTexture, let presentationScaler {
            presentationScaler.encode(commandBuffer: commandBuffer, sourceTexture: outputTexture, destinationTexture: presentationTexture)
            
            copySource = presentationTexture
        } else {
            copySource = outputTexture
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            scaler.colorTexture = nil
            scaler.outputTexture = nil
            return false
        }
        
        blitEncoder.label = "MeloNX MetalFX presentation copy"
        blitEncoder.copy(
            from: copySource,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: configuration.outputWidth,
                height: configuration.outputHeight,
                depth: 1
            ),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: destinationX, y: destinationY, z: 0)
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        
        scaler.colorTexture = nil
        scaler.outputTexture = nil
        
        return true
    }
}

@available(iOS 16.0, *)
enum MetalFxBridge {
    private static let probeCallback = "MetalFxProbe"
    private static let configureCallback = "MetalFxConfigure"
    private static let encodeCallback = "MetalFxEncode"
    private static let resetCallback = "MetalFxReset"
    
    private static let lock = NSLock()
    private static var registered = false
    private static var state: MetalFxSpatialState?
    
    static var isSupported: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }
    
    static func registerCallbacks() {
        lock.lock()
        defer { lock.unlock() }
        
        guard !registered else {
            return
        }
        
        registered = true
        
        CallbackManager.register(name: probeCallback) { callbackData in
            autoreleasepool {
                withRequest(callbackData) { request in
                    guard let device = metalDevice(from: request.pointee.device) else {
                        request.pointee.result = 0
                        return
                    }
                    
                    request.pointee.result = MTLFXSpatialScalerDescriptor.supportsDevice(device) ? 1 : 0
                }
            }
        }
        
        CallbackManager.register(name: configureCallback) { callbackData in
            autoreleasepool {
                withRequest(callbackData) { request in
                    configure(request)
                }
            }
        }
        
        CallbackManager.register(name: encodeCallback) { callbackData in
            autoreleasepool {
                withRequest(callbackData) { request in
                    encode(request)
                }
            }
        }
        
        CallbackManager.register(name: resetCallback) { _ in
            autoreleasepool {
                lock.lock()
                state = nil
                lock.unlock()
            }
        }
    }
    
    private static func withRequest(
        _ callbackData: CallbackData,
        _ body: (UnsafeMutablePointer<MetalFxInteropRequest>) -> Void
    ) {
        guard callbackData.len >= MemoryLayout<MetalFxInteropRequest>.size,
              let rawPointer = callbackData.ptr else {
            return
        }
        
        body(rawPointer.assumingMemoryBound(to: MetalFxInteropRequest.self))
    }
    
    private static func metalDevice(from pointer: UnsafeMutableRawPointer?) -> (any MTLDevice)? {
        guard let pointer else {
            return nil
        }
        
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any MTLDevice
    }
    
    private static func metalCommandQueue(from pointer: UnsafeMutableRawPointer?) -> (any MTLCommandQueue)? {
        guard let pointer else {
            return nil
        }
        
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any MTLCommandQueue
    }
    
    private static func metalTexture(from pointer: UnsafeMutableRawPointer?) -> (any MTLTexture)? {
        guard let pointer else {
            return nil
        }
        
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any MTLTexture
    }
    
    private static func configure(_ request: UnsafeMutablePointer<MetalFxInteropRequest>) {
        request.pointee.result = 0
        
        guard let device = metalDevice(from: request.pointee.device),
              let inputTexture = metalTexture(from: request.pointee.inputTexture),
              let destinationTexture = metalTexture(from: request.pointee.destinationTexture),
              MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            return
        }
        
        let inputWidth = Int(request.pointee.inputWidth)
        let inputHeight = Int(request.pointee.inputHeight)
        let outputWidth = Int(request.pointee.outputWidth)
        let outputHeight = Int(request.pointee.outputHeight)
        let renderWidth = Int(request.pointee.renderWidth)
        let renderHeight = Int(request.pointee.renderHeight)
        
        lock.lock()
        defer { lock.unlock() }
        
        if state?.matches(
            device: device,
            inputTexture: inputTexture,
            destinationTexture: destinationTexture,
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            renderWidth: renderWidth,
            renderHeight: renderHeight
        ) != true {
            state = .init(
                device: device,
                inputTexture: inputTexture,
                destinationTexture: destinationTexture,
                inputWidth: inputWidth,
                inputHeight: inputHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                renderWidth: renderWidth,
                renderHeight: renderHeight
            )
        }
        
        request.pointee.result = state == nil ? 0 : 1
    }
    
    private static func encode(_ request: UnsafeMutablePointer<MetalFxInteropRequest>) {
        request.pointee.result = 0
        
        guard let commandQueue = metalCommandQueue(from: request.pointee.commandQueue),
              let inputTexture = metalTexture(from: request.pointee.inputTexture),
              let destinationTexture = metalTexture(from: request.pointee.destinationTexture) else {
            return
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        request.pointee.result = state?.encode(commandQueue: commandQueue, inputTexture: inputTexture, destinationTexture: destinationTexture, destinationX: Int(request.pointee.destinationX), destinationY: Int(request.pointee.destinationY)) == true ? 1 : 0
    }
}
