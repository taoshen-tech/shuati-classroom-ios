import UIKit

final class LoginViewController: UIViewController, UITextFieldDelegate {
    private let serverField = UITextField()
    private let rootField = UITextField()
    private let transcodeField = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let submitButton = UIButton.action("连接并进入课堂")
    private let loading = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "连接你的课程库"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        buildUI()
        fillSavedConfiguration()
    }

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.pin(to: view.safeAreaLayoutGuide)

        let hero = UILabel.make("把每一节课，\n变成看得见的进步。", size: 30, weight: .bold, color: AppColor.ink)
        let subtitle = UILabel.make("连接家庭 NAS 上的 Alist，课程与播放记录由你自己掌握。", size: 15, color: .secondaryLabel)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        card.addSubview(stack)
        stack.pin(to: card, insets: UIEdgeInsets(top: 20, left: 18, bottom: 20, right: 18))

        configure(serverField, title: "Alist 地址", placeholder: "例如 http://192.168.1.10:5244", stack: stack)
        configure(rootField, title: "课程根目录", placeholder: "例如 /课程/刷题课堂", stack: stack)
        configure(usernameField, title: "用户名", placeholder: "Alist 用户名", stack: stack)
        configure(passwordField, title: "密码", placeholder: "仅保存在本机钥匙串", stack: stack)
        passwordField.isSecureTextEntry = true
        configure(transcodeField, title: "FLV 转封装地址（选填）", placeholder: "服务地址，或包含 {url} 的地址模板", stack: stack)
        let note = UILabel.make("支持 MP4、MOV、M4V、M3U8 直接播放；FLV 使用转封装服务。地址与账号不会写死在应用中。", size: 12, color: .secondaryLabel)
        stack.addArrangedSubview(note)

        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        loading.hidesWhenStopped = true
        submitButton.addSubview(loading)
        loading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo: submitButton.centerXAnchor), loading.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor)])

        let content = UIStackView(arrangedSubviews: [hero, subtitle, card, submitButton])
        content.axis = .vertical
        content.spacing = 20
        content.setCustomSpacing(32, after: subtitle)
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            submitButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func configure(_ field: UITextField, title: String, placeholder: String, stack: UIStackView) {
        field.borderStyle = .none
        field.backgroundColor = .tertiarySystemBackground
        field.layer.cornerRadius = 10
        field.font = .systemFont(ofSize: 16)
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.delegate = self
        field.clearButtonMode = .whileEditing
        field.setLeftPadding(12)
        field.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let titleLabel = UILabel.make(title, size: 13, weight: .semibold, color: .secondaryLabel)
        let group = UIStackView(arrangedSubviews: [titleLabel, field])
        group.axis = .vertical
        group.spacing = 7
        stack.addArrangedSubview(group)
    }

    private func fillSavedConfiguration() {
        let value = AppEnvironment.shared.configuration
        serverField.text = value.serverURL
        rootField.text = value.courseRoot
        transcodeField.text = value.transcodeURL
        usernameField.text = value.username
    }

    @objc private func submit() {
        view.endEditing(true)
        let configuration = ServerConfiguration(
            serverURL: serverField.text ?? "",
            courseRoot: rootField.text ?? "",
            transcodeURL: transcodeField.text ?? "",
            username: (usernameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let password = passwordField.text ?? ""
        guard configuration.isValid, !configuration.username.isEmpty, !password.isEmpty else {
            showMessage("请填写有效的 Alist 地址、课程目录、用户名和密码。")
            return
        }
        submitButton.isEnabled = false
        submitButton.configuration?.title = ""
        loading.startAnimating()
        Task { @MainActor in
            do {
                let token = try await AlistAPIClient.login(configuration: configuration, password: password)
                AppEnvironment.shared.completeLogin(configuration: configuration, password: password, token: token)
                (UIApplication.shared.delegate as? AppDelegate)?.showMain()
            } catch {
                showError(error, title: "连接失败")
            }
            loading.stopAnimating()
            submitButton.isEnabled = true
            submitButton.configuration?.title = "连接并进入课堂"
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

private extension UITextField {
    func setLeftPadding(_ width: CGFloat) {
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
        leftView = padding
        leftViewMode = .always
        rightView = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
        rightViewMode = .always
    }
}
