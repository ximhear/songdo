#!/usr/bin/env python3
"""
3D 메시 생성기
GeoJSON 건물/도로 데이터를 3D 메시로 변환
"""

import json
import struct
import math
from dataclasses import dataclass, field
from typing import List, Tuple, Dict, Optional
from pathlib import Path
import numpy as np

# 송도 원점 (로컬 좌표계 기준점)
SONGDO_ORIGIN = {
    "latitude": 37.355,
    "longitude": 126.615
}

# 미터 변환 상수 (위도 37도 기준)
LAT_TO_METERS = 111000.0  # 위도 1도 ≈ 111km
LON_TO_METERS = 111000.0 * math.cos(math.radians(37.39))  # 경도 (위도에 따라 다름)


@dataclass
class Vertex:
    """버텍스"""
    position: Tuple[float, float, float]
    normal: Tuple[float, float, float]
    texcoord: Tuple[float, float]

    def to_bytes(self) -> bytes:
        """바이너리 변환 (32 bytes: 3+3+2 floats)"""
        return struct.pack(
            "8f",
            *self.position,
            *self.normal,
            *self.texcoord
        )


@dataclass
class Mesh:
    """메시 데이터"""
    vertices: List[Vertex] = field(default_factory=list)
    indices: List[int] = field(default_factory=list)

    def to_bytes(self) -> bytes:
        """바이너리 변환"""
        data = struct.pack("II", len(self.vertices), len(self.indices))
        for v in self.vertices:
            data += v.to_bytes()
        for idx in self.indices:
            data += struct.pack("I", idx)
        return data


@dataclass
class BuildingMesh:
    """건물 메시 + 인스턴스 데이터"""
    mesh: Mesh
    position: Tuple[float, float, float]
    height: float
    building_type: str
    lod_meshes: List[Mesh] = field(default_factory=list)


def geo_to_local(lon: float, lat: float, origin: Dict = None) -> Tuple[float, float]:
    """위경도를 로컬 좌표(미터)로 변환"""
    origin = origin or SONGDO_ORIGIN
    x = (lon - origin["longitude"]) * LON_TO_METERS
    z = (lat - origin["latitude"]) * LAT_TO_METERS
    return (x, z)


def triangulate_polygon(coords: List[Tuple[float, float]]) -> List[int]:
    """
    단순 폴리곤 삼각분할 (Ear Clipping 알고리즘)
    coords: (x, z) 좌표 리스트 (마지막 좌표는 첫 좌표와 같지 않아야 함)
    returns: 인덱스 리스트
    """
    if len(coords) < 3:
        return []

    # numpy 배열로 변환
    points = np.array(coords)
    n = len(points)

    # 폴리곤이 시계방향인지 확인 (반시계방향으로 변환)
    signed_area = 0
    for i in range(n):
        j = (i + 1) % n
        signed_area += points[i][0] * points[j][1]
        signed_area -= points[j][0] * points[i][1]

    if signed_area > 0:
        points = points[::-1]

    # 인덱스 리스트
    indices = list(range(n))
    triangles = []

    while len(indices) > 2:
        found_ear = False

        for i in range(len(indices)):
            prev_idx = indices[(i - 1) % len(indices)]
            curr_idx = indices[i]
            next_idx = indices[(i + 1) % len(indices)]

            prev_pt = points[prev_idx]
            curr_pt = points[curr_idx]
            next_pt = points[next_idx]

            # 볼록 정점인지 확인
            cross = (curr_pt[0] - prev_pt[0]) * (next_pt[1] - prev_pt[1]) - \
                    (curr_pt[1] - prev_pt[1]) * (next_pt[0] - prev_pt[0])

            if cross >= 0:
                continue  # 오목 정점

            # 다른 정점이 삼각형 안에 있는지 확인
            is_ear = True
            for j in indices:
                if j in (prev_idx, curr_idx, next_idx):
                    continue
                if point_in_triangle(points[j], prev_pt, curr_pt, next_pt):
                    is_ear = False
                    break

            if is_ear:
                triangles.extend([prev_idx, curr_idx, next_idx])
                indices.remove(curr_idx)
                found_ear = True
                break

        if not found_ear:
            # 실패 시 남은 점으로 팬 삼각분할
            for i in range(1, len(indices) - 1):
                triangles.extend([indices[0], indices[i], indices[i + 1]])
            break

    return triangles


