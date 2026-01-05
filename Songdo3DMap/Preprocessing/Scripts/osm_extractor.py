#!/usr/bin/env python3
"""
OpenStreetMap 데이터 추출기
인천 송도 지역의 건물, 도로 데이터를 Overpass API로 추출
"""

import json
import requests
import time
from dataclasses import dataclass, field
from typing import List, Tuple, Dict, Optional
from pathlib import Path

# 송도 바운딩 박스 (남서 → 북동)
SONGDO_BBOX = {
    "south": 37.355,
    "west": 126.615,
    "north": 37.425,
    "east": 126.725
}

# Overpass API 엔드포인트 (여러 서버 중 선택)
OVERPASS_URLS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
]
OVERPASS_URL = OVERPASS_URLS[0]  # 첫 번째 서버 사용

@dataclass
class Building:
    """건물 데이터"""
    id: int
    coordinates: List[Tuple[float, float]]  # (lon, lat) 리스트
    height: float = 10.0  # 기본 높이 10m
    levels: int = 3
    building_type: str = "yes"
    name: Optional[str] = None

    @property
    def footprint_area(self) -> float:
        """건물 바닥 면적 계산 (Shoelace formula)"""
        if len(self.coordinates) < 3:
            return 0
        n = len(self.coordinates)
        area = 0
        for i in range(n):
            j = (i + 1) % n
            area += self.coordinates[i][0] * self.coordinates[j][1]
            area -= self.coordinates[j][0] * self.coordinates[i][1]
        return abs(area) / 2

@dataclass
class Road:
    """도로 데이터"""
    id: int
    coordinates: List[Tuple[float, float]]  # (lon, lat) 리스트
    highway_type: str = "residential"
    name: Optional[str] = None
    lanes: int = 2
    width: float = 6.0  # 기본 폭 6m

    @property
    def length(self) -> float:
        """도로 길이 계산"""
        total = 0
        for i in range(len(self.coordinates) - 1):
            dx = self.coordinates[i+1][0] - self.coordinates[i][0]
            dy = self.coordinates[i+1][1] - self.coordinates[i][1]
            # 대략적인 미터 변환 (위도 1도 ≈ 111km)
            total += ((dx * 111000 * 0.85) ** 2 + (dy * 111000) ** 2) ** 0.5
        return total

@dataclass
class OSMData:
    """추출된 OSM 데이터"""
    buildings: List[Building] = field(default_factory=list)
    roads: List[Road] = field(default_factory=list)
    bbox: Dict = field(default_factory=lambda: SONGDO_BBOX.copy())


class OSMExtractor:
    """OpenStreetMap 데이터 추출기"""

    def __init__(self, bbox: Dict = None):
        self.bbox = bbox or SONGDO_BBOX
        self.nodes: Dict[int, Tuple[float, float]] = {}  # node_id -> (lon, lat)

    def _build_query(self, include_buildings=True, include_roads=True) -> str:
        """Overpass QL 쿼리 생성"""
        south, west = self.bbox["south"], self.bbox["west"]
        north, east = self.bbox["north"], self.bbox["east"]
        bbox_str = f"{south},{west},{north},{east}"

        parts = []

        if include_buildings:
            parts.append(f"""
  way["building"]({bbox_str});
  relation["building"]({bbox_str});""")

        if include_roads:
            parts.append(f"""
  way["highway"]({bbox_str});""")

        parts_str = ''.join(parts)
        query = f"""
[out:json][timeout:600];
({parts_str}
);
out body;
>;
out skel qt;
"""
        return query

    def fetch_data(self, include_buildings=True, include_roads=True) -> Dict:
        """Overpass API로 데이터 가져오기"""
        query = self._build_query(include_buildings, include_roads)

        print(f"Fetching OSM data for bbox: {self.bbox}")
        print(f"Query length: {len(query)} chars")

        # 여러 서버 시도
        for url in OVERPASS_URLS:
            try:
                print(f"Trying server: {url}")
                response = requests.post(
                    url,
                    data={"data": query},
                    timeout=600
                )
                response.raise_for_status()
                print(f"Success with server: {url}")
                return response.json()
            except requests.exceptions.RequestException as e:
                print(f"Error with {url}: {e}")
                continue

        raise Exception("All Overpass servers failed")

    def _parse_nodes(self, elements: List[Dict]):
        """노드 좌표 파싱"""
        for elem in elements:
            if elem["type"] == "node":
                self.nodes[elem["id"]] = (elem["lon"], elem["lat"])

    def _parse_height(self, tags: Dict) -> float:
        """건물 높이 파싱"""
        # height 태그가 있으면 사용
        if "height" in tags:
            try:
                h = tags["height"].replace("m", "").strip()
                return float(h)
            except ValueError:
                pass

        # building:levels로 추정 (층당 3m)
        if "building:levels" in tags:
            try:
                levels = int(tags["building:levels"])
                return levels * 3.0
            except ValueError:
                pass

        # 건물 타입별 기본 높이
        building_type = tags.get("building", "yes")
        default_heights = {
            "apartments": 30.0,
            "commercial": 15.0,
            "office": 25.0,
            "retail": 8.0,
            "industrial": 12.0,
            "warehouse": 10.0,
            "residential": 10.0,
            "house": 8.0,
            "yes": 10.0
        }
        return default_heights.get(building_type, 10.0)

    def _parse_road_width(self, tags: Dict) -> float:
        """도로 폭 파싱"""
        # width 태그가 있으면 사용
        if "width" in tags:
            try:
                w = tags["width"].replace("m", "").strip()
                return float(w)
            except ValueError:
                pass

        # lanes로 추정 (차선당 3.5m)
        if "lanes" in tags:
            try:
                lanes = int(tags["lanes"])
                return lanes * 3.5
            except ValueError:
                pass

        # 도로 타입별 기본 폭
        highway_type = tags.get("highway", "residential")
        default_widths = {
            "motorway": 14.0,
            "trunk": 12.0,
            "primary": 10.0,
            "secondary": 8.0,
            "tertiary": 7.0,
            "residential": 6.0,
            "service": 4.0,
            "footway": 2.0,
            "cycleway": 2.5,
            "path": 1.5
        }
        return default_widths.get(highway_type, 6.0)

    def _get_way_coords(self, node_refs: List[int]) -> List[Tuple[float, float]]:
        """way의 노드 참조를 좌표 리스트로 변환"""
        coords = []
        for node_id in node_refs:
            if node_id in self.nodes:
                coords.append(self.nodes[node_id])
        return coords

    def parse(self, data: Dict) -> OSMData:
        """OSM 응답 데이터 파싱"""
        elements = data.get("elements", [])

        # 먼저 모든 노드 파싱
        self._parse_nodes(elements)
        print(f"Parsed {len(self.nodes)} nodes")

        result = OSMData(bbox=self.bbox)

        # way 파싱
        for elem in elements:
            if elem["type"] != "way":
                continue

            tags = elem.get("tags", {})
            node_refs = elem.get("nodes", [])
            coords = self._get_way_coords(node_refs)

            if len(coords) < 2:
                continue

            # 건물인 경우
            if "building" in tags:
                building = Building(
                    id=elem["id"],
                    coordinates=coords,
                    height=self._parse_height(tags),
                    building_type=tags.get("building", "yes"),
                    name=tags.get("name")
                )
                if "building:levels" in tags:
                    try:
                        building.levels = int(tags["building:levels"])
                    except ValueError:
                        pass
                result.buildings.append(building)

            # 도로인 경우
            elif "highway" in tags:
                highway_type = tags.get("highway", "residential")
                # 보행자 전용도로, 자전거도로 등도 포함
                road = Road(
                    id=elem["id"],
                    coordinates=coords,
                    highway_type=highway_type,
                    name=tags.get("name"),
                    width=self._parse_road_width(tags)
                )
                if "lanes" in tags:
                    try:
                        road.lanes = int(tags["lanes"])
                    except ValueError:
                        pass
                result.roads.append(road)

        print(f"Parsed {len(result.buildings)} buildings, {len(result.roads)} roads")
        return result

    def extract(self) -> OSMData:
        """데이터 추출 및 파싱"""
        data = self.fetch_data()
        return self.parse(data)


