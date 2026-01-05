#!/usr/bin/env python3
"""
청크 빌더
53km² 송도 영역을 500m 청크로 분할하여 바이너리 데이터 생성
"""

import json
import struct
import math
from dataclasses import dataclass, field
from typing import List, Tuple, Dict, Optional
from pathlib import Path
import numpy as np

from mesh_generator import (
    BuildingMeshGenerator, RoadMeshGenerator,
    geo_to_local, Vertex, Mesh, SONGDO_ORIGIN,
    LAT_TO_METERS, LON_TO_METERS
)

# 청크 설정
CHUNK_SIZE = 500.0  # 미터
MAGIC = b"SDC1"  # Songdo Data Chunk v1
VERSION = 1

# 송도 영역 크기 (대략)
SONGDO_WIDTH = 9200   # 미터 (동서)
SONGDO_HEIGHT = 7800  # 미터 (남북)


@dataclass
class ChunkBounds:
    """청크 경계"""
    x: int  # 청크 X 인덱스
    y: int  # 청크 Y 인덱스
    min_x: float  # 최소 X (미터)
    min_z: float  # 최소 Z (미터)
    max_x: float  # 최대 X (미터)
    max_z: float  # 최대 Z (미터)

    def contains_point(self, x: float, z: float) -> bool:
        return self.min_x <= x < self.max_x and self.min_z <= z < self.max_z

    def intersects_polygon(self, coords: List[Tuple[float, float]]) -> bool:
        """폴리곤이 청크와 교차하는지 확인"""
        # 간단한 AABB 테스트
        xs = [c[0] for c in coords]
        zs = [c[1] for c in coords]
        poly_min_x, poly_max_x = min(xs), max(xs)
        poly_min_z, poly_max_z = min(zs), max(zs)

        return not (poly_max_x < self.min_x or poly_min_x > self.max_x or
                   poly_max_z < self.min_z or poly_min_z > self.max_z)

    def intersects_line(self, coords: List[Tuple[float, float]]) -> bool:
        """라인이 청크와 교차하는지 확인"""
        for x, z in coords:
            if self.contains_point(x, z):
                return True
        return False


@dataclass
class ChunkData:
    """청크 데이터"""
    bounds: ChunkBounds
    buildings: List[Dict] = field(default_factory=list)
    roads: List[Dict] = field(default_factory=list)
    building_meshes: List[Mesh] = field(default_factory=list)
    road_meshes: List[Mesh] = field(default_factory=list)