def point_in_triangle(p, a, b, c) -> bool:
    """점이 삼각형 내부에 있는지 확인"""
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])

    d1 = sign(p, a, b)
    d2 = sign(p, b, c)
    d3 = sign(p, c, a)

    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)

    return not (has_neg and has_pos)


class BuildingMeshGenerator:
    """건물 메시 생성기"""

    def __init__(self, origin: Dict = None):
        self.origin = origin or SONGDO_ORIGIN

    def generate_mesh(self, coords: List[Tuple[float, float]], height: float) -> Mesh:
        """
        2D 폴리곤에서 3D 건물 메시 생성
        coords: (lon, lat) 좌표 리스트
        height: 건물 높이 (미터)
        """
        # 로컬 좌표로 변환
        local_coords = [geo_to_local(lon, lat, self.origin) for lon, lat in coords]

        # 마지막 좌표가 첫 좌표와 같으면 제거
        if len(local_coords) > 1 and local_coords[0] == local_coords[-1]:
            local_coords = local_coords[:-1]

        if len(local_coords) < 3:
            return Mesh()

        mesh = Mesh()

        # 1. 바닥면 생성 (y = 0)
        floor_start = len(mesh.vertices)
        for x, z in local_coords:
            mesh.vertices.append(Vertex(
                position=(x, 0, z),
                normal=(0, -1, 0),
                texcoord=(x / 10, z / 10)  # 10m당 1 UV
            ))

        floor_indices = triangulate_polygon(local_coords)
        # 바닥면은 아래를 향하므로 인덱스 순서 유지
        for idx in floor_indices:
            mesh.indices.append(floor_start + idx)

        # 2. 지붕면 생성 (y = height)
        roof_start = len(mesh.vertices)
        for x, z in local_coords:
            mesh.vertices.append(Vertex(
                position=(x, height, z),
                normal=(0, 1, 0),
                texcoord=(x / 10, z / 10)
            ))

        # 지붕면은 위를 향하므로 인덱스 순서 반전
        for i in range(0, len(floor_indices), 3):
            mesh.indices.append(roof_start + floor_indices[i])
            mesh.indices.append(roof_start + floor_indices[i + 2])
            mesh.indices.append(roof_start + floor_indices[i + 1])

        # 3. 벽면 생성
        n = len(local_coords)
        for i in range(n):
            j = (i + 1) % n

            x0, z0 = local_coords[i]
            x1, z1 = local_coords[j]

            # 벽 방향 벡터
            dx, dz = x1 - x0, z1 - z0
            length = math.sqrt(dx * dx + dz * dz)
            if length < 0.01:
                continue

            # 외향 법선 (오른손 법칙)
            nx, nz = dz / length, -dx / length

            # UV 좌표 (가로: 벽 길이, 세로: 높이)
            u0, u1 = 0, length / 3  # 3m당 1 UV (창문 패턴용)

            wall_start = len(mesh.vertices)

            # 4개 버텍스 (좌하, 우하, 우상, 좌상)
            mesh.vertices.append(Vertex((x0, 0, z0), (nx, 0, nz), (u0, 0)))
            mesh.vertices.append(Vertex((x1, 0, z1), (nx, 0, nz), (u1, 0)))
            mesh.vertices.append(Vertex((x1, height, z1), (nx, 0, nz), (u1, height / 3)))
            mesh.vertices.append(Vertex((x0, height, z0), (nx, 0, nz), (u0, height / 3)))

            # 2개 삼각형
            mesh.indices.extend([
                wall_start, wall_start + 1, wall_start + 2,
                wall_start, wall_start + 2, wall_start + 3
            ])

        return mesh

    def generate_lod_mesh(self, coords: List[Tuple[float, float]], height: float, lod: int) -> Mesh:
        """LOD 레벨별 메시 생성"""
        if lod == 0:
            return self.generate_mesh(coords, height)

        # 로컬 좌표로 변환
        local_coords = [geo_to_local(lon, lat, self.origin) for lon, lat in coords]
        if len(local_coords) > 1 and local_coords[0] == local_coords[-1]:
            local_coords = local_coords[:-1]

        if lod == 1:
            # LOD1: 폴리곤 단순화 (Douglas-Peucker 또는 점 수 감소)
            simplified = self._simplify_polygon(local_coords, tolerance=2.0)
            return self.generate_mesh(
                [(x, z) for x, z in simplified],
                height
            )

        else:  # LOD2+: 바운딩 박스
            return self._generate_box_mesh(local_coords, height)

    def _simplify_polygon(self, coords: List[Tuple[float, float]], tolerance: float) -> List[Tuple[float, float]]:
        """폴리곤 단순화 (Ramer-Douglas-Peucker)"""
        if len(coords) <= 4:
            return coords

        # 간단한 구현: 매 n번째 점만 유지
        step = max(1, len(coords) // 8)
        simplified = coords[::step]
        if simplified[-1] != coords[-1]:
            simplified.append(coords[-1])
        return simplified

    def _generate_box_mesh(self, coords: List[Tuple[float, float]], height: float) -> Mesh:
        """바운딩 박스 메시 생성"""
        xs = [c[0] for c in coords]
        zs = [c[1] for c in coords]
        min_x, max_x = min(xs), max(xs)
        min_z, max_z = min(zs), max(zs)

        box_coords = [
            (min_x, min_z),
            (max_x, min_z),
            (max_x, max_z),
            (min_x, max_z)
        ]

        # 박스 좌표를 위경도로 다시 변환하지 않고 직접 메시 생성
        mesh = Mesh()

        # 바닥
        for x, z in box_coords:
            mesh.vertices.append(Vertex((x, 0, z), (0, -1, 0), (x/10, z/10)))

        mesh.indices.extend([0, 1, 2, 0, 2, 3])

        # 지붕
        roof_start = 4
        for x, z in box_coords:
            mesh.vertices.append(Vertex((x, height, z), (0, 1, 0), (x/10, z/10)))

        mesh.indices.extend([roof_start, roof_start+2, roof_start+1,
                            roof_start, roof_start+3, roof_start+2])

        # 벽면 (4개)
        wall_normals = [(0, 0, -1), (1, 0, 0), (0, 0, 1), (-1, 0, 0)]
        for i in range(4):
            j = (i + 1) % 4
            x0, z0 = box_coords[i]
            x1, z1 = box_coords[j]
            nx, ny, nz = wall_normals[i]

            wall_start = len(mesh.vertices)
            mesh.vertices.extend([
                Vertex((x0, 0, z0), (nx, ny, nz), (0, 0)),
                Vertex((x1, 0, z1), (nx, ny, nz), (1, 0)),
                Vertex((x1, height, z1), (nx, ny, nz), (1, 1)),
                Vertex((x0, height, z0), (nx, ny, nz), (0, 1)),
            ])
            mesh.indices.extend([
                wall_start, wall_start+1, wall_start+2,
                wall_start, wall_start+2, wall_start+3
            ])

        return mesh


class RoadMeshGenerator:
    """도로 메시 생성기"""

    def __init__(self, origin: Dict = None):
        self.origin = origin or SONGDO_ORIGIN

    def generate_mesh(self, coords: List[Tuple[float, float]], width: float) -> Mesh:
        """
        폴리라인에서 도로 리본 메시 생성
        coords: (lon, lat) 좌표 리스트
        width: 도로 폭 (미터)
        """
        # 로컬 좌표로 변환
        local_coords = [geo_to_local(lon, lat, self.origin) for lon, lat in coords]

        if len(local_coords) < 2:
            return Mesh()

        mesh = Mesh()
        half_width = width / 2
        accumulated_length = 0

        for i in range(len(local_coords)):
            x, z = local_coords[i]

            # 진행 방향 계산
            if i == 0:
                dx = local_coords[1][0] - x
                dz = local_coords[1][1] - z
            elif i == len(local_coords) - 1:
                dx = x - local_coords[i-1][0]
                dz = z - local_coords[i-1][1]
            else:
                # 평균 방향
                dx = local_coords[i+1][0] - local_coords[i-1][0]
                dz = local_coords[i+1][1] - local_coords[i-1][1]

            length = math.sqrt(dx*dx + dz*dz)
            if length < 0.001:
                continue

            # 정규화 및 수직 벡터
            dx, dz = dx/length, dz/length
            px, pz = -dz, dx  # 수직 (왼쪽)

            # 좌우 버텍스
            left_x = x + px * half_width
            left_z = z + pz * half_width
            right_x = x - px * half_width
            right_z = z - pz * half_width

            # UV (v는 도로 방향으로 증가)
            v = accumulated_length / 10  # 10m당 1 UV

            mesh.vertices.append(Vertex(
                (left_x, 0.05, left_z),  # 약간 높임 (z-fighting 방지)
                (0, 1, 0),
                (0, v)
            ))
            mesh.vertices.append(Vertex(
                (right_x, 0.05, right_z),
                (0, 1, 0),
                (1, v)
            ))

            # 누적 길이
            if i > 0:
                prev_x, prev_z = local_coords[i-1]
                segment_len = math.sqrt((x-prev_x)**2 + (z-prev_z)**2)
                accumulated_length += segment_len

            # 삼각형 인덱스
            if i > 0:
                base = (i - 1) * 2
                mesh.indices.extend([
                    base, base + 1, base + 2,
                    base + 1, base + 3, base + 2
                ])

        return mesh


def process_geojson(input_dir: Path, output_dir: Path, origin: Dict = None):
    """GeoJSON 파일을 3D 메시로 변환"""
    origin = origin or SONGDO_ORIGIN
    output_dir.mkdir(parents=True, exist_ok=True)

    building_gen = BuildingMeshGenerator(origin)
    road_gen = RoadMeshGenerator(origin)

    # 건물 처리
    buildings_file = input_dir / "buildings.geojson"
    if buildings_file.exists():
        with open(buildings_file, encoding="utf-8") as f:
            data = json.load(f)

        buildings = []
        for feature in data["features"]:
            coords = feature["geometry"]["coordinates"][0]
            props = feature["properties"]
            height = props.get("height", 10.0)

            # LOD0 메시 생성
            mesh = building_gen.generate_mesh(coords, height)
            if len(mesh.vertices) == 0:
                continue

            # 중심점 계산
            local_coords = [geo_to_local(lon, lat, origin) for lon, lat in coords]
            center_x = sum(c[0] for c in local_coords) / len(local_coords)
            center_z = sum(c[1] for c in local_coords) / len(local_coords)

            buildings.append({
                "id": feature["id"],
                "position": (center_x, 0, center_z),
                "height": height,
                "building_type": props.get("building_type", "yes"),
                "vertex_count": len(mesh.vertices),
                "index_count": len(mesh.indices)
            })

        # 건물 메타데이터 저장
        with open(output_dir / "buildings_meta.json", "w", encoding="utf-8") as f:
            json.dump({
                "count": len(buildings),
                "buildings": buildings
            }, f, ensure_ascii=False, indent=2)

        print(f"Processed {len(buildings)} buildings")

    # 도로 처리
    roads_file = input_dir / "roads.geojson"
    if roads_file.exists():
        with open(roads_file, encoding="utf-8") as f:
            data = json.load(f)

        roads = []
        for feature in data["features"]:
            coords = feature["geometry"]["coordinates"]
            props = feature["properties"]
            width = props.get("width", 6.0)

            mesh = road_gen.generate_mesh(coords, width)
            if len(mesh.vertices) == 0:
                continue

            roads.append({
                "id": feature["id"],
                "highway_type": props.get("highway_type", "residential"),
                "width": width,
                "vertex_count": len(mesh.vertices),
                "index_count": len(mesh.indices)
            })

        # 도로 메타데이터 저장
        with open(output_dir / "roads_meta.json", "w", encoding="utf-8") as f:
            json.dump({
                "count": len(roads),
                "roads": roads
            }, f, ensure_ascii=False, indent=2)

        print(f"Processed {len(roads)} roads")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Generate 3D meshes from GeoJSON")
    parser.add_argument(
        "--input", "-i",
        type=Path,
        default=Path("output/osm"),
        help="Input directory with GeoJSON files"
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path("output/meshes"),
        help="Output directory for mesh data"
    )

    args = parser.parse_args()
    process_geojson(args.input, args.output)


if __name__ == "__main__":
    main()