def save_geojson(osm_data: OSMData, output_dir: Path):
    """GeoJSON 형식으로 저장"""
    output_dir.mkdir(parents=True, exist_ok=True)

    # 건물 GeoJSON
    buildings_geojson = {
        "type": "FeatureCollection",
        "features": []
    }

    for b in osm_data.buildings:
        if len(b.coordinates) < 3:
            continue
        # 폴리곤은 첫 좌표와 마지막 좌표가 같아야 함
        coords = b.coordinates[:]
        if coords[0] != coords[-1]:
            coords.append(coords[0])

        feature = {
            "type": "Feature",
            "id": b.id,
            "properties": {
                "height": b.height,
                "levels": b.levels,
                "building_type": b.building_type,
                "name": b.name
            },
            "geometry": {
                "type": "Polygon",
                "coordinates": [coords]
            }
        }
        buildings_geojson["features"].append(feature)

    with open(output_dir / "buildings.geojson", "w", encoding="utf-8") as f:
        json.dump(buildings_geojson, f, ensure_ascii=False, indent=2)

    # 도로 GeoJSON
    roads_geojson = {
        "type": "FeatureCollection",
        "features": []
    }

    for r in osm_data.roads:
        if len(r.coordinates) < 2:
            continue

        feature = {
            "type": "Feature",
            "id": r.id,
            "properties": {
                "highway_type": r.highway_type,
                "name": r.name,
                "lanes": r.lanes,
                "width": r.width
            },
            "geometry": {
                "type": "LineString",
                "coordinates": r.coordinates
            }
        }
        roads_geojson["features"].append(feature)

    with open(output_dir / "roads.geojson", "w", encoding="utf-8") as f:
        json.dump(roads_geojson, f, ensure_ascii=False, indent=2)

    # 메타데이터
    metadata = {
        "bbox": osm_data.bbox,
        "building_count": len(osm_data.buildings),
        "road_count": len(osm_data.roads),
        "total_road_length_km": sum(r.length for r in osm_data.roads) / 1000,
        "extracted_at": time.strftime("%Y-%m-%d %H:%M:%S")
    }

    with open(output_dir / "metadata.json", "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)

    print(f"Saved to {output_dir}")
    print(f"  - buildings.geojson: {len(osm_data.buildings)} buildings")
    print(f"  - roads.geojson: {len(osm_data.roads)} roads")


def main():
    """메인 실행"""
    import argparse

    parser = argparse.ArgumentParser(description="Extract OSM data for Songdo")
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path("output/osm"),
        help="Output directory"
    )
    parser.add_argument(
        "--bbox",
        type=str,
        help="Custom bbox: south,west,north,east"
    )

    args = parser.parse_args()

    bbox = SONGDO_BBOX
    if args.bbox:
        parts = [float(x) for x in args.bbox.split(",")]
        bbox = {
            "south": parts[0],
            "west": parts[1],
            "north": parts[2],
            "east": parts[3]
        }

    extractor = OSMExtractor(bbox)
    osm_data = extractor.extract()
    save_geojson(osm_data, args.output)


if __name__ == "__main__":
    main()
