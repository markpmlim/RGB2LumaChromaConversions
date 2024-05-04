//
//  MetalRenderer.swift
//  LumaChroma2RGB
//
//  Created by mark lim pak mun on 03/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import AppKit
import MetalKit

class MetalRenderer: NSObject, MTKViewDelegate
{
    var metalView: MTKView!
    var metalDevice: MTLDevice
    var commandQueue: MTLCommandQueue!
    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!

    var lumaTexture: MTLTexture!
    var srcChromaTexture: MTLTexture!
    var destChromaTexture: MTLTexture!
    var rgbTexture: MTLTexture!
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    init?(view: MTKView, device: MTLDevice)
    {
        self.metalView = view
        self.metalDevice = device
        self.commandQueue = metalDevice.makeCommandQueue()
        super.init()
        buildResources()
        buildPipelineState()
    }

    func createMetalTextureFrom(image: NSImage, pixelFormat: MTLPixelFormat) -> MTLTexture?
    {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                    width: width, height: height,
                                                                    mipmapped: false)
        textureDescr.usage = [.shaderRead]
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                          context: nil,
                                          hints: nil)
        else {
            return nil
        }
        let texLoader = MTKTextureLoader(device: self.metalDevice)
        // Load as Linear RGB pixel data
        let textureLoaderOptions: [MTKTextureLoader.Option : Any] = [
            .origin : MTKTextureLoader.Origin.topLeft,
            .SRGB : false
        ]
        var texture: MTLTexture?
        do {
            texture = try texLoader.newTexture(cgImage: cgImage,
                                               options: textureLoaderOptions)
        }
        catch let error {
            print("error:", error)
            return nil
        }
        return texture
    }

    // We need to create a chroma texture with the same width and height as the
    // luma texture but only 1 quarter of the area is filled with pixels
    // from the chroma image. The instance method of MTLBitCommandEncoder
    // copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:
    // is called to copy the entire texture data from the source to a part of the destination.
    // Create a region that covers the entire texture of the source
    func buildResources()
    {
        guard let lumaImage = NSImage(named: NSImage.Name(rawValue: "luma.jpg"))
        else {
            return
        }
        guard let chromaImage = NSImage(named: NSImage.Name(rawValue: "chroma.jpg"))
        else {
            return
        }
        lumaTexture = createMetalTextureFrom(image: lumaImage, pixelFormat: .r8Unorm)
        srcChromaTexture = createMetalTextureFrom(image: chromaImage, pixelFormat: .rg8Unorm)
        // We need to blit the entire chroma texture to another texture which has
        // the same size as the luma texture.
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srcChromaTexture.pixelFormat,
                                                                    width: lumaTexture.width, height: lumaTexture.height,
                                                                    mipmapped: false)
        destChromaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        guard let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: srcChromaTexture.width,
                           height: srcChromaTexture.height,
                           depth: 1)
        // All pixels from the source (chrominance) texture are copied to the 
        // destination (chrominance) texture with its first pixel at the top left.
        // This is equivalent to a ChromaSiting of top left.
        blitEncoder.copy(from: srcChromaTexture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: origin,
                         sourceSize: size,
                         to: destChromaTexture,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: origin)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // XCode's Metal Debugger should show the entire source chroma texture has
        // been copied to the destination chroma texture. The first pixel of
        // destination chroma texture is at the top left corner.
        // Its pixels covers 1/4 of the destination texture's area
    }

    func buildPipelineState()
    {
        // Load all the shader files with a metal file extension in the project
        guard let library = metalDevice.makeDefaultLibrary()
        else {
            fatalError("Could not load default library from main bundle")
        }
 
        // Use a compute shader function to convert yuv colours to rgb colours.
        let kernelFunction = library.makeFunction(name: "YCbCrColorConversion")
        do {
            computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            fatalError("Unable to create compute pipeline state")
        }

        // Instantiate a new instance of MTLTexture to capture the output of kernel function.
        let mtlTextureDesc = MTLTextureDescriptor()
        mtlTextureDesc.textureType = .type2D
        // .bgra8Unorm_srgb is non-writable on macOS.
        mtlTextureDesc.pixelFormat = .bgra8Unorm
        mtlTextureDesc.width = Int(lumaTexture.width)
        mtlTextureDesc.height = Int(lumaTexture.height)
        mtlTextureDesc.usage = [.shaderRead, .shaderWrite]
        rgbTexture = metalDevice.makeTexture(descriptor: mtlTextureDesc)
        
        // To speed up the colour conversion of the frame, utilise all available threads
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        threadgroupsPerGrid = MTLSizeMake((mtlTextureDesc.width+threadsPerThreadgroup.width-1) / threadsPerThreadgroup.width,
                                          (mtlTextureDesc.height+threadsPerThreadgroup.height-1) / threadsPerThreadgroup.height,
                                          1)

        ////// Create the render pipeline state for the drawable render pass.
        // Set up a descriptor for creating a pipeline state object
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Quad Pipeline"
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "screen_vert")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "screen_frag")

        pipelineDescriptor.sampleCount = metalView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        // The attributes of the vertices are generated on the fly.
        pipelineDescriptor.vertexDescriptor = nil

        do {
            renderPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }

    func draw(in view: MTKView)
    {
        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer!.label = "Render Drawable"
        if  let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable {
            let computeCommandEncoder = commandBuffer!.makeComputeCommandEncoder()
            computeCommandEncoder!.label = "Compute Encoder"
            
            computeCommandEncoder!.setComputePipelineState(computePipelineState)
            computeCommandEncoder!.setTexture(lumaTexture, index: 0)
            computeCommandEncoder!.setTexture(destChromaTexture, index: 1)
            computeCommandEncoder!.setTexture(rgbTexture, index: 2)
            computeCommandEncoder!.dispatchThreadgroups(threadgroupsPerGrid,
                                                        threadsPerThreadgroup: threadsPerThreadgroup)
            computeCommandEncoder!.endEncoding()
            
            // These 4 statements are not necessary.
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
            
            let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            renderEncoder!.label = "Render Encoder"
            renderEncoder!.setRenderPipelineState(renderPipelineState)

            renderEncoder!.setFragmentTexture(rgbTexture,
                                              index : 0)
            
            // The attributes of the vertices are generated on the fly.
            renderEncoder!.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: 3)
            
            renderEncoder!.endEncoding()
            commandBuffer!.present(drawable)
            commandBuffer!.commit()
            commandBuffer!.waitUntilCompleted()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {
        
    }
}
