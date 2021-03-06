//
//  Renderer.swift
//  RasterizationWithMetal
//
//  Created by Chao Li on 11/30/20.
//

import Foundation
import MetalKit
import simd

enum ShadingType: Int {
    case wireFrame = 0
    case flat
    case pervertex
    case texture
}

class Renderer: NSObject, MTKViewDelegate {
    
    var shadingType: ShadingType
    
    var device: MTLDevice
    var commandQueue: MTLCommandQueue
    var linePipelineState: MTLRenderPipelineState
    var trianglePipelineState: MTLRenderPipelineState
    var texturePipelineState: MTLRenderPipelineState
    
    var viewPortSize: SIMD2<UInt32>
    var texture: MTLTexture?
    
    var lessDepthState: MTLDepthStencilState
    var defaultModelMatrix: matrix_float4x4
    
    // just line, no normal
    var lineBuffer: MTLBuffer
    // normal vector here is the normal of triangle
    var triangleBuffer: MTLBuffer
    var pervertexBuffer: MTLBuffer
    
    // mesh to render
    var mesh: Mesh
    
    // uniform attributes
    var uniform: Uniform
    
    var camera: Camera
    var animationFrame: Int
    
    var animation: Bool
    let animationMatrix: [matrix_float4x4]
    
    init?(with mtkView: MTKView, mesh: Mesh, textureURL: URL?) {
        if let device = mtkView.device {
            self.device = device
            self.mesh = mesh
            
            let loader = MTKTextureLoader.init(device: device)
            if textureURL == nil {
                self.texture = nil
            } else {
                self.texture = try? loader.newTexture(URL: textureURL!, options: nil)
            }
//            do {
//                if textureURL != nil {
//                    let texture = try loader.newTexture(URL: textureURL!, options: nil)
//                    self.texture = texture
//                } else {
//                    self.texture = nil
//                }
//            } catch {
//                return nil
//            }
            
            guard let lineBuffer = device.makeBuffer(length: MemoryLayout<Vertex>.size * mesh.lines.count,
                                                      options: .storageModeShared) else {
                return nil
            }
            self.lineBuffer = lineBuffer
            self.lineBuffer.contents().copyMemory(from: mesh.lines, byteCount: MemoryLayout<Vertex>.size * mesh.lines.count)
            guard let triangleBuffer = device.makeBuffer(length: MemoryLayout<Vertex>.size * mesh.triangles.count,
                                                         options: .storageModeShared) else {
                return nil
            }
            self.triangleBuffer = triangleBuffer
            self.triangleBuffer.contents().copyMemory(from: mesh.triangles, byteCount: MemoryLayout<Vertex>.size * mesh.triangles.count)
            
            guard let pervertexBuffer = device.makeBuffer(length: MemoryLayout<Vertex>.size * mesh.trianglesPerVertex.count,
                                                          options: .storageModeShared) else {
                return nil
            }
            self.pervertexBuffer = pervertexBuffer
            self.pervertexBuffer.contents().copyMemory(from: mesh.trianglesPerVertex, byteCount: MemoryLayout<Vertex>.size * mesh.trianglesPerVertex.count)
                
            mtkView.depthStencilPixelFormat = .depth32Float
            
            let defaultLibrary = device.makeDefaultLibrary()!
            
            let vertexFunction = defaultLibrary.makeFunction(name: "vertexShader")
            let fragmentFunction = defaultLibrary.makeFunction(name: "fragmentShader")
            
            let pipelineStateDescriptor = MTLRenderPipelineDescriptor.init()
            pipelineStateDescriptor.label = "Simple Pipeline"
            pipelineStateDescriptor.vertexFunction = vertexFunction
            pipelineStateDescriptor.fragmentFunction = fragmentFunction
            pipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            pipelineStateDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
            do {
                try self.trianglePipelineState = device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
            } catch {
                return nil
            }
            
            let linePipelineStateDescriptor = MTLRenderPipelineDescriptor.init()
            linePipelineStateDescriptor.label = "line pipeline"
            linePipelineStateDescriptor.vertexFunction = defaultLibrary.makeFunction(name: "wireFrameShaderFrontLine")
            linePipelineStateDescriptor.fragmentFunction = fragmentFunction
            linePipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            linePipelineStateDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
            do {
                try self.linePipelineState = device.makeRenderPipelineState(descriptor: linePipelineStateDescriptor)
            } catch {
                return nil
            }
            
            // texturePipelineState
            let texturePipelineDescriptor = MTLRenderPipelineDescriptor.init()
            texturePipelineDescriptor.label = "texture pipeline"
            texturePipelineDescriptor.vertexFunction = defaultLibrary.makeFunction(name: "textureShaderTriangle")
            texturePipelineDescriptor.fragmentFunction = defaultLibrary.makeFunction(name: "textureFragmentShader")
            texturePipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            texturePipelineDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
            do {
                try self.texturePipelineState = device.makeRenderPipelineState(descriptor: texturePipelineDescriptor)
            } catch {
                return nil
            }
            
            let lessDepthDescriptor = MTLDepthStencilDescriptor.init()
            lessDepthDescriptor.depthCompareFunction = .lessEqual
            lessDepthDescriptor.isDepthWriteEnabled = true
            if let depthState = device.makeDepthStencilState(descriptor: lessDepthDescriptor) {
                self.lessDepthState = depthState
            } else {
                return nil
            }
            
            self.commandQueue = device.makeCommandQueue()!
            self.viewPortSize = SIMD2<UInt32>()
            
            let near: Float = 0.35
            let far: Float = 5
            let position = simd_float3(0, 0, 3)
            let fieldOfView: Float = atan((mesh.max.y - mesh.min.y) / 2 / near) * 2.1
            
            self.camera = Camera.init(position: position,
                                      upDirection: simd_float3(0, 1, 0),
                                      fieldOfView: fieldOfView,
                                      aspectRatio: Float(self.viewPortSize.x) / Float(self.viewPortSize.y),
                                      near: near,
                                      far: far,
                                      perspective: false)
            self.animationFrame = 0
            
            self.defaultModelMatrix = makeRotateAlongYAxisMatrix(alpha: Float.pi * 2 / 3) * makeTranslateMatrix(tx: -mesh.midpoint[0], ty: -mesh.midpoint[1], tz: -mesh.midpoint[2])
            
            self.uniform = Uniform.init()
            self.uniform.cameraMatrix = camera.worldToCanonical
            self.uniform.cameraPosition = camera.position
            self.uniform.modelMatrix = defaultModelMatrix
            self.uniform.modelMatrixInverseTranspose = simd_transpose(self.uniform.modelMatrix.inverse)
            self.uniform.lightPosition = vector_float3(2, 0, 4);
            self.uniform.lightIntensity = 16
            self.uniform.ambient = 0.2
            self.uniform.diffuse = 0.5
            self.uniform.specular = 0.2
            self.uniform.specular_exponent = 256
            
            self.shadingType = .flat
            
            self.animation = false
            let ratio: Float = 0.6
            self.animationMatrix = Array(0..<480).map({ (time:Int) -> matrix_float4x4 in
                if time < 240 {
                    let translation = makeTranslateMatrix(tx: position[0] * ratio * Float(time) / 240, ty: position[1] * ratio * Float(time) / 240, tz: position[2] * ratio * Float(time) / 240)
                    return translation * makeRotateAlongYAxisMatrix(alpha: Float.pi / 120 * Float(time))
                } else {
                    let translation = makeTranslateMatrix(tx: position[0] * ratio * Float(480 - time) / 240, ty: position[1] * ratio * Float(480 - time) / 240, tz: position[2] * ratio * Float(480 - time) / 240)
                    return translation * makeRotateAlongYAxisMatrix(alpha: Float.pi / 120 * Float(time))
                }
            })
            super.init()
            return
        }
        return nil
    }
    
