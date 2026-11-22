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

    // 右侧竖排控制栏
    private let rootStack = UIStackView()
    private let sideBar = UIView()
    private let sideStack = UIStackView()
    private let statusDot = UIView()

    // 连接设置浮层
    private let settingsOverlay = UIView()
    private let backdrop = UIView()
    private let settingsCard = UIStackView()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let tokenField = UITextField()
    private let deviceButton = UIButton(type: .system)
    private let qualitySeg = UISegmentedControl(items: ["流畅", "标准", "高清"])
    private let connectButton = UIButton(type: .system)

    private let exitFullscreenButton = UIButton(type: .system)

    private var selectedSerial: String?
    private var connected = false
    private var isFullscreen = false

    private let qualityValues = ["low", "mid", "high"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        client.attach(to: container.videoView.videoLayer)

        client.onStatus = { [weak self] text in
            guard let self = self else { return }
            if text.hasPrefix("已连接") || text.hasPrefix("就绪") {
                self.connected = true
                self.statusDot.backgroundColor = UIColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1)
                self.updateConnectButton()
                self.setSettings(visible: false)
            } else if text.hasPrefix("断开") || text.hasPrefix("错误") || text.hasPrefix("连接失败") {
                self.connected = false
                self.statusDot.backgroundColor = UIColor(white: 0.45, alpha: 1)
                self.updateConnectButton()
            }
        }

        client.onVideoSize = { [weak self] size in
            guard let self = self, size.width > 0, size.height > 0 else { return }
            self.container.aspect = size.width / size.height
        }

        let d = UserDefaults.standard
        hostField.text = d.string(forKey: "host") ?? ""
        portField.text = d.string(forKey: "port") ?? "8080"
        tokenField.text = d.string(forKey: "token") ?? ""
        let qi = d.integer(forKey: "qualityIndex")
        qualitySeg.selectedSegmentIndex = (0...2).contains(qi) ? qi : 1

        reloadDevices()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom] }

    // MARK: - UI

    private func buildUI() {
        rootStack.axis = .horizontal
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buildSideBar()

        rootStack.addArrangedSubview(container)
        rootStack.addArrangedSubview(sideBar)

        buildExitFullscreen()

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        container.videoView.isUserInteractionEnabled = true
        container.videoView.addGestureRecognizer(tap)
        container.videoView.addGestureRecognizer(pan)

        buildSettingsOverlay()
    }

    private func buildSideBar() {
        sideBar.backgroundColor = UIColor(white: 0.07, alpha: 1)
        sideBar.translatesAutoresizingMaskIntoConstraints = false
        sideBar.widthAnchor.constraint(equalToConstant: 56).isActive = true

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.backgroundColor = UIColor(white: 0.45, alpha: 1)
        statusDot.layer.cornerRadius = 4
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let dotHolder = UIView()
        dotHolder.translatesAutoresizingMaskIntoConstraints = false
        dotHolder.addSubview(statusDot)
        NSLayoutConstraint.activate([
            dotHolder.heightAnchor.constraint(equalToConstant: 22),
            statusDot.centerXAnchor.constraint(equalTo: dotHolder.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: dotHolder.centerYAnchor),
        ])

        sideStack.axis = .vertical
        sideStack.spacing = 6
        sideStack.alignment = .center
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sideStack.addArrangedSubview(dotHolder)
        sideStack.addArrangedSubview(makeSideButton("power", #selector(doPower)))
        sideStack.addArrangedSubview(makeSideButton("speaker.plus", #selector(doVolUp)))
        sideStack.addArrangedSubview(makeSideButton("speaker.minus", #selector(doVolDown)))
        sideStack.addArrangedSubview(separator())
        sideStack.addArrangedSubview(makeSideButton("arrowtriangle.left.fill", #selector(doBack)))
        sideStack.addArrangedSubview(makeSideButton("circle", #selector(doHome)))
        sideStack.addArrangedSubview(makeSideButton("square", #selector(doRecents)))
        sideStack.addArrangedSubview(separator())
        sideStack.addArrangedSubview(makeSideButton("arrow.up.left.and.arrow.down.right", #selector(toggleFullscreen)))
        sideStack.addArrangedSubview(makeSideButton("gearshape.fill", #selector(openSettings)))

        sideBar.addSubview(sideStack)
        NSLayoutConstraint.activate([
            sideStack.topAnchor.constraint(equalTo: sideBar.safeAreaLayoutGuide.topAnchor, constant: 12),
            sideStack.centerXAnchor.constraint(equalTo: sideBar.centerXAnchor),
            sideStack.bottomAnchor.constraint(lessThanOrEqualTo: sideBar.safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    private func makeSideButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0.18, alpha: 1)
        b.layer.cornerRadius = 10
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.3, alpha: 0.6)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 24).isActive = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func buildExitFullscreen() {
        exitFullscreenButton.setTitle("退出全屏", for: .normal)
        exitFullscreenButton.setTitleColor(.white, for: .normal)
        exitFullscreenButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        exitFullscreenButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        exitFullscreenButton.layer.cornerRadius = 15
        exitFullscreenButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        exitFullscreenButton.isHidden = true
        exitFullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        exitFullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exitFullscreenButton)
        NSLayoutConstraint.activate([
            exitFullscreenButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exitFullscreenButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            exitFullscreenButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func buildSettingsOverlay() {
        settingsOverlay.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlay.isHidden = true
        view.addSubview(settingsOverlay)
        NSLayoutConstraint.activate([
            settingsOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            settingsOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        backdrop.backgroundColor = UIColor(white: 0, alpha: 0.62)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeSettings)))
        settingsOverlay.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: settingsOverlay.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: settingsOverlay.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: settingsOverlay.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: settingsOverlay.bottomAnchor),
        ])

        settingsCard.axis = .vertical
        settingsCard.spacing = 10
        settingsCard.isLayoutMarginsRelativeArrangement = true
        settingsCard.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        settingsCard.backgroundColor = UIColor(white: 0.12, alpha: 1)
        settingsCard.layer.cornerRadius = 16
        settingsCard.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlay.addSubview(settingsCard)
        NSLayoutConstraint.activate([
            settingsCard.centerYAnchor.constraint(equalTo: settingsOverlay.centerYAnchor),
            settingsCard.leadingAnchor.constraint(equalTo: settingsOverlay.leadingAnchor, constant: 18),
            settingsCard.trailingAnchor.constraint(equalTo: settingsOverlay.trailingAnchor, constant: -18),
        ])

        let title = UILabel()
        title.text = "连接设置"
        title.textColor = .white
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        hostField.placeholder = "局域网 IP 或域名"
        hostField.textColor = .white
        hostField.backgroundColor = UIColor(white: 0.2, alpha: 1)
        hostField.borderStyle = .roundedRect
        hostField.keyboardType = .URL
        hostField.autocorrectionType = .no
        hostField.autocapitalizationType = .none
        hostField.returnKeyType = .go
        hostField.font = .systemFont(ofSize: 15)
        hostField.clearButtonMode = .whileEditing

        portField.placeholder = "端口"
        portField.textColor = .white
        portField.backgroundColor = UIColor(white: 0.2, alpha: 1)
        portField.borderStyle = .roundedRect
        portField.keyboardType = .numberPad
        portField.font = .systemFont(ofSize: 15)
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let addrRow = UIStackView(arrangedSubviews: [hostField, portField])
        addrRow.axis = .horizontal
        addrRow.spacing = 8

        deviceButton.setTitle("选择设备", for: .normal)
        deviceButton.setTitleColor(.white, for: .normal)
        deviceButton.titleLabel?.font = .systemFont(ofSize: 14)
        deviceButton.backgroundColor = UIColor(white: 0.2, alpha: 1)
        deviceButton.layer.cornerRadius = 8
        deviceButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        deviceButton.contentHorizontalAlignment = .leading
        deviceButton.showsMenuAsPrimaryAction = true
        deviceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tokenField.placeholder = "token（走隧道时填）"
        tokenField.textColor = .white
        tokenField.backgroundColor = UIColor(white: 0.2, alpha: 1)
        tokenField.borderStyle = .roundedRect
        tokenField.autocorrectionType = .no
        tokenField.autocapitalizationType = .none
        tokenField.font = .systemFont(ofSize: 13)
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 132).isActive = true

        let targetRow = UIStackView(arrangedSubviews: [deviceButton, tokenField])
        targetRow.axis = .horizontal
        targetRow.spacing = 8

        qualitySeg.selectedSegmentIndex = 1
        qualitySeg.selectedSegmentTintColor = UIColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1)
        qualitySeg.backgroundColor = UIColor(white: 0.2, alpha: 1)
        qualitySeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        qualitySeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        qualitySeg.addTarget(self, action: #selector(onQualityChanged), for: .valueChanged)
        qualitySeg.translatesAutoresizingMaskIntoConstraints = false
        qualitySeg.heightAnchor.constraint(equalToConstant: 34).isActive = true

        connectButton.setTitle("连接", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        connectButton.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1)
        connectButton.layer.cornerRadius = 8
        connectButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        connectButton.addTarget(self, action: #selector(toggleConnect), for: .touchUpInside)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.widthAnchor.constraint(equalToConstant: 84).isActive = true
        connectButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let actionRow = UIStackView(arrangedSubviews: [qualitySeg, connectButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .center

        let hint = UILabel()
        hint.text = "画质切换会使画面中断约 10 秒"
        hint.textColor = UIColor(white: 0.55, alpha: 1)
        hint.font = .systemFont(ofSize: 11)
        hint.numberOfLines = 0

        settingsCard.addArrangedSubview(title)
        settingsCard.addArrangedSubview(addrRow)
        settingsCard.addArrangedSubview(targetRow)
        settingsCard.addArrangedSubview(actionRow)
        settingsCard.addArrangedSubview(hint)
    }

    // MARK: - 模式

    @objc private func openSettings() {
        setSettings(visible: true)
        reloadDevices()
    }

    @objc private func closeSettings() {
        setSettings(visible: false)
    }

    private func setSettings(visible: Bool) {
        settingsOverlay.isHidden = !visible
        if visible { view.endEditing(false) }
    }

    @objc private func toggleFullscreen() {
        isFullscreen.toggle()
        sideBar.isHidden = isFullscreen
        exitFullscreenButton.isHidden = !isFullscreen
        if isFullscreen { setSettings(visible: false) }
    }

    // MARK: - 连接

    private func resolveHost() -> String? {
        let h = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "/", with: "")
        return h.isEmpty ? nil : h
    }

    private func resolvePort() -> Int {
        Int((portField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 8080
    }

    private func resolveToken() -> String {
        (tokenField.text ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func reloadDevices() {
        guard let host = resolveHost() else {
            deviceButton.setTitle("先填地址", for: .normal)
            return
        }
        let port = resolvePort()
        var comps = URLComponents(string: "http://\(host):\(port)/api/devices")
        let t = resolveToken()
        if !t.isEmpty { comps?.queryItems = [URLQueryItem(name: "token", value: t)] }
        guard let url = comps?.url else { return }

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
            return
        }
        guard let host = resolveHost() else { return }
        let port = resolvePort()
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(String(port), forKey: "port")
        UserDefaults.standard.set(resolveToken(), forKey: "token")

        guard let serial = selectedSerial else {
            reloadDevices()
            return
        }

        let q = qualityValues[qualitySeg.selectedSegmentIndex]
        client.connect(host: host, port: port, serial: serial, quality: q, token: resolveToken())
        connected = true
        updateConnectButton()
    }

    @objc private func onQualityChanged() {
        UserDefaults.standard.set(qualitySeg.selectedSegmentIndex, forKey: "qualityIndex")
        guard connected, let host = resolveHost(), let serial = selectedSerial else { return }
        let q = qualityValues[qualitySeg.selectedSegmentIndex]
        client.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.client.connect(host: host, port: self.resolvePort(), serial: serial, quality: q, token: self.resolveToken())
        }
    }

    private func updateConnectButton() {
        connectButton.setTitle(connected ? "断开" : "连接", for: .normal)
        connectButton.backgroundColor = connected
            ? UIColor(white: 0.3, alpha: 1)
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
    @objc private func doVolUp() { client.sendVolumeUp() }
    @objc private func doVolDown() { client.sendVolumeDown() }
}
