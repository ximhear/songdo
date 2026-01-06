import SwiftUI
import MetalKit

/// SwiftUI wrapper for Metal 3D map view
struct MapView: UIViewRepresentable {

    @Binding var cameraPosition: SIMD3<Float>
    @Binding var cameraTarget: SIMD3<Float>
    var userLocation: SIMD3<Float>?
    @Binding var selectionResult: SelectionResult

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()

        // Use the same device as the renderer
        let device = context.coordinator.renderer.device
        mtkView.device = device

        // Configure view
        mtkView.preferredFramesPerSecond = 60
        mtkView.colorPixelFormat = .bgra8Unorm_srgb
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.529, green: 0.808, blue: 0.922, alpha: 1.0)

        // Ensure drawable is available
        mtkView.autoResizeDrawable = true
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.framebufferOnly = true

        // Set initial frame to avoid zero size issues
        mtkView.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        // Set delegate after configuration
        mtkView.delegate = context.coordinator.renderer

        // Setup gesture recognizers
        context.coordinator.setupGestures(for: mtkView)

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer.updateCamera(
            position: cameraPosition,
            target: cameraTarget
        )
        context.coordinator.renderer.updateLocationMarker(position: userLocation)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        var parent: MapView
        var renderer: MetalRenderer!

        // Gesture state
        private var lastPanLocation: CGPoint = .zero
        private var lastRotationAngle: CGFloat = 0
        private var isPanning = false

        init(_ parent: MapView) {
            self.parent = parent
            super.init()

            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal not supported")
            }
            self.renderer = MetalRenderer(device: device)
        }

        func setupGestures(for view: MTKView) {
            // Pan gesture (1 finger = rotate, 2 fingers = pan)
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            panGesture.minimumNumberOfTouches = 1
            panGesture.maximumNumberOfTouches = 2
            view.addGestureRecognizer(panGesture)

            // Pinch gesture (zoom)
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            view.addGestureRecognizer(pinchGesture)

            // Rotation gesture
            let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
            view.addGestureRecognizer(rotationGesture)

            // Single tap for selection
            let singleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
            singleTapGesture.numberOfTapsRequired = 1
            view.addGestureRecognizer(singleTapGesture)

            // Double tap to reset
            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTapGesture.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTapGesture)

            // Single tap should wait for double tap to fail
            singleTapGesture.require(toFail: doubleTapGesture)

            // Allow simultaneous gestures
            panGesture.delegate = self
            pinchGesture.delegate = self
            rotationGesture.delegate = self
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let numberOfTouches = gesture.numberOfTouches

            switch gesture.state {
            case .began:
                lastPanLocation = translation
                isPanning = true

            case .changed:
                let dx = Float(translation.x - lastPanLocation.x)
                let dy = Float(translation.y - lastPanLocation.y)

                if numberOfTouches == 2 {
                    // Two finger pan = move target
                    renderer.pan(dx: dx, dy: dy)
                } else {
                    // One finger = rotate camera
                    renderer.rotate(dx: dx, dy: dy)
                }

                lastPanLocation = translation

            case .ended, .cancelled:
                isPanning = false

            default:
                break
            }

            updateBindings()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .changed:
                renderer.zoom(scale: Float(gesture.scale))
                gesture.scale = 1.0

            default:
                break
            }

            updateBindings()
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            switch gesture.state {
            case .changed:
                let delta = Float(gesture.rotation - lastRotationAngle)
                renderer.camera.yaw += delta * 30  // degrees
                lastRotationAngle = gesture.rotation

            case .ended, .cancelled:
                lastRotationAngle = 0

            default:
                break
            }

            updateBindings()
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MTKView else { return }

            let tapLocation = gesture.location(in: view)
            let viewportSize = renderer.currentViewportSize

            // 뷰포트 크기가 유효하지 않으면 무시
            guard viewportSize.width > 0 && viewportSize.height > 0 else { return }

            // Ray 생성
            // viewMatrix에 flipZ가 포함되어 있으므로, 역행렬 적용 시 자동으로 원본 좌표계로 변환됨
            let ray = RayCaster.createRay(
                screenPoint: tapLocation,
                viewportSize: viewportSize,
                viewMatrix: renderer.viewMatrix,
                projectionMatrix: renderer.projectionMatrix
            )

            print("Tap at: \(tapLocation), Ray origin: \(ray.origin), direction: \(ray.direction)")

            // Hit Test 수행
            let chunks = renderer.getLoadedChunks()
            print("Testing against \(chunks.count) chunks")

            if let hitResult = HitTester.performHitTest(ray: ray, chunks: chunks) {
                parent.selectionResult = hitResult.toSelectionResult()
                print("Hit: \(hitResult.objectType) at distance \(hitResult.distance)")
            } else {
                // 빈 공간 탭 - 선택 해제
                parent.selectionResult = .none
                print("No hit")
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Reset camera to default position
            renderer.camera.target = SIMD3(5000, 0, -4250)  // Center of data (Z 반전)
            renderer.camera.distance = 3000
            renderer.camera.pitch = -45
            renderer.camera.yaw = 0

            updateBindings()
        }

        private func updateBindings() {
            parent.cameraPosition = renderer.camera.position
            parent.cameraTarget = renderer.camera.target
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

@MainActor
extension MapView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch and rotation to work together
        return true
    }
}

// MARK: - Preview

#Preview {
    MapView(
        cameraPosition: .constant(SIMD3(0, 500, 500)),
        cameraTarget: .constant(SIMD3(0, 0, 0)),
        userLocation: nil,
        selectionResult: .constant(.none)
    )
}
