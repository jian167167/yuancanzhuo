import Foundation
import UIKit
import AVFoundation
import VideoToolbox

/// 与电脑端 relay 通信：接收 H.264（Annex B），用 VideoToolbox 硬件解码，
/// 渲染到 AVSampleBufferDisplayLayer；并把触摸/按键回传。
final class StreamClient {

    private(set) var displayLayer = AVSampleBufferDisplayLayer()

    /// 绑定外部提供的显示层（由 VideoView 持有）
    func attach(to layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private(set) var videoSize = CGSize(width: 576, height: 1280)
    private(set) var deviceSize = CGSize(width: 1080, height: 2400)

    var onStatus: ((String) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    private var demux = AnnexBDemuxer()

    init() {}

    // MARK: - 连接

    func connect(host: String, port: Int, serial: String) {
        disconnect()

        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = port
        comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "serial", value: serial)]
        guard let url = comps.url else { return }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()

        report("连接 \(host):\(port) …")
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        formatDesc = nil
        demux.reset()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleBinary(data)
                case .string(let text):
                    self.handleText(text)
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                self.report("断开连接：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 文本消息

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "meta":
            if let w = obj["videoW"] as? Int, let h = obj["videoH"] as? Int {
                videoSize = CGSize(width: w, height: h)
            }
            if let w = obj["deviceW"] as? Int, let h = obj["deviceH"] as? Int {
                deviceSize = CGSize(width: w, height: h)
                DispatchQueue.main.async { self.onVideoSize?(self.videoSize) }
            }
            report("已连接 \(Int(videoSize.width))×\(Int(videoSize.height))")
            DispatchQueue.main.async { self.onStatus?("已连接") }
        case "status":
            if let msg = obj["msg"] as? String {
                report(msg == "ready" ? "就绪" : msg)
            }
        case "error":
            if let msg = obj["msg"] as? String {
                DispatchQueue.main.async { self.onStatus?("错误：\(msg)") }
            }
        default:
            break
        }
    }

    private func report(_ s: String) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: - 二进制消息

    private func handleBinary(_ data: Data) {
        guard data.count > 1 else { return }
        let flag = data[data.startIndex]
        let payload = Data(data[(data.startIndex + 1)...])

        switch flag {
        case 2:
            prepareFormat(with: payload)
        case 1:
            feed(payload, isKey: true)
        case 0:
            feed(payload, isKey: false)
        default:
            break
        }
    }

    /// 从 SPS/PPS 建立解码格式描述
    private func prepareFormat(with data: Data) {
        let params = H264ParameterSets.extract(from: data)
        guard let s = params.sps, let p = params.pps else { return }
        sps = s
        pps = p

        var desc: CMVideoFormatDescription?
        let status = s.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> OSStatus in
            p.withUnsafeBytes { (pp: UnsafeRawBufferPointer) -> OSStatus in
                guard let sPtr = sp.bindMemory(to: UInt8.self).baseAddress,
                      let pPtr = pp.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                var pointers: [UnsafePointer<UInt8>] = [sPtr, pPtr]
                var sizes: [Int] = [s.count, p.count]
                return pointers.withUnsafeBufferPointer { ptrBuf -> OSStatus in
                    sizes.withUnsafeBufferPointer { sizeBuf -> OSStatus in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        }

        if status == noErr, let d = desc {
            formatDesc = d
            let dims = CMVideoFormatDescriptionGetDimensions(d)
            videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            DispatchQueue.main.async {
                self.displayLayer.flush()
                self.onStatus?("已连接 \(Int(dims.width))×\(Int(dims.height))")
                self.onVideoSize?(self.videoSize)
            }
        }
    }

    /// Annex B → AVCC（长度前缀），封装 CMSampleBuffer 送显
    private func feed(_ data: Data, isKey: Bool) {
        guard let fmt = formatDesc else { return }
        let avcc = AnnexBConverter.toAVCC(data)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let length = avcc.count
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard st == kCMBlockBufferNoErr, let bb = blockBuffer else { return }

        var replaceStatus: OSStatus = -1
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            replaceStatus = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length

        let cs = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard cs == noErr, let sb = sampleBuffer else { return }

        if !isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           let first = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = Unmanaged<CFMutableDictionary>.fromOpaque(first).takeUnretainedValue()
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        DispatchQueue.main.async {
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sb)
        }
    }

    // MARK: - 控制

    private func send(_ obj: [String: Any]) {
        guard let t = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    func sendTouch(phase: Int, point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let nx = max(0, min(1, point.x / size.width))
        let ny = max(0, min(1, point.y / size.height))
        send([
            "t": "touch",
            "a": phase,
            "x": Int(nx * deviceSize.width),
            "y": Int(ny * deviceSize.height),
            "p": 1,
        ])
    }

    func sendKey(_ keycode: Int) {
        send(["t": "key", "a": 0, "k": keycode])
        send(["t": "key", "a": 1, "k": keycode])
    }

    func sendHome() { sendKey(3) }
    func sendBack() { sendKey(4) }
    func sendRecents() { sendKey(187) }
    func sendPower() { sendKey(26) }
}

// MARK: - Annex B 工具

struct AnnexBConverter {
    /// 把 Annex B 的起始码替换为 4 字节大端长度
    static func toAVCC(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var scLens: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i); scLens.append(4); i += 4
            } else if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i); scLens.append(3); i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return Data() }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count + starts.count * 4)

        for idx in 0..<starts.count {
            let start = starts[idx] + scLens[idx]
            let end = (idx + 1 < starts.count) ? starts[idx + 1] : bytes.count
            guard end > start else { continue }
            let nal = Array(bytes[start..<end])
            let len = UInt32(nal.count).bigEndian
            out.append(UInt8(len & 0xff))
            out.append(UInt8((len >> 8) & 0xff))
            out.append(UInt8((len >> 16) & 0xff))
            out.append(UInt8((len >> 24) & 0xff))
            out.append(contentsOf: nal)
        }
        return Data(out)
    }
}

struct H264ParameterSets {
    static func extract(from data: Data) -> (sps: Data?, pps: Data?) {
        let bytes = [UInt8](data)
        var sps: Data?
        var pps: Data?
        var i = 0
        while i + 4 < bytes.count {
            guard bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 else {
                i += 1
                continue
            }
            let nalType = bytes[i + 4] & 0x1f
            let bodyStart = i + 4
            var j = bodyStart
            var bodyEnd = bytes.count
            while j + 3 < bytes.count {
                if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 0, bytes[j + 3] == 1 {
                    bodyEnd = j
                    break
                }
                j += 1
            }
            let nal = Data(bytes[bodyStart..<bodyEnd])
            if nalType == 7, sps == nil { sps = nal }
            if nalType == 8, pps == nil { pps = nal }
            i = bodyEnd
        }
        return (sps, pps)
    }
}

/// 目前服务端已按帧切好，这里保留占位以便将来直连裸流
final class AnnexBDemuxer {
    func reset() {}
}
