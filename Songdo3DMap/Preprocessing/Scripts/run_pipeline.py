#!/usr/bin/env python3
"""
송도 3D 지도 데이터 파이프라인 실행 스크립트
1. OSM 데이터 추출
2. 메시 생성
3. 청크 빌드
"""

import argparse
import sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(
        description="Songdo 3D Map Data Pipeline"
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path("output"),
        help="Output base directory"
    )
    parser.add_argument(
        "--skip-download",
        action="store_true",
        help="Skip OSM data download (use existing data)"
    )
    parser.add_argument(
        "--small-area",
        action="store_true",
        help="Use smaller test area (Songdo Central Park vicinity)"
    )

    args = parser.parse_args()

    output_dir = args.output
    osm_dir = output_dir / "osm"
    chunks_dir = output_dir / "chunks"

    # 작은 테스트 영역 (송도 센트럴파크 주변 약 2km x 2km)
    small_bbox = {
        "south": 37.390,
        "west": 126.635,
        "north": 37.405,
        "east": 126.660
    }

    print("=" * 60)
    print("Songdo 3D Map Data Pipeline")
    print("=" * 60)

    # Step 1: OSM 데이터 추출
    if not args.skip_download:
        print("\n[Step 1/3] Extracting OSM data...")
        print("-" * 40)

        from osm_extractor import OSMExtractor, save_geojson, SONGDO_BBOX

        bbox = small_bbox if args.small_area else SONGDO_BBOX
        print(f"Bounding box: {bbox}")

        try:
            extractor = OSMExtractor(bbox)
            osm_data = extractor.extract()
            save_geojson(osm_data, osm_dir)
            print("OSM extraction complete!")
        except Exception as e:
            print(f"Error during OSM extraction: {e}")
            sys.exit(1)
    else:
        print("\n[Step 1/3] Skipping OSM download (using existing data)")

    # Step 2: 청크 빌드
    print("\n[Step 2/3] Building chunks...")
    print("-" * 40)

    from chunk_builder import build_chunks, SONGDO_ORIGIN

    buildings_file = osm_dir / "buildings.geojson"
    roads_file = osm_dir / "roads.geojson"

    if not buildings_file.exists() and not roads_file.exists():
        print("Error: No GeoJSON files found. Run without --skip-download first.")
        sys.exit(1)

    origin = SONGDO_ORIGIN
    if args.small_area:
        origin = {
            "latitude": small_bbox["south"],
            "longitude": small_bbox["west"]
        }

    build_chunks(buildings_file, roads_file, chunks_dir, origin)
    print("Chunk building complete!")

    # Step 3: 앱 리소스 디렉토리로 복사
    print("\n[Step 3/3] Copying to app resources...")
    print("-" * 40)

    import shutil

    app_resources = Path(__file__).parent.parent.parent / "Resources" / "MapData"
    app_resources.mkdir(parents=True, exist_ok=True)

    # index.json 복사
    if (chunks_dir / "index.json").exists():
        shutil.copy(chunks_dir / "index.json", app_resources / "index.json")
        print(f"Copied index.json to {app_resources}")

    # chunks 디렉토리 복사
    app_chunks = app_resources / "chunks"
    if app_chunks.exists():
        shutil.rmtree(app_chunks)
    if (chunks_dir / "chunks").exists():
        shutil.copytree(chunks_dir / "chunks", app_chunks)
        chunk_count = len(list(app_chunks.glob("*.bin")))
        print(f"Copied {chunk_count} chunk files to {app_chunks}")

    print("\n" + "=" * 60)
    print("Pipeline complete!")
    print("=" * 60)
    print(f"\nOutput files:")
    print(f"  - {osm_dir}/buildings.geojson")
    print(f"  - {osm_dir}/roads.geojson")
    print(f"  - {chunks_dir}/index.json")
    print(f"  - {chunks_dir}/chunks/*.bin")
    print(f"  - {app_resources}/ (app bundle)")


if __name__ == "__main__":
    main()
