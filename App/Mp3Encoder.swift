import AVFoundation
import Foundation
import Shine

enum Mp3Error: LocalizedError {
    case unsupported, unreadable, encoder

    var errorDescription: String? {
        switch self {
        case .unsupported: return L("mp3.unsupported")
        case .unreadable: return L("mp3.unreadable")
        case .encoder: return L("mp3.encoder")
        }
    }
}

/// Conversion en MP3 par l'encodeur libre shine, entièrement sur l'appareil.
enum Mp3Encoder {
    static let sampleRate = 44_100
    static let bitrate: Int32 = 96

    /// Encode des échantillons 16 bits mono à 44,1 kHz.
    static func encode(_ samples: [Int16]) throws -> Data {
        var out = Data()
        try encode(chunks: { handler in handler(samples) }, into: { out.append($0) })
        return out
    }

    /// Encode un flux d'échantillons fourni par morceaux ; chaque morceau encodé est passé à `write`.
    static func encode(chunks: (([Int16]) -> Void) throws -> Void, into write: (Data) -> Void) throws {
        var config = shine_config_t()
        config.wave.channels = PCM_MONO
        config.wave.samplerate = Int32(sampleRate)
        shine_set_config_mpeg_defaults(&config.mpeg)
        config.mpeg.mode = MONO
        config.mpeg.bitr = bitrate
        guard shine_check_config(Int32(sampleRate), bitrate) >= 0, let encoder = shine_initialise(&config) else { throw Mp3Error.encoder }
        defer { shine_close(encoder) }
        let perPass = Int(shine_samples_per_pass(encoder))
        var pending: [Int16] = []
        var written: Int32 = 0

        func flushFrames(final: Bool) {
            if final, !pending.isEmpty, pending.count < perPass {
                pending.append(contentsOf: [Int16](repeating: 0, count: perPass - pending.count))
            }
            var start = 0
            while pending.count - start >= perPass {
                var frame = Array(pending[start..<(start + perPass)])
                frame.withUnsafeMutableBufferPointer { buf in
                    if let bytes = shine_encode_buffer_interleaved(encoder, buf.baseAddress, &written), written > 0 {
                        write(Data(bytes: bytes, count: Int(written)))
                    }
                }
                start += perPass
            }
            pending.removeFirst(start)
        }

        try chunks { samples in
            pending.append(contentsOf: samples)
            flushFrames(final: false)
        }
        flushFrames(final: true)
        if let bytes = shine_flush(encoder, &written), written > 0 {
            write(Data(bytes: bytes, count: Int(written)))
        }
    }

    /// Convertit un fichier audio (M4A) en MP3, écrit dans `output`.
    static func convert(_ input: URL, to output: URL, progress: ((Double) -> Void)? = nil) throws {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Mp3Error.unreadable }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(trackOutput) else { throw Mp3Error.unsupported }
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? Mp3Error.unreadable }
        let total = max(0.001, CMTimeGetSeconds(asset.duration))
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var done = 0.0
        try encode(chunks: { handler in
            while let buffer = trackOutput.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Int16](repeating: 0, count: length / 2)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                handler(samples)
                done += Double(samples.count) / Double(sampleRate)
                progress?(min(1, done / total))
            }
            if reader.status == .failed { throw reader.error ?? Mp3Error.unreadable }
        }, into: { handle.write($0) })
    }
}
