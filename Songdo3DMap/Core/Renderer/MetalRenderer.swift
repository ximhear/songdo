import MetalKit
import simd

/// Metal4 기반 3D 맵 렌더러
@MainActor
final class MetalRenderer: NSObject {

    // MARK: - Metal Core Objects

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var library: MTLLibrary!

    // MARK: - Render Pipelines

    private var gridPipeline: MTLRenderPipelineState!
    private var buildingPipeline: MTLRenderPipelineState!
    private var roadPipeline: MTLRenderPipelineState!
    private var markerPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    // MARK: - Buffers

    private var uniformBuffer: MTLBuffer!
    private var modelMatrixBuffer: MTLBuffer!
    private var markerModelMatrixBuffer: MTLBuffer!  // 마커 전용 버퍼
    private var uniforms = Uniforms()

    // MARK: - Camera

    var camera: Camera

    // MARK: - Chunk Management

    private var chunkManager: ChunkManager!
    private var isChunkManagerInitialized = false

    // MARK: - Scene State

    private var time: Float = 0
    private var viewportSize: CGSize = .zero
    private var lastCameraPosition: SIMD3<Float> = .zero

    // MARK: - Statistics

    private(set) var buildingCount: Int = 0
    private(set) var roadCount: Int = 0
    private(set) var chunkCount: Int = 0

    // MARK: - Location Marker

    private var locationMarkerMesh: Mesh?
    private var locationMarkerPosition: SIMD3<Float>?
    private let markerColor = SIMD4<Float>(1.0, 0.2, 0.2, 1.0)  // 빨간색
    private let markerRadius: Float = 5.0   // 반지름 5미터
    private let markerHeight: Float = 100.0  // 높이 100미터

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        // Initialize camera at a good viewing position for Songdo
        // Data center is (5000, 4250) based on full Songdo chunk bounds
        self.camera = Camera()
        camera.target = SIMD3<Float>(5000, 0, -4250)  // Center of data (Z 반전)
        camera.distance = 3000  // 더 넓은 영역을 보기 위해 증가
        camera.pitch = -45
        camera.yaw = 0

        super.init()

