import Flutter
import UIKit
import AVFoundation

public enum SoundStreamErrors: String {
    case FailedToRecord
    case FailedToPlay
    case FailedToStop
    case FailedToWriteBuffer
    case Unknown
}

public enum SoundStreamStatus: String {
    case Unset
    case Initialized
    case Playing
    case Stopped
}

@available(iOS 9.0, *)
public class SwiftSoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var hasPermission: Bool = false
    private var debugLogging: Bool = false
    
    //========= Recorder's vars
    private var mAudioEngine: AVAudioEngine!
    private let mRecordBus = 0
    private var mInputNode: AVAudioInputNode!
    private var mRecordSampleRate: Double = 16000 // 16Khz
    private var mRecordBufferSize: AVAudioFrameCount = 8192
    private var mRecordChannel = 0
    private var mRecordSettings: [String:Int]!
    private var mRecordFormat: AVAudioFormat!
    

    /** ======== Basic Plugin initialization ======== **/
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "vn.casperpas.sound_stream:methods", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundStreamPlugin( channel, registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    init( _ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
        
        super.init()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            hasPermission(result)
        case "initializeRecorder":
            initializeRecorder(call, result)
        case "startRecording":
            startRecording(result)
        case "stopRecording":
            stopRecording(result)
        default:
            print("Unrecognized method: \(call.method)")
            sendResult(result, FlutterMethodNotImplemented)
        }
    }
    
    private func sendResult(_ result: @escaping FlutterResult, _ arguments: Any?) {
        DispatchQueue.main.async {
            result( arguments )
        }
    }
    
    private func invokeFlutter( _ method: String, _ arguments: Any? ) {
        DispatchQueue.main.async {
            self.channel.invokeMethod( method, arguments: arguments )
        }
    }
    
    /** ======== Plugin methods ======== **/
    
    private func checkAndRequestPermission(completion callback: @escaping ((Bool) -> Void)) {
        if (hasPermission) {
            callback(hasPermission)
            return
        }
        
        var permission: AVAudioSession.RecordPermission
        #if swift(>=4.2)
        permission = AVAudioSession.sharedInstance().recordPermission
        #else
        permission = AVAudioSession.sharedInstance().recordPermission()
        #endif
        switch permission {
        case .granted:
            print("granted")
            hasPermission = true
            callback(hasPermission)
            break
        case .denied:
            print("denied")
            hasPermission = false
            callback(hasPermission)
            break
        case .undetermined:
            print("undetermined")
            AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
                if allowed {
                    self.hasPermission = true
                    print("undetermined true")
                    callback(self.hasPermission)
                } else {
                    self.hasPermission = false
                    print("undetermined false")
                    callback(self.hasPermission)
                }
            }
            break
        default:
            callback(hasPermission)
            break
        }
    }
    
    private func hasPermission( _ result: @escaping FlutterResult) {
        checkAndRequestPermission { value in
            self.sendResult(result, value)
        }
    }
    
    private func startEngine() {
        guard !mAudioEngine.isRunning else {
            return
        }
        
        try? mAudioEngine.start()
    }
    
    private func stopEngine() {
        mAudioEngine.stop()
        mAudioEngine.reset()
    }
    
    private func sendEventMethod(_ name: String, _ data: Any) {
        var eventData: [String: Any] = [:]
        eventData["name"] = name
        eventData["data"] = data
        invokeFlutter("platformEvent", eventData)
    }
    
    private func initializeRecorder(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
            else {
                sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                                 message:"Incorrect parameters",
                                                 details: nil ))
                return
        }
        mRecordSampleRate = argsArr["sampleRate"] as? Double ?? mRecordSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mRecordFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mRecordSampleRate, channels: 1, interleaved: true)

        checkAndRequestPermission { isGranted in
            if isGranted {
                // Initialize audio engine
                if self.mAudioEngine == nil {
                    self.mAudioEngine = AVAudioEngine()
                    self.mInputNode = self.mAudioEngine.inputNode
                }
                
                self.sendRecorderStatus(SoundStreamStatus.Initialized)
                self.sendResult(result, true)
            } else {
                self.sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                                      message:"Incorrect parameters",
                                                      details: nil ))
            }
        }
    }
    
    private func resetEngineForRecord() {
        let input = mAudioEngine.inputNode
        
        // Remove existing tap if present
        input.removeTap(onBus: mRecordBus)
        
        // Stop engine before installing tap (iOS 17 requirement)
        if mAudioEngine.isRunning {
            mAudioEngine.stop()
        }
        
        // Use inputFormat instead of outputFormat for iOS 17 compatibility
        let inputFormat = input.inputFormat(forBus: mRecordBus)
        
        // Fallback to default format if hardware format is invalid
        var recordFormat = inputFormat
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 44100,
                                        channels: 1,
                                        interleaved: false)!
        }
        
        let converter = AVAudioConverter(from: recordFormat, to: mRecordFormat!)!
        let ratio: Float = Float(recordFormat.sampleRate)/Float(mRecordFormat.sampleRate)
        
        input.installTap(onBus: mRecordBus, bufferSize: mRecordBufferSize, format: recordFormat) { (buffer, time) -> Void in
            let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.mRecordFormat!, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!
            
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
            
            if status == .error {
                return
            }
            
            if (self.mRecordFormat?.commonFormat == AVAudioCommonFormat.pcmFormatInt16) {
                let values = self.audioBufferToBytes(convertedBuffer)
                self.sendMicData(values)
            }
        }
        
    }
    
    private func startRecording(_ result: @escaping FlutterResult) {
        do {
            // Configure audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            
            // Install tap before starting engine
            resetEngineForRecord()
            
            // Start engine after tap is installed
            try mAudioEngine.start()
            
            sendRecorderStatus(SoundStreamStatus.Playing)
            result(true)
        } catch {
            result(FlutterError(code: SoundStreamErrors.FailedToRecord.rawValue,
                              message: "Failed to start recording",
                              details: error.localizedDescription))
        }
    }
    
    private func stopRecording(_ result: @escaping FlutterResult) {
        if mAudioEngine.inputNode.numberOfInputs > 0 {
            mAudioEngine.inputNode.removeTap(onBus: mRecordBus)
        }
        stopEngine()
        sendRecorderStatus(SoundStreamStatus.Stopped)
        result(true)
    }
    
    private func sendMicData(_ data: [UInt8]) {
        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: data, length: data.count) as Data)
        sendEventMethod("dataPeriod", channelData)
    }
    
    private func sendRecorderStatus(_ status: SoundStreamStatus) {
        sendEventMethod("recorderStatus", status.rawValue)
    }
    
    private func audioBufferToBytes(_ audioBuffer: AVAudioPCMBuffer) -> [UInt8] {
        let srcLeft = audioBuffer.int16ChannelData![0]
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        let numBytes = Int(bytesPerFrame * audioBuffer.frameLength)
        
        // initialize bytes by 0
        var audioByteArray = [UInt8](repeating: 0, count: numBytes)
        
        srcLeft.withMemoryRebound(to: UInt8.self, capacity: numBytes) { srcByteData in
            audioByteArray.withUnsafeMutableBufferPointer {
                $0.baseAddress!.initialize(from: srcByteData, count: numBytes)
            }
        }
        
        return audioByteArray
    }
}
