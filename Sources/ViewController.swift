import UIKit
import AVFoundation

final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

final class VideoContainer: UIView {
    let videoView = VideoView()
    var aspect: CGFloat = 1080.0 / 2400.0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(videoView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        var w = b.width
        var h = w / aspect
        if h > b.height {
            h = b.height
            w = h * aspect
        }
        videoView.frame = CGRect(
            x: (b.width - w) / 2,
            y: (b.height - h) / 2,
            width: w,
            height: h
        )
    }
}

final class ViewController: UIViewController {

    private let client = StreamClient()
    private let container = VideoContainer()

    private let hostField = UITextField()
    private let portField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let deviceButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let settingsBar = UIStackView()

    private var selectedSerial: String?
    private var connected = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        client.attach(to: container.videoView.videoLayer)

        client.onStatus = { [weak self] text in
            self?.statusLabel.text = text
            if text.hasPrefix("已连接") || text.hasPrefix("就绪") {
                self?.connected = true
                self?.updateConnectButton()
            }
        }

        client.onVideoSize = { [weak self] size in
            guard let self = self, size.width > 0, size.height > 0 else { return }
            self.container.aspect = size.width / size.height
        }

        let saved = UserDefaults.standard.string(forKey: "host") ?? ""
        hostField.text = saved
        portField.text = UserDefaults.standard.string(forKey: "port") ?? "8080"
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - UI

    private func buildUI() {
        settingsBar.axis = .vertical
        settingsBar.spacing = 8
        settingsBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsBar)

        let row1 = UIStackView(arrangedSubviews: [hostField, portField])
        row1.axis = .horizontal
        row1.spacing = 8

        hostField.placeholder = "电脑局域网 IP，如 10.0.0.123"
        hostField.textColor = .white
        hostField.backgroundColor = UIColor(white: 0.14, alpha: 1)
        hostField.borderStyle = .roundedRect
        hostField.keyboardType = .numbersAndPunctuation
        hostField.autocorrectionType = .no
        hostField.autocapitalizationType = .none
        hostField.returnKeyType = .done
        hostField.font = .systemFont(ofSize: 15)

        portField.placeholder = "端口"
        portField.textColor = .white
        portField.backgroundColor = UIColor(white: 0.14, alpha: 1)
        portField.borderStyle = .roundedRect
        portField.keyboardType = .numberPad
        portField.font = .systemFont(ofSize: 15)
        portField.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let row2 = UIStackView(arrangedSubviews: [deviceButton, connectButton])
        row2.axis = .horizontal
        row2.spacing = 8

        deviceButton.setTitle("选择设备", for: .normal)
        deviceButton.titleLabel?.font = .systemFont(ofSize: 15)
        deviceButton.backgroundColor = UIColor(white: 0.14, alpha: 1)
        deviceButton.tintColor = .white
        deviceButton.layer.cornerRadius = 8
        deviceButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        deviceButton.showsMenuAsPrimaryAction = true

        connectButton.setTitle("连接", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        connectButton.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1)
        connectButton.tintColor = .white
        connectButton.layer.cornerRadius = 8
        connectButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        connectButton.addTarget(self, action: #selector(toggleConnect), for: .touchUpInside)

        statusLabel.text = "未连接"
        statusLabel.textColor = UIColor(white: 0.6, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 12)

        settingsBar.addArrangedSubview(row1)
        settingsBar.addArrangedSubview(row2)
        settingsBar.addArrangedSubview(statusLabel)

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let bottom = makeBottomBar()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottom)

        NSLayoutConstraint.activate([
            settingsBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            settingsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            container.topAnchor.constraint(equalTo: settingsBar.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bottom.heightAnchor.constraint(equalToConstant: 52),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        container.videoView.isUserInteractionEnabled = true
        container.videoView.addGestureRecognizer(tap)
        container.videoView.addGestureRecognizer(pan)

        reloadDevices()
    }

    private func makeBottomBar() -> UIStackView {
        let items: [(String, Selector)] = [
            ("返回", #selector(doBack)),
            ("主页", #selector(doHome)),
            ("多任务", #selector(doRecents)),
            ("锁屏", #selector(doPower)),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        for (title, sel) in items {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14)
            b.backgroundColor = UIColor(white: 0.14, alpha: 1)
            b.layer.cornerRadius = 10
            b.addTarget(self, action: sel, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        return stack
    }

    // MARK: - 连接

    private func resolveHost() -> String? {
        let h = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        return h.isEmpty ? nil : h
    }

    private func resolvePort() -> Int {
        Int((portField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 8080
    }

    private func reloadDevices() {
        guard let host = resolveHost() else {
            deviceButton.setTitle("先填 IP", for: .normal)
            return
        }
        let port = resolvePort()
        guard let url = URL(string: "http://\(host):\(port)/api/devices") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            var items: [(String, String)] = []
            if let data = data,
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for d in arr {
                    guard let serial = d["serial"] as? String,
                          (d["state"] as? String) == "device" else { continue }
                    let model = (d["model"] as? String) ?? "设备"
                    items.append((serial, model))
                }
            }
            DispatchQueue.main.async {
                guard !items.isEmpty else {
                    self.deviceButton.setTitle("没找到设备", for: .normal)
                    return
                }
                if self.selectedSerial == nil { self.selectedSerial = items[0].0 }
                self.deviceButton.setTitle("\(items[0].1) ·\(items[0].0.suffix(4))", for: .normal)

                let menus = items.map { (serial, model) -> UIAction in
                    UIAction(title: "\(model) · \(serial.suffix(4))") { _ in
                        self.selectedSerial = serial
                        self.deviceButton.setTitle("\(model) ·\(serial.suffix(4))", for: .normal)
                    }
                }
                self.deviceButton.menu = UIMenu(title: "选择设备", children: menus)
            }
        }.resume()
    }

    @objc private func toggleConnect() {
        if connected {
            client.disconnect()
            connected = false
            updateConnectButton()
            statusLabel.text = "已断开"
            return
        }
        guard let host = resolveHost() else {
            statusLabel.text = "请先填电脑的局域网 IP"
            return
        }
        let port = resolvePort()
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(String(port), forKey: "port")

        guard let serial = selectedSerial else {
            reloadDevices()
            statusLabel.text = "正在读取设备，稍后重试"
            return
        }

        client.connect(host: host, port: port, serial: serial)
        connected = true
        updateConnectButton()
    }

    private func updateConnectButton() {
        connectButton.setTitle(connected ? "断开" : "连接", for: .normal)
        connectButton.backgroundColor = connected
            ? UIColor(white: 0.25, alpha: 1)
            : UIColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1)
    }

    // MARK: - 手势

    private func pointInVideo(_ gesture: UIGestureRecognizer) -> CGPoint {
        gesture.location(in: container.videoView)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = pointInVideo(g)
        let size = container.videoView.bounds.size
        client.sendTouch(phase: 0, point: p, in: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.client.sendTouch(phase: 1, point: p, in: size)
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = pointInVideo(g)
        let size = container.videoView.bounds.size
        switch g.state {
        case .began:
            client.sendTouch(phase: 0, point: p, in: size)
        case .changed:
            client.sendTouch(phase: 2, point: p, in: size)
        case .ended, .cancelled, .failed:
            client.sendTouch(phase: 1, point: p, in: size)
        default:
            break
        }
    }

    // MARK: - 按键

    @objc private func doBack() { client.sendBack() }
    @objc private func doHome() { client.sendHome() }
    @objc private func doRecents() { client.sendRecents() }
    @objc private func doPower() { client.sendPower() }
}
