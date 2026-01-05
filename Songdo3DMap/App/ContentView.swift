import SwiftUI
import simd

struct ContentView: View {
    @State private var cameraPosition: SIMD3<Float> = SIMD3(0, 500, 500)
    @State private var cameraTarget: SIMD3<Float> = SIMD3(0, 0, 0)
    @State private var showControls = true
    @StateObject private var locationManager = LocationManager()

    var body: some View {
        ZStack {
            // 3D Map View
            MapView(
                cameraPosition: $cameraPosition,
                cameraTarget: $cameraTarget,
                userLocation: locationManager.localPosition
            )
            .ignoresSafeArea()

            // UI Overlay
            if showControls {
                VStack {
                    HStack {
                        Spacer()
                        // Mini map placeholder
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.3))
                            .frame(width: 120, height: 120)
                            .overlay(
                                Text("Mini Map")
                                    .foregroundColor(.white)
                                    .font(.caption)
                            )
                            .padding()
                    }

                    Spacer()

                    // Bottom controls
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // Zoom controls
                            Button(action: { zoomIn() }) {
                                Image(systemName: "plus")
                                    .frame(width: 44, height: 44)
                                    .background(Color.white)
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }

                            Button(action: { zoomOut() }) {
                                Image(systemName: "minus")
                                    .frame(width: 44, height: 44)
                                    .background(Color.white)
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }

                            // Location button
                            Button(action: { centerOnLocation() }) {
                                Image(systemName: "location.fill")
                                    .foregroundColor(locationManager.localPosition != nil ? .blue : .gray)
                                    .frame(width: 44, height: 44)
                                    .background(Color.white)
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }

                            // Compass
                            Image(systemName: "location.north.fill")
                                .frame(width: 44, height: 44)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        }
                        .padding()
                    }
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            locationManager.requestAuthorization()
        }
    }

    private func centerOnLocation() {
        guard let position = locationManager.localPosition else { return }
        cameraTarget = SIMD3(position.x, 0, position.z)
    }

    private func zoomIn() {
        let direction = normalize(cameraTarget - cameraPosition)
        cameraPosition += direction * 50
    }

    private func zoomOut() {
        let direction = normalize(cameraTarget - cameraPosition)
        cameraPosition -= direction * 50
    }
}

#Preview {
    ContentView()
}
