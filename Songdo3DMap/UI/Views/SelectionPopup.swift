import SwiftUI

/// 선택된 객체 정보를 표시하는 팝업 뷰
struct SelectionPopup: View {
    let selection: SelectionResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(headerTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // Content
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground).opacity(0.95))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .frame(maxWidth: 300)
    }

    private var headerTitle: String {
        switch selection {
        case .building:
            return "건물 정보"
        case .road:
            return "도로 정보"
        case .none:
            return ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .building(let info):
            buildingContent(info: info)
        case .road(let info):
            roadContent(info: info)
        case .none:
            EmptyView()
        }
    }

    private func buildingContent(info: BuildingSelectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = info.name, !name.isEmpty {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .padding(.bottom, 4)
            }
            InfoRow(label: "높이", value: String(format: "%.1f m", info.height))
            InfoRow(label: "너비", value: String(format: "%.1f m", info.width))
            InfoRow(label: "깊이", value: String(format: "%.1f m", info.depth))
            InfoRow(label: "위치", value: String(format: "(%.0f, %.0f)", info.position.x, info.position.z))
        }
    }

    private func roadContent(info: RoadSelectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = info.name, !name.isEmpty {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .padding(.bottom, 4)
            }
            InfoRow(label: "종류", value: info.roadType.displayName)
            InfoRow(label: "차선 수", value: "\(info.lanes)차선")
            InfoRow(label: "폭", value: String(format: "%.1f m", info.width))
        }
    }
}

/// 정보 행 뷰
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
            Spacer()
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

#Preview("Building Selection") {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        SelectionPopup(
            selection: .building(BuildingSelectionInfo(
                position: SIMD3<Float>(1000, 0, 2000),
                height: 45.5,
                width: 30.0,
                depth: 25.0,
                name: "송도 센트럴파크",
                chunkId: ChunkID(5, 4),
                indexInChunk: 10
            )),
            onDismiss: {}
        )
        .padding()
    }
}

#Preview("Road Selection") {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        SelectionPopup(
            selection: .road(RoadSelectionInfo(
                roadType: .primary,
                lanes: 4,
                width: 12.0,
                name: "인천대로",
                chunkId: ChunkID(5, 4),
                indexInChunk: 5
            )),
            onDismiss: {}
        )
        .padding()
    }
}
