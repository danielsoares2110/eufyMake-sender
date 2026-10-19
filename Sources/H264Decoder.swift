import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import AppKit

// Swift port of AnkerH264Decoder.mm: feed chunks of Annex-B H.264; decode via
// VideoToolbox (BGRA) ; only rebuild the decompression session when SPS/PPS change
// (the M5 resends SPS/PPS every GOP); deliver CGImages for display.

final class H264Decoder {
    var onFrame: ((CGImage) -> Void)?

    private var buf = Data()
    private var sps = Data()
    private var pps = Data()

    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let frameQueue = DispatchQueue(label: "m5.h264.render", qos: .userInteractive)

    func teardown() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func createSession() {
        teardown()
        guard !sps.isEmpty, !pps.isEmpty else { return }
        var status: CMVideoFormatDescription?
        var sizes: [Int] = []
        var pointers: [UnsafePointer<UInt8>] = []
        do {
            let spsMem = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
            sps.withUnsafeBytes { memcpy(spsMem, $0.baseAddress!, sps.count) }
            let ppsMem = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
            pps.withUnsafeBytes { memcpy(ppsMem, $0.baseAddress!, pps.count) }
            defer { spsMem.deallocate(); ppsMem.deallocate() }
            sizes = [sps.count, pps.count]
            pointers = [UnsafePointer(spsMem), UnsafePointer(ppsMem)]
            let st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &status)
            _ = st
        }
        guard let fmt = status else {
            AppLog.video("format desc failed")
            return
        }
        format = fmt

        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        // C-callback form (labels per this SDK's import: imageBufferAttributes / outputCallback).
        final class Sink { var handler: VTDecompressionOutputHandler = { _, _, _, _, _ in } }
        let sink = Sink()
        sink.handler = { [weak self] status, flags, imageBuffer, pts, dur in
            guard let self, status == noErr, let imageBuffer else { return }
            self.emit(imageBuffer)
            _ = flags; _ = pts; _ = dur
        }
        var outputCb: VTDecompressionOutputCallback = { refcon, _, status, flags, imageBuffer, pts, dur in
            let sink = Unmanaged<Sink>.fromOpaque(refcon!).takeUnretainedValue()
            sink.handler(status, flags, imageBuffer, pts, dur)
        }
        var reg = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCb,
            decompressionOutputRefCon: Unmanaged.passRetained(sink).toOpaque())
        var newSession: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                              formatDescription: fmt,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: &reg,
                                              decompressionSessionOut: &newSession)
        session = newSession
        if st == noErr, session != nil {
            AppLog.video("decode session ready")
        } else {
            AppLog.video("session create failed: \(st)")
            session = nil
        }
    }

    private func emit(_ imageBuffer: CVImageBuffer) {
        frameQueue.async {
            let ci = CIImage(cvPixelBuffer: imageBuffer)
            let rect = ci.extent
            guard let cg = self.ciContext.createCGImage(ci, from: rect) else { return }
            self.onFrame?(cg)
        }
    }

    private func decodeNal(_ nal: Data) {
        guard let session, !nal.isEmpty else { return }
        var avcc = Data()
        avcc.append(UInt8((nal.count >> 24) & 0xff))
        avcc.append(UInt8((nal.count >> 16) & 0xff))
        avcc.append(UInt8((nal.count >> 8) & 0xff))
        avcc.append(UInt8(nal.count & 0xff))
        avcc.append(nal)

        var block: CMBlockBuffer?
        let st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                    blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil, offsetToData: 0,
                                                    dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else { return }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        var size = avcc.count
        let st2 = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                            formatDescription: format, sampleCount: 1,
                                            sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                            sampleBufferOut: &sample)
        if st2 == noErr, let sample {
            var infoOut = VTDecodeInfoFlags()
            // bit 0 = kVTDecodeFrame_EnableAsynchronousDecompression (async decode)
            let handler: VTDecompressionOutputHandler = { [weak self] (status: OSStatus, _: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, _: CMTime, dur: CMTime) -> Void in
                guard let self, status == noErr, let imageBuffer else { return }
                self.emit(imageBuffer)
                _ = dur
            }
            _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                  flags: VTDecodeFrameFlags(rawValue: 1 << 0),
                                                  infoFlagsOut: &infoOut,
                                                  outputHandler: handler)
        }
    }

    private func handleNal(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let type = nal[nal.startIndex] & 0x1f
        switch type {
        case 7:
            if nal != sps { sps = nal; if !pps.isEmpty { createSession() } }
        case 8:
            if nal != pps { pps = nal; if !sps.isEmpty { createSession() } }
        default:
            decodeNal(nal)
        }
    }

    func feed(_ data: Data) {
        buf.append(data)
        guard buf.count >= 4 else { return }
        var starts: [Int] = []
        var i = 0
        while i + 2 < buf.count {
            if buf[buf.startIndex + i] == 0 && buf[buf.startIndex + i + 1] == 0 && buf[buf.startIndex + i + 2] == 1 {
                starts.append(i)
            }
            i += 1
        }
        guard starts.count >= 2 else {
            if let first = starts.first, first > 0 { buf.removeFirst(first) }
            return
        }

        for k in 0..<(starts.count - 1) {
            var nalStart = buf.startIndex + starts[k] + 3
            var nalEnd = buf.startIndex + starts[k + 1]
            if buf[nalEnd - 1] == 0 { nalEnd -= 1 }
            if nalStart < nalEnd {
                handleNal(buf.subdata(in: nalStart..<nalEnd))
            }
        }
        buf.removeFirst(starts.last!)
    }
}