    func setPerspective(perspective: Bool) {
        if perspective {
            self.camera.setPerspective(persepctive: perspective, fov: atan((mesh.max.y - mesh.min.y) / 2 / self.camera.near) * 1)
        } else {
            self.camera.setPerspective(persepctive: perspective, fov: atan((mesh.max.y - mesh.min.y) / 2 / self.camera.near) * 2.1)
        }
        self.camera.perspective = perspective
        self.uniform.cameraMatrix = self.camera.worldToCanonical
    }
    
    func setAnimation(animation: Bool) {
        self.animationFrame = 0
        self.animation = animation
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.viewPortSize.x = UInt32(size.width)
        self.viewPortSize.y = UInt32(size.height)
        self.camera.aspectRatio = Float(self.viewPortSize.x) / Float(self.viewPortSize.y)
        self.uniform.cameraMatrix = camera.worldToCanonical
    }
    
    func parameterChanged() {
        self.uniform.cameraMatrix = camera.worldToCanonical
    }
    
    func wireframe(in view: MTKView) {
        if let renderPassDescriptor = view.currentRenderPassDescriptor {
            let commandBuffer = self.commandQueue.makeCommandBuffer()
            commandBuffer?.label = "Wireframe command"
            
            if let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "Wireframe Render Encoder"
                renderEncoder.setViewport(MTLViewport.init(originX: 0.0,
                                                           originY: 0.0,
                                                           width: Double(self.viewPortSize.x),
                                                           height: Double(self.viewPortSize.y),
                                                           znear: 0.0,
                                                           zfar: 1.0))
                renderEncoder.setRenderPipelineState(self.linePipelineState)
                renderEncoder.setDepthStencilState(self.lessDepthState)
                renderEncoder.setVertexBuffer(self.lineBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniform,
                                             length: MemoryLayout<Uniform>.size,
                                             index: Int(VertexInputIndexUniform.rawValue))
                renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: self.mesh.lines.count)
                renderEncoder.endEncoding()
            }
            