class ChunkBuilder:
    """청크 빌더"""

    def __init__(self, origin: Dict = None, chunk_size: float = CHUNK_SIZE):
        self.origin = origin or SONGDO_ORIGIN
        self.chunk_size = chunk_size
        self.building_gen = BuildingMeshGenerator(origin)
        self.road_gen = RoadMeshGenerator(origin)

    def get_chunk_bounds(self, chunk_x: int, chunk_y: int) -> ChunkBounds:
        """청크 경계 계산"""
        min_x = chunk_x * self.chunk_size
        min_z = chunk_y * self.chunk_size
        max_x = min_x + self.chunk_size
        max_z = min_z + self.chunk_size

        return ChunkBounds(
            x=chunk_x, y=chunk_y,
            min_x=min_x, min_z=min_z,
            max_x=max_x, max_z=max_z
        )

    def get_chunk_for_point(self, x: float, z: float) -> Tuple[int, int]:
        """점이 속한 청크 인덱스 반환"""
        chunk_x = int(x // self.chunk_size)
        chunk_y = int(z // self.chunk_size)
        return (chunk_x, chunk_y)

    def assign_to_chunks(
        self,
        buildings_geojson: Dict,
        roads_geojson: Dict
    ) -> Dict[Tuple[int, int], ChunkData]:
        """건물/도로를 청크에 할당"""
        chunks: Dict[Tuple[int, int], ChunkData] = {}

        # 건물 할당
        for feature in buildings_geojson.get("features", []):
            coords = feature["geometry"]["coordinates"][0]
            props = feature["properties"]

            # 로컬 좌표 변환
            local_coords = [geo_to_local(lon, lat, self.origin) for lon, lat in coords]

            # 중심점으로 청크 결정
            center_x = sum(c[0] for c in local_coords) / len(local_coords)
            center_z = sum(c[1] for c in local_coords) / len(local_coords)
            chunk_idx = self.get_chunk_for_point(center_x, center_z)

            if chunk_idx not in chunks:
                chunks[chunk_idx] = ChunkData(
                    bounds=self.get_chunk_bounds(*chunk_idx)
                )

            chunks[chunk_idx].buildings.append({
                "id": feature.get("id"),
                "coords": coords,
                "local_coords": local_coords,
                "height": props.get("height", 10.0),
                "building_type": props.get("building_type", "yes"),
                "center": (center_x, center_z)
            })

        # 도로 할당 (여러 청크에 걸칠 수 있음)
        for feature in roads_geojson.get("features", []):
            coords = feature["geometry"]["coordinates"]
            props = feature["properties"]

            # 로컬 좌표 변환
            local_coords = [geo_to_local(lon, lat, self.origin) for lon, lat in coords]

            # 도로가 지나가는 모든 청크에 추가
            visited_chunks = set()
            for x, z in local_coords:
                chunk_idx = self.get_chunk_for_point(x, z)
                if chunk_idx in visited_chunks:
                    continue
                visited_chunks.add(chunk_idx)

                if chunk_idx not in chunks:
                    chunks[chunk_idx] = ChunkData(
                        bounds=self.get_chunk_bounds(*chunk_idx)
                    )

                # 해당 청크 내 도로 세그먼트 추출
                chunks[chunk_idx].roads.append({
                    "id": feature.get("id"),
                    "coords": coords,
                    "local_coords": local_coords,
                    "highway_type": props.get("highway_type", "residential"),
                    "width": props.get("width", 6.0)
                })

        return chunks

    def generate_chunk_meshes(self, chunk_data: ChunkData):
        """청크의 메시 생성"""
        # 건물 메시 생성
        for building in chunk_data.buildings:
            height = building["height"]
            mesh = self.building_gen.generate_mesh(building["coords"], height)
            if len(mesh.vertices) > 0:
                chunk_data.building_meshes.append(mesh)

        # 도로 메시 생성
        for road in chunk_data.roads:
            width = road["width"]
            mesh = self.road_gen.generate_mesh(road["coords"], width)
            if len(mesh.vertices) > 0:
                chunk_data.road_meshes.append(mesh)

    def write_chunk_binary(self, chunk_data: ChunkData, output_path: Path):
        """청크 바이너리 파일 생성"""
        with open(output_path, "wb") as f:
            # 헤더 (64 bytes)
            header = bytearray(64)

            # Magic + Version
            header[0:4] = MAGIC
            struct.pack_into("I", header, 4, VERSION)

            # 청크 인덱스
            struct.pack_into("ii", header, 8, chunk_data.bounds.x, chunk_data.bounds.y)

            # 건물/도로 개수
            struct.pack_into("I", header, 16, len(chunk_data.building_meshes))
            struct.pack_into("I", header, 20, len(chunk_data.road_meshes))

            # 오프셋 (나중에 채움)
            building_offset_pos = 24
            road_offset_pos = 32

            f.write(header)

            # 건물 섹션
            building_offset = f.tell()
            for i, mesh in enumerate(chunk_data.building_meshes):
                building = chunk_data.buildings[i]

                # 인스턴스 데이터 (48 bytes)
                instance_data = struct.pack(
                    "ffffffffHHI",
                    building["center"][0], 0.0, building["center"][1],  # position (12)
                    0.0,  # rotation (4)
                    1.0, 1.0, 1.0,  # scale (12)
                    building["height"],  # height (4)
                    0,  # texture_id (2)
                    0,  # flags (2)
                    0xFFFFFFFF  # color RGBA (4)
                )
                # padding to 48 bytes
                padding_size = 48 - len(instance_data)
                if padding_size > 0:
                    f.write(instance_data)
                    f.write(b'\x00' * padding_size)
                else:
                    f.write(instance_data[:48])

                # 메시 데이터
                f.write(struct.pack("II", len(mesh.vertices), len(mesh.indices)))
                for v in mesh.vertices:
                    f.write(v.to_bytes())
                for idx in mesh.indices:
                    f.write(struct.pack("I", idx))

            # 도로 섹션
            road_offset = f.tell()
            for i, mesh in enumerate(chunk_data.road_meshes):
                road = chunk_data.roads[i]

                # 도로 메타데이터 (16 bytes)
                highway_types = {
                    "motorway": 0, "trunk": 0, "primary": 1,
                    "secondary": 2, "tertiary": 2, "residential": 3,
                    "service": 3, "footway": 4, "cycleway": 4, "path": 4
                }
                road_type = highway_types.get(road["highway_type"], 3)

                f.write(struct.pack(
                    "BBfI",
                    road_type,  # road_type (1)
                    road.get("lanes", 2),  # lanes (1)
                    road["width"],  # width (4)
                    len(road["local_coords"])  # point_count (4)
                ))
                f.write(b'\x00' * 6)  # padding

                # 메시 데이터
                f.write(struct.pack("II", len(mesh.vertices), len(mesh.indices)))
                for v in mesh.vertices:
                    f.write(v.to_bytes())
                for idx in mesh.indices:
                    f.write(struct.pack("I", idx))

            # 오프셋 업데이트
            f.seek(building_offset_pos)
            f.write(struct.pack("Q", building_offset))
            f.seek(road_offset_pos)
            f.write(struct.pack("Q", road_offset))


def build_chunks(
    buildings_file: Path,
    roads_file: Path,
    output_dir: Path,
    origin: Dict = None
):
    """청크 빌드 메인 함수"""
    origin = origin or SONGDO_ORIGIN
    output_dir.mkdir(parents=True, exist_ok=True)
    chunks_dir = output_dir / "chunks"
    chunks_dir.mkdir(exist_ok=True)

    # GeoJSON 로드
    buildings_geojson = {"features": []}
    roads_geojson = {"features": []}

    if buildings_file.exists():
        with open(buildings_file, encoding="utf-8") as f:
            buildings_geojson = json.load(f)
        print(f"Loaded {len(buildings_geojson['features'])} buildings")

    if roads_file.exists():
        with open(roads_file, encoding="utf-8") as f:
            roads_geojson = json.load(f)
        print(f"Loaded {len(roads_geojson['features'])} roads")

    # 청크 빌더
    builder = ChunkBuilder(origin)

    # 청크에 할당
    chunks = builder.assign_to_chunks(buildings_geojson, roads_geojson)
    print(f"Created {len(chunks)} chunks")

    # 인덱스 파일 생성
    index = {
        "version": "1.0",
        "origin": origin,
        "chunk_size_meters": CHUNK_SIZE,
        "chunks": []
    }

    # 각 청크 처리
    for (cx, cy), chunk_data in chunks.items():
        print(f"Processing chunk ({cx}, {cy}): "
              f"{len(chunk_data.buildings)} buildings, "
              f"{len(chunk_data.roads)} roads")

        # 메시 생성
        builder.generate_chunk_meshes(chunk_data)

        # 바이너리 저장
        chunk_file = f"chunk_{cx}_{cy}.bin"
        builder.write_chunk_binary(chunk_data, chunks_dir / chunk_file)

        # 인덱스에 추가
        index["chunks"].append({
            "id": f"{cx}_{cy}",
            "file": f"chunks/{chunk_file}",
            "x": cx,
            "y": cy,
            "bounds": {
                "min_x": chunk_data.bounds.min_x,
                "min_z": chunk_data.bounds.min_z,
                "max_x": chunk_data.bounds.max_x,
                "max_z": chunk_data.bounds.max_z
            },
            "building_count": len(chunk_data.building_meshes),
            "road_count": len(chunk_data.road_meshes)
        })

    # 인덱스 저장
    with open(output_dir / "index.json", "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)

    print(f"\nOutput saved to {output_dir}")
    print(f"  - index.json")
    print(f"  - chunks/: {len(chunks)} chunk files")

    # 통계
    total_buildings = sum(len(c.buildings) for c in chunks.values())
    total_roads = sum(len(c.roads) for c in chunks.values())
    print(f"\nTotal: {total_buildings} buildings, {total_roads} road segments")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Build chunks from GeoJSON")
    parser.add_argument(
        "--input", "-i",
        type=Path,
        default=Path("output/osm"),
        help="Input directory with GeoJSON files"
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path("output/chunks"),
        help="Output directory for chunk data"
    )

    args = parser.parse_args()

    build_chunks(
        args.input / "buildings.geojson",
        args.input / "roads.geojson",
        args.output
    )


if __name__ == "__main__":
    main()
