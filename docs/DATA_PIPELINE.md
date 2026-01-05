# 송도 3D 지도 데이터 파이프라인

이 문서는 iOS 앱에 표시되는 3D 건물과 도로 데이터가 어떻게 생성되는지 설명합니다.

## 개요

```
OpenStreetMap (OSM)
       ↓
   OSM 추출기 (Python)
       ↓
   메시 생성기 (Python)
       ↓
   청크 빌더 (Python)
       ↓
   .bin 파일들 (바이너리)
       ↓
   iOS 앱 (Swift/Metal)
```

---

## 1. 데이터 소스: OpenStreetMap (OSM)

### OSM이란?
- 오픈소스 지도 프로젝트 (https://www.openstreetmap.org)
- 전 세계 사용자가 기여하는 무료 지도 데이터
- 건물, 도로, POI 등 다양한 지리 정보 포함

### 송도 지역 데이터
- **위치**: 인천광역시 연수구 송도동 일대
- **기준점 (Origin)**: 위도 37.39°, 경도 126.635°
- **범위**: 약 3.5km × 3.5km (테스트 데이터 기준)

### OSM 데이터 구조
```
OSM 데이터
├── Node (점) - 위도/경도 좌표
├── Way (선/면) - Node들의 연결
│   ├── building=yes → 건물
│   ├── highway=* → 도로
│   └── ...
└── Relation (관계) - Way들의 그룹
```

---

## 2. OSM 데이터 추출 (osm_extractor.py)

### 역할
OSM 원본 데이터에서 건물과 도로 정보만 추출합니다.

### 추출 정보

#### 건물 (Buildings)
```python
{
    "id": "way/123456",
    "type": "building",
    "geometry": [[lon1, lat1], [lon2, lat2], ...],  # 폴리곤 좌표
    "tags": {
        "building": "apartments",
        "height": "45",           # 높이 (미터)
        "building:levels": "15",  # 층수
        "name": "송도 타워"
    }
}
```

#### 도로 (Roads)
```python
{
    "id": "way/789012",
    "type": "road",
    "geometry": [[lon1, lat1], [lon2, lat2], ...],  # 라인스트링 좌표
    "tags": {
        "highway": "primary",     # 도로 유형
        "lanes": "4",             # 차선 수
        "name": "송도대로",
        "width": "20"             # 도로 폭 (미터)
    }
}
```

### 도로 유형별 기본 폭
| highway 태그 | 기본 폭 (m) |
|-------------|-----------|
| motorway | 15.0 |
| primary | 12.0 |
| secondary | 10.0 |
| tertiary | 8.0 |
| residential | 6.0 |
| footway | 2.0 |

---

## 3. 좌표 변환

### WGS84 → 로컬 좌표계

GPS 좌표(위도/경도)를 미터 단위 로컬 좌표로 변환합니다.

```python
# 기준점
ORIGIN = {
    "latitude": 37.39,
    "longitude": 126.635
}

# 변환 상수
LAT_TO_METERS = 111000.0  # 위도 1도 ≈ 111km
LON_TO_METERS = 111000.0 * cos(radians(37.39))  # 경도 (위도에 따라 다름)
                                                 # ≈ 88,000m

# 변환 함수
def geo_to_local(lon, lat):
    x = (lon - ORIGIN["longitude"]) * LON_TO_METERS
    z = (lat - ORIGIN["latitude"]) * LAT_TO_METERS
    return (x, z)
```

### 좌표계
```
      Z (북쪽, +)
      ↑
      │
      │
      └────→ X (동쪽, +)
     원점
   (37.39°N, 126.635°E)

Y = 높이 (위쪽, +)
```

---

## 4. 메시 생성 (mesh_generator.py)

### 건물 메시 생성

#### 입력
- 건물 폴리곤 좌표 (2D)
- 높이 정보 (태그 또는 층수로 계산)

#### 처리 과정

1. **바닥면 생성**
   ```
   폴리곤 좌표들 → earcut 삼각분할 → 바닥 삼각형들
   ```

2. **측면(벽) 생성**
   ```
   각 변(edge)마다:
     - 4개 버텍스 (하단 2개, 상단 2개)
     - 2개 삼각형
   ```

3. **지붕 생성**
   ```
   바닥면과 동일한 삼각형들을 높이(Y)만큼 위로 이동
   ```

#### 출력 버텍스 구조
```python
class GPUVertex:
    position: (x, y, z)   # 3D 위치
    normal: (nx, ny, nz)  # 법선 벡터 (조명용)
    texCoord: (u, v)      # 텍스처 좌표
```

#### 높이 계산 로직
```python
def calculate_height(tags):
    # 1. height 태그 직접 사용
    if "height" in tags:
        return float(tags["height"])

    # 2. 층수로 계산 (층당 3m)
    if "building:levels" in tags:
        return int(tags["building:levels"]) * 3.0

    # 3. 건물 유형별 기본값
    building_type = tags.get("building", "yes")
    defaults = {
        "apartments": 30.0,
        "commercial": 15.0,
        "house": 8.0,
        "yes": 10.0  # 기본값
    }
    return defaults.get(building_type, 10.0)
```

### 도로 메시 생성

#### 입력
- 도로 중심선 좌표들
- 도로 폭

#### 처리 과정

1. **중심선을 폴리곤으로 확장**
   ```
   각 세그먼트마다:
     - 진행 방향의 수직 벡터 계산
     - 좌우로 폭/2 만큼 확장
   ```

2. **교차점 처리**
   ```
   연속된 세그먼트의 확장선 교차점 계산 (miter join)
   ```

3. **삼각분할**
   ```
   확장된 폴리곤 → earcut → 삼각형들
   ```

#### 도로 Y 좌표
- 도로는 Y = 0 (지면)
- 셰이더에서 +0.15m 올려서 z-fighting 방지

---

## 5. 청크 시스템 (chunk_builder.py)

### 청크란?
- 큰 지도를 작은 타일로 분할한 것
- 카메라 위치에 따라 필요한 청크만 로드/언로드
- 메모리 효율성과 성능 최적화

### 청크 구조
```
전체 지도
┌─────┬─────┬─────┬─────┐
│ 0,3 │ 1,3 │ 2,3 │ 3,3 │
├─────┼─────┼─────┼─────┤
│ 0,2 │ 1,2 │ 2,2 │ 3,2 │
├─────┼─────┼─────┼─────┤
│ 0,1 │ 1,1 │ 2,1 │ 3,1 │
├─────┼─────┼─────┼─────┤
│ 0,0 │ 1,0 │ 2,0 │ 3,0 │
└─────┴─────┴─────┴─────┘

각 청크: 500m × 500m
```

### 청크 할당 로직
```python
CHUNK_SIZE = 500  # 미터

def get_chunk_id(x, z):
    chunk_x = int(floor(x / CHUNK_SIZE))
    chunk_z = int(floor(z / CHUNK_SIZE))
    return f"{chunk_x}_{chunk_z}"

# 건물은 중심점 기준으로 청크 할당
# 도로는 세그먼트별로 해당 청크에 할당
```

---

## 6. 바이너리 파일 포맷

### index.json
```json
{
    "version": 1,
    "origin": {
        "latitude": 37.39,
        "longitude": 126.635
    },
    "chunk_size_meters": 500,
    "chunks": [
        {
            "id": "0_0",
            "file": "chunks/chunk_0_0.bin",
            "x": 0,
            "y": 0,
            "bounds": {
                "min_x": 0.0,
                "min_z": 0.0,
                "max_x": 500.0,
                "max_z": 500.0
            },
            "building_count": 25,
            "road_count": 42
        },
        ...
    ]
}
```

### chunk_X_Y.bin 구조

```
┌──────────────────────────────────────┐
│            HEADER (32 bytes)          │
├──────────────────────────────────────┤
│  magic: "CHK1" (4 bytes)             │
│  version: UInt32 (4 bytes)            │
│  buildingCount: UInt32 (4 bytes)      │
│  roadCount: UInt32 (4 bytes)          │
│  buildingSectionOffset: UInt64        │
│  roadSectionOffset: UInt64            │
├──────────────────────────────────────┤
│         BUILDING SECTION              │
├──────────────────────────────────────┤
│  Building 0:                          │
│    vertexCount: UInt32                │
│    indexCount: UInt32                 │
│    position: Float32 × 3              │
│    boundingBox: Float32 × 6           │
│    vertices: GPUVertex × vertexCount  │
│    indices: UInt32 × indexCount       │
│  Building 1: ...                      │
│  ...                                  │
├──────────────────────────────────────┤
│           ROAD SECTION                │
├──────────────────────────────────────┤
│  Road 0:                              │
│    vertexCount: UInt32                │
│    indexCount: UInt32                 │
│    roadType: UInt8                    │
│    vertices: GPUVertex × vertexCount  │
│    indices: UInt32 × indexCount       │
│  Road 1: ...                          │
│  ...                                  │
└──────────────────────────────────────┘
```

### GPUVertex 구조 (32 bytes)
```
offset 0:  position.x (Float32)
offset 4:  position.y (Float32)
offset 8:  position.z (Float32)
offset 12: normal.x (Float32)
offset 16: normal.y (Float32)
offset 20: normal.z (Float32)
offset 24: texCoord.u (Float32)
offset 28: texCoord.v (Float32)
```

---

## 7. iOS 앱에서의 로딩

### ChunkLoader.swift
```swift
// 1. index.json 로드
func loadIndex() throws {
    let indexURL = Bundle.main.url(forResource: "index",
                                    withExtension: "json",
                                    subdirectory: "MapData")
    let data = try Data(contentsOf: indexURL)
    let index = try JSONDecoder().decode(ChunkIndex.self, from: data)
}

// 2. 청크 바이너리 로드
func loadChunk(id: ChunkID) throws -> ChunkData {
    let chunkURL = Bundle.main.url(forResource: "chunk_\(id)",
                                    withExtension: "bin",
                                    subdirectory: "MapData/chunks")
    let data = try Data(contentsOf: chunkURL)
    return parseChunkData(data)
}
```

### ChunkManager.swift
```swift
// 카메라 위치 기반 청크 로드/언로드
func update(cameraPosition: SIMD3<Float>) {
    // loadRadius 내의 청크 로드
    // unloadRadius 밖의 청크 언로드
}
```

### Metal 렌더링
```swift
// 각 건물/도로 메시를 GPU 버퍼로 변환
let vertexBuffer = device.makeBuffer(bytes: vertices, ...)
let indexBuffer = device.makeBuffer(bytes: indices, ...)

// 드로우 콜
encoder.setVertexBuffer(vertexBuffer, ...)
encoder.drawIndexedPrimitives(type: .triangle,
                               indexCount: indexCount,
                               indexType: .uint32,
                               indexBuffer: indexBuffer, ...)
```

---

## 8. 전처리 실행 방법

### 환경 설정
```bash
cd Songdo3DMap/Preprocessing
pip install -r requirements.txt
```

### 데이터 생성
```bash
# 1. OSM에서 송도 데이터 추출
python Scripts/osm_extractor.py

# 2. 메시 생성 및 청크 빌드
python Scripts/chunk_builder.py

# 3. 결과 확인
ls -la ../Resources/MapData/
ls -la ../Resources/MapData/chunks/
```

### 출력 파일
```
Resources/MapData/
├── index.json           # 청크 인덱스
└── chunks/
    ├── chunk_0_0.bin    # 청크 데이터
    ├── chunk_0_1.bin
    ├── chunk_1_0.bin
    └── ...
```

---

## 9. 데이터 통계 (테스트 데이터)

| 항목 | 값 |
|-----|---|
| 총 청크 수 | 36개 |
| 총 건물 수 | ~400개 |
| 총 도로 수 | ~750개 |
| 데이터 범위 | X: -500 ~ 3000m, Z: -1000 ~ 2500m |
| 청크 크기 | 500m × 500m |

---

## 10. 확장 계획

### 전체 송도 지역
- 면적: ~53km² (현재의 ~4배)
- 예상 청크 수: ~200개
- LOD (Level of Detail) 시스템 필요

### 추가 데이터
- 공원, 수역 (water)
- 랜드마크 건물 상세 모델
- 지하철역, 버스정류장
- 도로 차선 및 신호등