            commandBuffer?.present(view.currentDrawable!)
            commandBuffer?.commit()
        }
    }
    
    func flatshading(in view: MTKView) {
        if let renderPassDescriptor = view.currentRenderPassDescriptor {
            let commandBuffer = self.commandQueue.makeCommandBuffer()
            commandBuffer?.label = "Flatshading command"
            
            if let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "Flat Render Encoder"
                renderEncoder.setViewport(MTLViewport.init(originX: 0.0,
                                                           originY: 0.0,
                                                           width: Double(self.viewPortSize.x),
                                                           height: Double(self.viewPortSize.y),
                                                           znear: 0.0,
                                                           zfar: 1.0))
                renderEncoder.setRenderPipelineState(self.trianglePipelineState)
                renderEncoder.setDepthStencilState(self.lessDepthState)
                renderEncoder.setVertexBuffer(self.triangleBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniform,
                                             length: MemoryLayout<Uniform>.size,
                                             index: Int(VertexInputIndexUniform.rawValue))
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.mesh.triangles.count)
                renderEncoder.setRenderPipelineState(self.linePipelineState)
                renderEncoder.setVertexBuffer(self.lineBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniform,
                                             length: MemoryLayout<Uniform>.size,
                                             index: Int(VertexInputIndexUniform.rawValue))
                renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: self.mesh.lines.count)
                renderEncoder.endEncoding()
            }
            
            commandBuffer?.present(view.currentDrawable!)
            commandBuffer?.commit()
        }
    }
    
    func pervertex(in view: MTKView) {
        if let renderPassDescriptor = view.currentRenderPassDescriptor {
            let commandBuffer = self.commandQueue.makeCommandBuffer()
            commandBuffer?.label = "pervertex command"
            
            if let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "pervertex Render Encoder"
                renderEncoder.setViewport(MTLViewport.init(originX: 0.0,
                                                           originY: 0.0,
                                                           width: Double(self.viewPortSize.x),
                                                           height: Double(self.viewPortSize.y),
                                                           znear: 0.0,
                                                           zfar: 1.0))
                renderEncoder.setRenderPipelineState(self.trianglePipelineState)
                renderEncoder.setDepthStencilState(self.lessDepthState)
                renderEncoder.setVertexBuffer(self.pervertexBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniform,
                                             length: MemoryLayout<Uniform>.size,
                                             index: Int(VertexInputIndexUniform.rawValue))
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.mesh.trianglesPerVertex.count)
                renderEncoder.endEncoding()
            }
            
            commandBuffer?.present(view.currentDrawable!)
            commandBuffer?.commit()
        }
    }
    
    func texture(in view: MTKView) {
        guard let texture = self.texture else {
            return pervertex(in: view)
        }
        if let renderPassDescriptor = view.currentRenderPassDescriptor {
            let commandBuffer = self.commandQueue.makeCommandBuffer()
            commandBuffer?.label = "texture command"
            
            if let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "texture Render Encoder"
                renderEncoder.setViewport(MTLViewport.init(originX: 0.0,
                                                           originY: 0.0,
                                                           width: Double(self.viewPortSize.x),
                                                           height: Double(self.viewPortSize.y),
                                                           znear: 0.0,
                                                           zfar: 1.0))
                renderEncoder.setRenderPipelineState(self.texturePipelineState)
                renderEncoder.setDepthStencilState(self.lessDepthState)
                renderEncoder.setVertexBuffer(self.triangleBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniform,
                                             length: MemoryLayout<Uniform>.size,
                                             index: Int(VertexInputIndexUniform.rawValue))
                renderEncoder.setFragmentTexture(texture,
                                                 index: Int(TextureIndexBaseColor.rawValue))
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.mesh.trianglesPerVertex.count)
                renderEncoder.endEncoding()
            }
            
            commandBuffer?.present(view.currentDrawable!)
            commandBuffer?.commit()
        }
    }
    
    func draw(in view: MTKView) {
        if self.animation {
            self.uniform.modelMatrix = self.animationMatrix[self.animationFrame] * self.defaultModelMatrix
            self.uniform.modelMatrixInverseTranspose = simd_transpose(self.uniform.modelMatrix.inverse)
            self.animationFrame = (self.animationFrame + 1) % self.animationMatrix.count
        } else {
            self.uniform.modelMatrix = self.defaultModelMatrix
            self.uniform.modelMatrixInverseTranspose = simd_transpose(self.uniform.modelMatrix.inverse)
        }
        
        switch self.shadingType {
        case .flat:
            flatshading(in: view)
        case .wireFrame:
            wireframe(in: view)
        case .pervertex:
            pervertex(in: view)
        case .texture:
            texture(in: view)
        }
    }
}