        setupPipelines()
        setupBuffers()
        setupChunkManager()
        setupLocationMarker()
    }

    // MARK: - Setup

    private func setupPipelines() {
        // Load shader library
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load shader library")
        }
        self.library = library

        // Grid pipeline
        gridPipeline = makeRenderPipeline(
            vertexFunction: "grid_vertex",
            fragmentFunction: "grid_fragment",
            label: "Grid Pipeline"
        )

        // Building pipeline (without texture)
        buildingPipeline = makeRenderPipelineWithVertexDescriptor(
            vertexFunction: "building_vertex",
            fragmentFunction: "building_fragment",
            label: "Building Pipeline"
        )

        // Road pipeline
        roadPipeline = makeRenderPipelineWithVertexDescriptor(
            vertexFunction: "road_vertex",
            fragmentFunction: "road_fragment",
            label: "Road Pipeline"
        )

        // Marker pipeline (reuse building shader)
        markerPipeline = makeRenderPipelineWithVertexDescriptor(
            vertexFunction: "building_vertex",
            fragmentFunction: "building_fragment",
            label: "Marker Pipeline"
        )

        // Depth state (Reversed-Z: greater 비교 사용)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater  // Reversed-Z
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)
    }

    private func setupChunkManager() {
        chunkManager = ChunkManager(device: device)
        chunkManager.delegate = self

        // Load chunk index
        Task {
            do {
                try chunkManager.loadIndex()
                isChunkManagerInitialized = true
                print("ChunkManager initialized successfully")

                // Immediately start loading chunks around the camera
                // ChunkManager는 원본 좌표계 사용, 카메라 타겟은 Z 반전되어 있으므로 다시 반전
                let cameraXZ = SIMD3<Float>(camera.target.x, 0, -camera.target.z)
                chunkManager.update(cameraPosition: cameraXZ)
                print("Initial chunk loading triggered at position: \(cameraXZ)")
            } catch {
                print("Failed to initialize ChunkManager: \(error)")
            }
        }
    }

    private func setupLocationMarker() {
        // 원기둥 마커 생성
        locationMarkerMesh = CylinderGenerator.generate(
            radius: markerRadius,
            height: markerHeight,
            segments: 32,
            device: device
        )

        // 송도현대아울렛 고정 위치 (GPS: 37.381659, 126.657836)
        // flipZ 매트릭스가 렌더링 시 반전 처리하므로 원본 좌표 사용
        locationMarkerPosition = SIMD3<Float>(3778, 0, 2959)
    }

    private func createMarkerBoxMesh() -> Mesh? {
        let hw: Float = markerRadius        // half width = 5m
        let hd: Float = markerRadius        // half depth = 5m
        let h: Float = markerHeight         // height = 100m

        // 24 vertices (4 per face for correct normals) - GPUVertex 사용
        var vertices: [GPUVertex] = []

        // Front face (+Z)
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, 0, hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(-hw, h, hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 1)))

        // Back face (-Z)
        vertices.append(GPUVertex(position: SIMD3(hw, 0, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(-hw, h, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(0, 1)))

        // Right face (+X)
        vertices.append(GPUVertex(position: SIMD3(hw, 0, hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, 0, -hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, -hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(0, 1)))

        // Left face (-X)
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, -hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(-hw, h, hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(-hw, h, -hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(0, 1)))

        // Top face (+Y)
        vertices.append(GPUVertex(position: SIMD3(-hw, h, hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, h, -hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(-hw, h, -hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(0, 1)))

        // Bottom face (-Y)
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, -hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(0, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, 0, -hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(1, 0)))
        vertices.append(GPUVertex(position: SIMD3(hw, 0, hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(1, 1)))
        vertices.append(GPUVertex(position: SIMD3(-hw, 0, hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(0, 1)))

        // Indices (2 triangles per face, CCW winding)
        let indices: [UInt32] = [
            0, 1, 2, 0, 2, 3,       // Front
            4, 5, 6, 4, 6, 7,       // Back
            8, 9, 10, 8, 10, 11,    // Right
            12, 13, 14, 12, 14, 15, // Left
            16, 17, 18, 16, 18, 19, // Top
            20, 21, 22, 20, 22, 23  // Bottom
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<GPUVertex>.stride,
            options: .storageModeShared
        ) else { return nil }

        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { return nil }

        return Mesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            primitiveType: .triangle
        )
    }

    // MARK: - Location Marker Update

    func updateLocationMarker(position: SIMD3<Float>?) {
        // GPS 위치가 있으면 업데이트, 없으면 기존 위치 유지
        if let pos = position {
            locationMarkerPosition = pos
            print("Location marker updated: (\(pos.x), \(pos.z))")
        }
    }

    private func makeRenderPipeline(
        vertexFunction: String,
        fragmentFunction: String,
        label: String
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create \(label): \(error)")
        }
    }

    private func makeRenderPipelineWithVertexDescriptor(
        vertexFunction: String,
        fragmentFunction: String,
        label: String
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float

        // Vertex descriptor for mesh data
        let vertexDescriptor = MTLVertexDescriptor()

        // Position
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        // Normal
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        // TexCoord
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0

        // Layout
        vertexDescriptor.layouts[0].stride = MemoryLayout<GPUVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        descriptor.vertexDescriptor = vertexDescriptor

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create \(label): \(error)")
        }
    }

    private func setupBuffers() {
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )
        uniformBuffer?.label = "Uniform Buffer"

        // Model matrix buffer for per-object transforms
        modelMatrixBuffer = device.makeBuffer(
            length: MemoryLayout<simd_float4x4>.stride,
            options: .storageModeShared
        )
        modelMatrixBuffer?.label = "Model Matrix Buffer"

        // Marker-specific model matrix buffer (avoid sharing with roads)
        markerModelMatrixBuffer = device.makeBuffer(
            length: MemoryLayout<simd_float4x4>.stride,
            options: .storageModeShared
        )
        markerModelMatrixBuffer?.label = "Marker Model Matrix Buffer"
    }

    // MARK: - Update

    func updateViewport(size: CGSize) {
        viewportSize = size
        camera.aspectRatio = Float(size.width / size.height)
    }

    func updateCamera(position: SIMD3<Float>, target: SIMD3<Float>) {
        // orbit 모드에서는 target만 업데이트 (position은 자동 계산됨)
        print("updateCamera called: target = (\(target.x), \(target.z)), current camera.target = (\(camera.target.x), \(camera.target.z))")
        camera.target = target
    }

    func centerOnLocation(_ position: SIMD3<Float>) {
        camera.target = position
        print("Camera centered on: (\(position.x), \(position.z))")
    }

    private func updateUniforms() {
        // Z축 반전 매트릭스 (북쪽이 화면 위쪽으로)
        let flipZ = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, -1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        // view * flip 으로 월드 Z축 반전
        let modifiedView = camera.viewMatrix * flipZ

        uniforms.viewMatrix = modifiedView
        uniforms.projectionMatrix = camera.projectionMatrix
        uniforms.viewProjectionMatrix = camera.projectionMatrix * modifiedView
        uniforms.cameraPosition = camera.position
        uniforms.time = time

        // Sun light (afternoon lighting)
        uniforms.lightDirection = normalize(SIMD3<Float>(0.5, 0.8, 0.3))
        uniforms.lightColor = SIMD3<Float>(1.0, 0.98, 0.95)
        uniforms.ambientColor = SIMD3<Float>(0.4, 0.45, 0.5)

        uniformBuffer?.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<Uniforms>.stride
        )
    }
}

