import UIKit

enum AppColor {
    static let accent = UIColor(red: 0.96, green: 0.55, blue: 0.20, alpha: 1)
    static let ink = UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
    static let soft = UIColor(red: 0.96, green: 0.94, blue: 0.91, alpha: 1)
}

extension UIView {
    func pin(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }

    func pin(to guide: UILayoutGuide, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom)
        ])
    }

    func addShadow() {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.06
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }
}

extension UILabel {
    static func make(_ text: String = "", size: CGFloat = 16, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}

extension UIButton {
    static func action(_ title: String, primary: Bool = true) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = primary ? AppColor.accent : .secondarySystemBackground
        configuration.baseForegroundColor = primary ? .white : .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        return UIButton(configuration: configuration)
    }
}

extension UIViewController {
    func showError(_ error: Error, title: String = "操作失败") {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    func showMessage(_ text: String, title: String = "提示") {
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

final class LoadingFooter: UIView {
    let spinner = UIActivityIndicatorView(style: .medium)
    let label = UILabel.make("正在加载…", size: 14, color: .secondaryLabel)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        addSubview(stack)
        stack.pin(to: self, insets: UIEdgeInsets(top: 22, left: 0, bottom: 22, right: 0))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
