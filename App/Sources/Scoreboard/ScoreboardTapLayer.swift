import SwiftUI
import UIKit

/// スコアボード全体のタップを受ける層。一本指はその位置を、二本指は「戻す」を知らせる。
/// SwiftUI だけでは二本指のタップを取れないので UIKit の認識器を使う。
struct ScoreboardTapLayer: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onTwoFingerTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let one = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let two = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerTapped))
        two.numberOfTouchesRequired = 2
        // 二本指の片方が先に離れても、一本指の得点にしない
        one.require(toFail: two)
        view.addGestureRecognizer(one)
        view.addGestureRecognizer(two)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onTwoFingerTap = onTwoFingerTap
    }

    final class Coordinator: NSObject {
        var onTap: (CGPoint) -> Void = { _ in }
        var onTwoFingerTap: () -> Void = {}

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap(recognizer.location(in: recognizer.view))
        }

        @objc func twoFingerTapped() {
            onTwoFingerTap()
        }
    }
}