// MARK: - MTKViewDelegate

extension MetalRenderer: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateViewport(size: size)
    }

    func draw(in view: MTKView) {
        // Skip if view size is invalid
        guard view.drawableSize.width > 0 && view.drawableSize.height > 0 else {
            return
        }

        time += 1.0 / 60.0

        // Update chunk manager based on camera position
        // ChunkManager는 원본 좌표계 사용, 카메라 타겟은 Z 반전되어 있으므로 다시 반전
        if isChunkManagerInitialized {
            let cameraXZ = SIMD3<Float>(camera.target.x, 0, -camera.target.z)
            if simd_distance(cameraXZ, lastCameraPosition) > 50 {
                chunkManager.update(cameraPosition: cameraXZ)
                lastCameraPosition = cameraXZ
            }
        }

        updateUniforms()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create command buffer")
            return
        }

        guard let drawable = view.currentDrawable else {
            print("No current drawable")
            return
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor else {
            print("No render pass descriptor")
            return
        }

        // Configure render pass
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.529, green: 0.808, blue: 0.922, alpha: 1.0  // Sky blue
        )

        // Reversed-Z: depth clear value를 0.0으로 설정 (기본값 1.0 대신)
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.depthAttachment.loadAction = .clear

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            print("Failed to create render encoder")
            return
        }

        renderEncoder.label = "Main Render Pass"
        renderEncoder.setDepthStencilState(depthState)

        // Draw ground grid
        drawGrid(encoder: renderEncoder)

        // Draw roads
        drawRoads(encoder: renderEncoder)

        // Draw buildings
        drawBuildings(encoder: renderEncoder)

        // Draw location marker
        drawLocationMarker(encoder: renderEncoder)

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawGrid(encoder: MTLRenderCommandEncoder) {
        encoder.pushDebugGroup("Draw Grid")
        encoder.setRenderPipelineState(gridPipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }

    private func drawBuildings(encoder: MTLRenderCommandEncoder) {
        guard isChunkManagerInitialized else { return }

        encoder.pushDebugGroup("Draw Buildings")
        encoder.setRenderPipelineState(buildingPipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))

        // Back-face culling 비활성화 (모든 면 렌더링)
        encoder.setCullMode(.none)

        var totalBuildings = 0
        let chunks = chunkManager.getLoadedChunks()

        for chunk in chunks {
            for building in chunk.buildings {
                guard let vertexBuffer = building.mesh.vertexBuffer,
                      let indexBuffer = building.mesh.indexBuffer else {
                    continue
                }

                // Set model matrix
                var modelMatrix = building.modelMatrix
                modelMatrixBuffer.contents().copyMemory(
                    from: &modelMatrix,
                    byteCount: MemoryLayout<simd_float4x4>.stride
                )
                encoder.setVertexBuffer(modelMatrixBuffer, offset: 0, index: Int(BufferIndexModelMatrix.rawValue))

                // Set color
                var color = building.color
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

                // Draw mesh
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
                encoder.drawIndexedPrimitives(
                    type: building.mesh.primitiveType,
                    indexCount: building.mesh.effectiveIndexCount,
                    indexType: .uint32,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
                totalBuildings += 1
            }
        }

        buildingCount = totalBuildings
        chunkCount = chunks.count
        encoder.popDebugGroup()
    }

    private func drawRoads(encoder: MTLRenderCommandEncoder) {
        guard isChunkManagerInitialized else { return }

        encoder.pushDebugGroup("Draw Roads")
        encoder.setRenderPipelineState(roadPipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))

        var totalRoads = 0
        let chunks = chunkManager.getLoadedChunks()

        for chunk in chunks {
            for road in chunk.roads {
                guard let vertexBuffer = road.mesh.vertexBuffer,
                      let indexBuffer = road.mesh.indexBuffer else {
                    continue
                }

                // Set model matrix (identity for roads)
                var modelMatrix = road.modelMatrix
                modelMatrixBuffer.contents().copyMemory(
                    from: &modelMatrix,
                    byteCount: MemoryLayout<simd_float4x4>.stride
                )
                encoder.setVertexBuffer(modelMatrixBuffer, offset: 0, index: Int(BufferIndexModelMatrix.rawValue))

                // Set color
                var color = road.color
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

                // Draw mesh
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
                encoder.drawIndexedPrimitives(
                    type: road.mesh.primitiveType,
                    indexCount: road.mesh.effectiveIndexCount,
                    indexType: .uint32,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
                totalRoads += 1
            }
        }

        roadCount = totalRoads
        encoder.popDebugGroup()
    }

    private func drawLocationMarker(encoder: MTLRenderCommandEncoder) {
        guard let mesh = locationMarkerMesh,
              let position = locationMarkerPosition,
              let vertexBuffer = mesh.vertexBuffer,
              let indexBuffer = mesh.indexBuffer else {
            return
        }

        encoder.pushDebugGroup("Draw Location Marker")
        encoder.setRenderPipelineState(markerPipeline)

        // Depth bias to prevent z-fighting (Reversed-Z: positive bias pushes closer)
        encoder.setDepthBias(0.0001, slopeScale: 1.0, clamp: 0.01)

        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))

        // Create model matrix with translation to marker position
        var modelMatrix = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(position.x, position.y, position.z, 1)
        )
        markerModelMatrixBuffer.contents().copyMemory(
            from: &modelMatrix,
            byteCount: MemoryLayout<simd_float4x4>.stride
        )
        encoder.setVertexBuffer(markerModelMatrixBuffer, offset: 0, index: Int(BufferIndexModelMatrix.rawValue))

        // Set marker color (red)
        var color = markerColor
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        // Draw cylinder
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
        encoder.drawIndexedPrimitives(
            type: mesh.primitiveType,
            indexCount: mesh.effectiveIndexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        // Reset depth bias
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)

        encoder.popDebugGroup()
    }
}

