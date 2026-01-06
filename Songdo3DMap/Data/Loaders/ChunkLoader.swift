import Foundation
import Metal

/// 청크 데이터 로더
final class ChunkLoader {

    // MARK: - Constants

    private static let magic = "SDC1".data(using: .ascii)!
    private static let headerSize = 64
    private static let instanceSize = 48
    private static let vertexSize = 32  // 8 floats

    // MARK: - Properties

    private let device: MTLDevice
    private let resourcesURL: URL
    private var chunkIndex: ChunkIndex?
    private var chunkInfoMap: [ChunkID: ChunkIndex.ChunkInfo] = [:]

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device

        // 앱 번들의 MapData 디렉토리
        if let bundleURL = Bundle.main.url(forResource: "MapData", withExtension: nil) {
            self.resourcesURL = bundleURL
            print("ChunkLoader: Found MapData at \(bundleURL.path)")
        } else if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("MapData") {
            self.resourcesURL = bundleURL
            print("ChunkLoader: Using fallback MapData at \(bundleURL.path)")
        } else {
            // 개발 중 fallback
            self.resourcesURL = URL(fileURLWithPath: "/Users/gzonelee/git/songdo/Songdo3DMap/Resources/MapData")
            print("ChunkLoader: Using development fallback path")
        }
    }

    // MARK: - Index Loading

    func loadIndex() throws {
        let indexURL = resourcesURL.appendingPathComponent("index.json")

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw ChunkLoaderError.indexNotFound
        }

        let data = try Data(contentsOf: indexURL)
        chunkIndex = try JSONDecoder().decode(ChunkIndex.self, from: data)

        // 청크 정보 맵 구축
        chunkInfoMap.removeAll()
        for info in chunkIndex?.chunks ?? [] {
            let id = ChunkID(from: info)
            chunkInfoMap[id] = info
        }

        print("Loaded chunk index: \(chunkInfoMap.count) chunks")
    }

    // MARK: - Chunk Loading

    func loadChunk(id: ChunkID) throws -> LoadedChunk? {
        guard let info = chunkInfoMap[id] else {
            return nil
        }

        let chunkURL = resourcesURL.appendingPathComponent(info.file)

        guard FileManager.default.fileExists(atPath: chunkURL.path) else {
            throw ChunkLoaderError.chunkFileNotFound(id)
        }

        let data = try Data(contentsOf: chunkURL)
        return try parseChunkData(data, id: id, info: info)
    }

    func loadChunkAsync(id: ChunkID, completion: @escaping (Result<LoadedChunk?, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let chunk = try self?.loadChunk(id: id)
                DispatchQueue.main.async {
                    completion(.success(chunk))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Chunk Parsing

    private func parseChunkData(_ data: Data, id: ChunkID, info: ChunkIndex.ChunkInfo) throws -> LoadedChunk {
        guard data.count >= Self.headerSize else {
            throw ChunkLoaderError.invalidChunkFormat
        }

        // 매직 넘버 확인
        let magic = data.subdata(in: 0..<4)
        guard magic == Self.magic else {
            throw ChunkLoaderError.invalidMagic
        }

        // 헤더 파싱
        var offset = 8  // Skip magic + version
        let chunkX: Int32 = data.read(at: offset)
        let chunkY: Int32 = data.read(at: offset + 4)
        offset += 8

        let buildingCount: UInt32 = data.read(at: offset)
        let roadCount: UInt32 = data.read(at: offset + 4)
        offset += 8

        let buildingOffset: UInt64 = data.read(at: offset)
        let roadOffset: UInt64 = data.read(at: offset + 8)

        // 경계 생성
        let bounds = ChunkBounds(
            minX: info.bounds.minX,
            minZ: info.bounds.minZ,
            maxX: info.bounds.maxX,
            maxZ: info.bounds.maxZ
        )

        // 건물 파싱
        var buildings: [BuildingData] = []
        var currentOffset = Int(buildingOffset)

        for _ in 0..<buildingCount {
            guard currentOffset + Self.instanceSize <= data.count else { break }

            // 인스턴스 데이터 (48 bytes)
            let posX: Float = data.read(at: currentOffset)
            let posY: Float = data.read(at: currentOffset + 4)
            let posZ: Float = data.read(at: currentOffset + 8)
            let rotation: Float = data.read(at: currentOffset + 12)
            let scaleX: Float = data.read(at: currentOffset + 16)
            let scaleY: Float = data.read(at: currentOffset + 20)
            let scaleZ: Float = data.read(at: currentOffset + 24)
            let height: Float = data.read(at: currentOffset + 28)
            let textureId: UInt16 = data.read(at: currentOffset + 32)
            let flags: UInt16 = data.read(at: currentOffset + 34)
            let color: UInt32 = data.read(at: currentOffset + 36)

            currentOffset += Self.instanceSize

            // 메시 데이터
            guard currentOffset + 8 <= data.count else { break }
            let vertexCount: UInt32 = data.read(at: currentOffset)
            let indexCount: UInt32 = data.read(at: currentOffset + 4)
            currentOffset += 8

            // 버텍스 읽기
            var vertices: [Vertex] = []
            for _ in 0..<vertexCount {
                guard currentOffset + Self.vertexSize <= data.count else { break }
                let vertex = parseVertex(from: data, at: currentOffset)
                vertices.append(vertex)
                currentOffset += Self.vertexSize
            }

            // 인덱스 읽기
            var indices: [UInt32] = []
            for _ in 0..<indexCount {
                guard currentOffset + 4 <= data.count else { break }
                let index: UInt32 = data.read(at: currentOffset)
                indices.append(index)
                currentOffset += 4
            }

            let building = BuildingData(
                position: SIMD3(posX, posY, posZ),
                rotation: rotation,
                scale: SIMD3(scaleX, scaleY, scaleZ),
                height: height,
                textureId: textureId,
                flags: flags,
                color: color,
                vertices: vertices,
                indices: indices
            )
            buildings.append(building)
        }

        // 도로 파싱
        // Python struct.pack("BBfI") with native alignment = 12 bytes + 6 bytes padding = 18 bytes
        // Offsets: roadType(0), lanes(1), padding(2-3), width(4-7), pointCount(8-11), padding(12-17)
        var roads: [RoadData] = []
        currentOffset = Int(roadOffset)

        for roadIdx in 0..<roadCount {
            guard currentOffset + 18 <= data.count else { break }

            let roadType: UInt8 = data.read(at: currentOffset)
            let lanes: UInt8 = data.read(at: currentOffset + 1)
            // 2 bytes padding at offset 2-3
            let width: Float = data.read(at: currentOffset + 4)
            let pointCount: UInt32 = data.read(at: currentOffset + 8)

            currentOffset += 18  // 12 bytes struct + 6 bytes explicit padding

            // 메시 데이터
            guard currentOffset + 8 <= data.count else { break }
            let vertexCount: UInt32 = data.read(at: currentOffset)
            let indexCount: UInt32 = data.read(at: currentOffset + 4)

//            if roadIdx == 0 {
//                print("Road[\(roadIdx)]: type=\(roadType), lanes=\(lanes), width=\(width), verts=\(vertexCount), indices=\(indexCount)")
//            }

            currentOffset += 8

            // 버텍스 읽기
            var vertices: [Vertex] = []
            for _ in 0..<vertexCount {
                guard currentOffset + Self.vertexSize <= data.count else { break }
                let vertex = parseVertex(from: data, at: currentOffset)
                vertices.append(vertex)
                currentOffset += Self.vertexSize
            }

            // 인덱스 읽기
            var indices: [UInt32] = []
            for _ in 0..<indexCount {
                guard currentOffset + 4 <= data.count else { break }
                let index: UInt32 = data.read(at: currentOffset)
                indices.append(index)
                currentOffset += 4
            }

            let road = RoadData(
                roadType: roadType,
                lanes: lanes,
                width: width,
                pointCount: pointCount,
                vertices: vertices,
                indices: indices
            )
            roads.append(road)
        }

        return LoadedChunk(
            id: id,
            bounds: bounds,
            buildings: buildings,
            roads: roads
        )
    }

    private func parseVertex(from data: Data, at offset: Int) -> Vertex {
        let px: Float = data.read(at: offset)
        let py: Float = data.read(at: offset + 4)
        let pz: Float = data.read(at: offset + 8)
        let nx: Float = data.read(at: offset + 12)
        let ny: Float = data.read(at: offset + 16)
        let nz: Float = data.read(at: offset + 20)
        let u: Float = data.read(at: offset + 24)
        let v: Float = data.read(at: offset + 28)

        return Vertex(
            position: SIMD3(px, py, pz),
            normal: SIMD3(nx, ny, nz),
            texCoord: SIMD2(u, v)
        )
    }

    // MARK: - Utilities

    func getAllChunkIDs() -> [ChunkID] {
        Array(chunkInfoMap.keys)
    }

    func getChunkInfo(for id: ChunkID) -> ChunkIndex.ChunkInfo? {
        chunkInfoMap[id]
    }

    func getChunksInRange(center: SIMD3<Float>, radius: Float) -> [ChunkID] {
        guard let index = chunkIndex else { return [] }

        let chunkSize = index.chunkSizeMeters

        return chunkInfoMap.keys.filter { id in
            guard let info = chunkInfoMap[id] else { return false }
            let chunkCenter = SIMD3<Float>(
                (info.bounds.minX + info.bounds.maxX) / 2,
                0,
                (info.bounds.minZ + info.bounds.maxZ) / 2
            )
            let distance = simd_length(center - chunkCenter)
            return distance <= radius + chunkSize
        }
    }
}

// MARK: - Errors

enum ChunkLoaderError: Error {
    case indexNotFound
    case chunkFileNotFound(ChunkID)
    case invalidChunkFormat
    case invalidMagic
}

// MARK: - Data Extension

extension Data {
    func read<T>(at offset: Int) -> T {
        self.subdata(in: offset..<offset + MemoryLayout<T>.size)
            .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
