import SwiftUI
import RealityKit
import AppKit

/// ARView keeps the native RealityKit viewport available on macOS 14.
struct DemoViewport: NSViewRepresentable {
    let rotation: Double
    let scale: Double
    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.windowBackgroundColor)
        let anchor = AnchorEntity(world: .zero)
        let block = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.08, 0.06, 0.04), cornerRadius: 0.0025),
                                materials: [SimpleMaterial(color: .systemGray, roughness: 0.5, isMetallic: false)])
        block.name = "demoBlock"
        anchor.addChild(block)
        let camera = PerspectiveCamera()
        camera.position = [0, 0, 0.23]
        anchor.addChild(camera)
        let light = DirectionalLight()
        light.light.intensity = 2000
        light.look(at: .zero, from: [2, 3, 4], relativeTo: nil)
        anchor.addChild(light)
        view.scene.addAnchor(anchor)
        return view
    }
    func updateNSView(_ view: ARView, context: Context) {
        view.environment.background = .color(.windowBackgroundColor)
        guard let block = view.scene.findEntity(named: "demoBlock") else { return }
        block.transform.rotation = simd_quatf(angle: Float(rotation * .pi / 180), axis: [0, 1, 0])
            * simd_quatf(angle: 0.3, axis: [1, 0, 0])
        block.scale = SIMD3<Float>(repeating: Float(scale))
    }
}