// MARK: - ChunkManagerDelegate

extension MetalRenderer: ChunkManagerDelegate {
    func chunkManager(_ manager: ChunkManager, didLoadChunk id: ChunkID) {
        // Chunk loaded, will be rendered in next frame
    }

    func chunkManager(_ manager: ChunkManager, didUnloadChunk id: ChunkID) {
        // Chunk unloaded
    }
}

// MARK: - Camera Controller Integration

extension MetalRenderer {

    func pan(dx: Float, dy: Float) {
        let sensitivity: Float = camera.distance * 0.002

        // Calculate right and forward vectors in world space
        let forward = normalize(SIMD3<Float>(
            camera.target.x - camera.position.x,
            0,
            camera.target.z - camera.position.z
        ))
        let right = normalize(cross(forward, SIMD3<Float>(0, 1, 0)))

        let movement = right * (-dx * sensitivity) + forward * (dy * sensitivity)
        camera.target += movement
    }

    func rotate(dx: Float, dy: Float) {
        let sensitivity: Float = 0.5
        camera.yaw -= dx * sensitivity
        camera.pitch = max(-89, min(-10, camera.pitch - dy * sensitivity))
    }

    func zoom(scale: Float) {
        camera.distance = max(camera.minDistance, min(camera.maxDistance, camera.distance / scale))
    }
}
