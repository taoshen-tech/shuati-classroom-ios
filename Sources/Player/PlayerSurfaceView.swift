import UIKit
import AVFoundation

final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var externalView: UIView?

    var showsExternalPlayer = false {
        didSet {
            playerLayer.isHidden = showsExternalPlayer
            externalView?.isHidden = !showsExternalPlayer
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attachExternalView(_ view: UIView) {
        guard externalView !== view else { return }
        externalView?.removeFromSuperview()
        externalView = view
        addSubview(view)
        view.pin(to: self)
        view.isHidden = !showsExternalPlayer
    }
}
