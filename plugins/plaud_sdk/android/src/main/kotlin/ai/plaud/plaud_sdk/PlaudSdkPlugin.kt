package ai.plaud.plaud_sdk

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sdk.NiceBuildSdk
import sdk.PlaudDeviceAgent
import sdk.PlaudDeviceAgentListener
import sdk.audio.AudioExportFormat
import sdk.audio.AudioExporter
import com.tinnotech.penblesdk.entity.BleDevice
import com.tinnotech.penblesdk.entity.BleFile
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter plugin bridging Plaud's native Android SDK. Android counterpart of
 * `ios/Classes/PlaudSdkPlugin.swift` — same nine methods and twelve events, same
 * channel names, same payload keys, so Dart never branches on platform.
 *
 * All SDK interaction and listener handling lives in [PlaudSdkController];
 * listener callbacks are forwarded to Dart as maps on the event channel, tagged
 * with an `event` key.
 */
class PlaudSdkPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private companion object {
        const val PERMISSION_REQUEST_CODE = 0x9134
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var controller: PlaudSdkController

    private val main = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var pendingPermission: ((Boolean) -> Unit)? = null

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "plaud_sdk/methods")
        eventChannel = EventChannel(binding.binaryMessenger, "plaud_sdk/events")

        controller = PlaudSdkController(
            context = binding.applicationContext,
            ensurePermissions = ::ensurePermissions,
            emit = { event, body ->
                // Hop to the main thread before crossing into Dart — SDK listener
                // callbacks can arrive on arbitrary threads.
                main.post {
                    val payload = HashMap<String, Any?>(body.size + 1)
                    payload["event"] = event
                    payload.putAll(body)
                    eventSink?.success(payload)
                }
            },
        )

        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        controller.dispose()
        eventSink = null
        appContext = null
    }

    // MARK: - EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // MARK: - Method dispatch

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any?> ?: emptyMap()
        when (call.method) {
            "initSDK" -> controller.initSDK(args, result)
            "startScan" -> controller.startScan(result)
            "stopScan" -> controller.stopScan(result)
            "connectBleDevice" -> controller.connectBleDevice(args, result)
            "disconnect" -> controller.disconnect(result)
            "depair" -> controller.depair(args, result)
            "isConnected" -> controller.isConnected(result)
            "getFileList" -> controller.getFileList(args, result)
            "exportAudio" -> controller.exportAudio(args, result)
            else -> result.notImplemented()
        }
    }

    // MARK: - ActivityAware (runtime BLE permissions)

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activity = null
    }

    /**
     * Grants the BLE permissions the scan needs, prompting the user if necessary, then reports
     * the outcome. iOS gets the equivalent prompt for free from CoreBluetooth's usage-description
     * flow, so keeping this inside the plugin is what lets Dart call `startScan` unconditionally.
     */
    private fun ensurePermissions(onResult: (Boolean) -> Unit) {
        val ctx = appContext ?: return onResult(false)
        val missing = requiredPermissions().filter {
            ctx.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return onResult(true)

        // Headless engine, or a request already in flight: report "not granted" rather than
        // stacking prompts. Dart hears about it as a scanTimeout.
        val act = activity ?: return onResult(false)
        if (pendingPermission != null) return onResult(false)

        pendingPermission = onResult
        act.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    /**
     * Android 12 split Bluetooth out of the location permission group; below that, a BLE scan
     * still needs fine location or it silently returns nothing.
     */
    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val callback = pendingPermission ?: return false
        pendingPermission = null
        callback(
            grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED },
        )
        return true
    }
}

/**
 * Owns every interaction with [PlaudDeviceAgent], holds the scan cache and in-flight export
 * callbacks, and is the SDK's [PlaudDeviceAgentListener]. Listener callbacks are forwarded to
 * Dart via [emit].
 */
private class PlaudSdkController(
    private val context: Context,
    private val ensurePermissions: ((Boolean) -> Unit) -> Unit,
    private val emit: (String, Map<String, Any?>) -> Unit,
) : PlaudDeviceAgentListener {

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    /**
     * `connectBleDevice` needs the actual [BleDevice] the SDK handed us during a scan — Dart only
     * carries identifiers, so we retain scanned objects and look them up. Keyed by `uuid`, which
     * on Android is the MAC address (the stable per-device handle, standing in for the
     * CoreBluetooth peripheral id on iOS). Touched only on the main thread.
     */
    private val scannedDevices = mutableMapOf<String, BleDevice>()

    /**
     * Retains in-flight export callbacks so the SDK's reference isn't the only one keeping them
     * alive. Main thread only.
     */
    private val exportCallbacks = mutableSetOf<AudioExporter.ExportCallback>()

    /** App-level user identifier from `initSDK`, reused as the default connect `deviceToken`. */
    private var userId: String? = null

    /** Bare host from `initSDK`, needed again when signing the device SN before a connect. */
    private var customDomain: String? = null

    /**
     * The device we last connected to. Android's [BleFile] exposes neither the SN nor the audio
     * layout, so the file list borrows both from here (see [bleFileList]). Volatile: written from
     * listener callbacks and read from others, all on SDK-chosen threads.
     */
    @Volatile
    private var connectedDevice: BleDevice? = null

    @Volatile
    private var connectedSn: String? = null

    private var scanReadyAttempts = 0

    /** Volatile: set on the main thread, cleared from the SDK's `bleScanOverTime` thread. */
    @Volatile
    private var isScanning = false

    fun dispose() {
        isScanning = false
        if (PlaudDeviceAgent.listener === this) PlaudDeviceAgent.listener = null
    }

    private fun rejectArgs(result: MethodChannel.Result, message: String) {
        main.post { result.error("ERR_PLAUD_ARGS", message, null) }
    }

    // MARK: - Connection lifecycle

    fun initSDK(args: Map<String, Any?>, result: MethodChannel.Result) {
        val token = args["userAccessToken"] as? String
        if (token.isNullOrEmpty()) {
            return rejectArgs(result, "userAccessToken is required")
        }
        val domain = args["customDomain"] as? String
        if (domain.isNullOrEmpty()) {
            return rejectArgs(result, "customDomain is required (domain only, no https://)")
        }
        val user = args["userId"] as? String
        main.post {
            userId = user
            customDomain = domain

            // The SDK's Partner API (gen-key / sn-sign) defaults to platform-jp and does NOT
            // follow initSDK's customDomain. Point it at the right host first, or a US token
            // sent to jp 401s, the RSA key fetch fails, and every handshake fails after it.
            runCatching { NiceBuildSdk.getPartnerApiManager().updateBaseUrl("https://$domain") }

            PlaudDeviceAgent.listener = this
            PlaudDeviceAgent.initSDK(
                context = context,
                userAccessToken = token,
                customDomain = domain,
            )
            result.success(null)
        }
    }

    fun startScan(result: MethodChannel.Result) {
        main.post {
            isScanning = true
            scanReadyAttempts = 0
            ensurePermissions { granted ->
                main.post {
                    if (!granted) {
                        isScanning = false
                        emit("scanTimeout", mapOf("reason" to "permissionDenied"))
                    } else {
                        attemptScanWhenReady()
                    }
                }
            }
            result.success(null)
        }
    }

    /**
     * Fires the SDK scan once the Bluetooth adapter is on, polling ~18s. With the radio off the
     * SDK's startScan silently finds nothing, so the UI would spin forever with no hint why —
     * the same trap CoreBluetooth sets on iOS before it reaches `.poweredOn`. Main thread only.
     */
    private fun attemptScanWhenReady() {
        if (!isScanning) return
        if (isBluetoothOn()) {
            runCatching { PlaudDeviceAgent.startScan() }
            return
        }
        scanReadyAttempts += 1
        if (scanReadyAttempts > 60) {
            isScanning = false
            emit("scanTimeout", mapOf("reason" to "bluetoothNotPoweredOn"))
            return
        }
        main.postDelayed({ attemptScanWhenReady() }, 300)
    }

    private fun isBluetoothOn(): Boolean = try {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        manager?.adapter?.isEnabled == true
    } catch (e: Exception) {
        false
    }

    fun stopScan(result: MethodChannel.Result) {
        main.post {
            isScanning = false
            runCatching { PlaudDeviceAgent.stopScan() }
            result.success(null)
        }
    }

    fun connectBleDevice(args: Map<String, Any?>, result: MethodChannel.Result) {
        // Always connect with a device token (the app-level userId) so the handshake binds the
        // device to the user. Prefer an explicit token.
        val token = (args["deviceToken"] as? String)?.takeIf { it.isNotEmpty() } ?: userId
        val uuid = args["uuid"] as? String
        val serialNumber = args["serialNumber"] as? String
        main.post {
            isScanning = false
            val device = lookupDevice(uuid, serialNumber)
            if (device == null) {
                result.error(
                    "ERR_PLAUD_UNKNOWN_DEVICE",
                    "Unknown device — scan first, then connect by uuid or serialNumber",
                    null,
                )
                return@post
            }
            connectedDevice = device
            connectedSn = device.serialNumber

            scope.launch {
                try {
                    prepareHandshake(device)
                    if (!token.isNullOrEmpty()) {
                        PlaudDeviceAgent.connectBleDevice(device, token)
                    } else {
                        PlaudDeviceAgent.connectBleDevice(device)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERR_PLAUD_CONNECT", e.message ?: "connect failed", null)
                }
            }
        }
    }

    /**
     * Two prerequisites the iOS SDK handles internally but the Android one leaves to the caller:
     * the partner RSA key pair (fetched asynchronously by initSDK) has to have landed, and the
     * device SN has to be signed and stored. Skipping either leaves the handshake without an
     * `snSignature` and the connect fails. Both are best-effort — a failure here is logged by the
     * SDK and still lets the connect attempt proceed, matching the template app.
     */
    private suspend fun prepareHandshake(device: BleDevice) = withContext(Dispatchers.IO) {
        val deadline = System.currentTimeMillis() + 10_000L
        while (!NiceBuildSdk.isPartnerDataReady() && System.currentTimeMillis() < deadline) {
            delay(200)
        }
        val sn = device.serialNumber
        if (!sn.isNullOrEmpty()) {
            runCatching { NiceBuildSdk.signAndStoreDeviceSn(deviceType(sn), sn) }
        }
    }

    /** SN prefix → device type, as expected by `signAndStoreDeviceSn`. */
    private fun deviceType(sn: String): String = when {
        sn.startsWith("881") -> "notepro"
        sn.startsWith("880") -> "notepin"
        sn.startsWith("882") -> "notepins"
        else -> "note"
    }

    fun disconnect(result: MethodChannel.Result) {
        main.post {
            runCatching { PlaudDeviceAgent.disconnect() }
            result.success(null)
        }
    }

    fun depair(args: Map<String, Any?>, result: MethodChannel.Result) {
        val clear = args["clear"] as? Boolean ?: true
        main.post {
            runCatching { PlaudDeviceAgent.depair(clear) }
            result.success(null)
        }
    }

    fun isConnected(result: MethodChannel.Result) {
        main.post {
            result.success(mapOf("connected" to PlaudDeviceAgent.isConnected()))
        }
    }

    // MARK: - Files

    fun getFileList(args: Map<String, Any?>, result: MethodChannel.Result) {
        val startSessionId = (args["startSessionId"] as? Number)?.toLong() ?: 0L
        main.post {
            runCatching { PlaudDeviceAgent.getFileList(startSessionId) }
            result.success(null)
        }
    }

    /**
     * Decode a recording into the app's private files dir (the Android analogue of iOS's
     * Documents/PlaudExports). Resolves `{ sessionId, outputPath }` on completion; emits
     * `exportProgress` along the way. `format` defaults to mp3.
     */
    fun exportAudio(args: Map<String, Any?>, result: MethodChannel.Result) {
        val sessionId = (args["sessionId"] as? Number)?.toLong()
        if (sessionId == null || sessionId < 0) {
            return rejectArgs(result, "sessionId is required")
        }
        val format = exportFormat(args["format"] as? String)
        val channels = (args["channels"] as? Number)?.toInt() ?: 1
        main.post {
            val dir = File(context.filesDir, "PlaudExports").apply { mkdirs() }

            val replied = AtomicBoolean(false)
            lateinit var callback: AudioExporter.ExportCallback
            callback = object : AudioExporter.ExportCallback {
                override fun onProgress(progress: Int, message: String) {
                    emit(
                        "exportProgress",
                        mapOf(
                            "sessionId" to sessionId,
                            "progress" to progress,
                            "message" to message,
                        ),
                    )
                }

                override fun onComplete(outputFile: File) {
                    if (!replied.compareAndSet(false, true)) return
                    main.post {
                        result.success(
                            mapOf(
                                "sessionId" to sessionId,
                                "outputPath" to outputFile.absolutePath,
                            ),
                        )
                        exportCallbacks.remove(callback)
                    }
                }

                override fun onError(error: String) {
                    if (!replied.compareAndSet(false, true)) return
                    main.post {
                        result.error("ERR_PLAUD_EXPORT", error, null)
                        exportCallbacks.remove(callback)
                    }
                }
            }
            exportCallbacks.add(callback)

            try {
                PlaudDeviceAgent.exportAudio(sessionId, dir, format, channels, callback)
            } catch (e: Exception) {
                if (replied.compareAndSet(false, true)) {
                    exportCallbacks.remove(callback)
                    result.error("ERR_PLAUD_EXPORT", e.message ?: "export failed", null)
                }
            }
        }
    }

    // MARK: - PlaudDeviceAgentListener

    /**
     * Android reports four state fields where iOS reports seven; the missing keys
     * (`findMyToken`, `hasSndpKey`, `deviceAccessToken`) are simply absent from the payload.
     * Dart treats `penState` as an informational raw map, so it reads both shapes.
     */
    override fun blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int) {
        emit(
            "penState",
            mapOf(
                "state" to state,
                "privacy" to privacy,
                "keyState" to keyState,
                "uDisk" to uDisk,
            ),
        )
    }

    override fun bleScanResult(devices: List<BleDevice>) {
        main.post {
            for (d in devices) scannedDevices[deviceUuid(d)] = d
        }
        emit(
            "scanResult",
            mapOf(
                "devices" to devices.map { d ->
                    mapOf(
                        "name" to (d.name ?: ""),
                        "uuid" to deviceUuid(d),
                        "serialNumber" to (d.serialNumber ?: ""),
                        "rssi" to d.rssi,
                        // The Android BleDevice has no supportWiFi flag; NotePro (project code
                        // 881) is the model with WiFi fast transfer.
                        "supportWiFi" to (d.projectCode == 881L),
                    )
                },
            ),
        )
    }

    override fun bleScanOverTime() {
        isScanning = false
        emit("scanTimeout", emptyMap())
    }

    override fun bleConnectState(state: Int) {
        // 1 = connected, 0 = disconnected, {2, -1, -2} = connection/handshake failure.
        val failed = state == 2 || state == -1 || state == -2
        if (state == 0 || failed) {
            connectedDevice = null
            connectedSn = null
        }
        emit(
            "connectState",
            mapOf("connected" to (state == 1), "failed" to failed, "state" to state),
        )
    }

    override fun bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
        if (status == 0 && !sn.isNullOrEmpty()) connectedSn = sn
        emit("bind", mapOf("sn" to sn, "status" to status, "protVersion" to protVersion))
    }

    // MARK: - Recording (device-initiated: physical button / VAD)

    override fun bleRecordStart(
        sessionId: Long,
        start: Long,
        status: Int,
        scene: Int,
        startTime: Long,
        reason: Int,
    ) {
        emit(
            "recordStart",
            mapOf(
                "sessionId" to sessionId,
                "start" to start,
                "status" to status,
                "scene" to scene,
                "startTime" to startTime,
                "reason" to reason,
            ),
        )
    }

    override fun bleRecordStop(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
        emit(
            "recordStop",
            mapOf(
                "sessionId" to sessionId,
                "reason" to reason,
                "fileExist" to fileExist,
                "fileSize" to fileSize,
            ),
        )
    }

    override fun bleRecordPause(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
        emit(
            "recordPause",
            mapOf(
                "sessionId" to sessionId,
                "reason" to reason,
                "fileExist" to fileExist,
                "fileSize" to fileSize,
            ),
        )
    }

    override fun bleRecordResume(
        sessionId: Long,
        start: Long,
        status: Int,
        scene: Int,
        startTime: Long,
    ) {
        emit(
            "recordResume",
            mapOf(
                "sessionId" to sessionId,
                "start" to start,
                "status" to status,
                "scene" to scene,
                "startTime" to startTime,
            ),
        )
    }

    override fun bleDepair(status: Int) {
        emit("depair", mapOf("status" to status))
    }

    override fun bleFileList(files: List<BleFile>) {
        // Android's BleFile carries only sessionId / fileSize / attribute / scene. The SN and the
        // audio layout come from the connected device, and the duration is derived the same way
        // the SDK does it (80 bytes per 20 ms Opus frame, per channel).
        val sn = connectedSn ?: ""
        val channels = connectedDevice?.audioChannel?.takeIf { it > 0 } ?: 1
        val isOgg = connectedDevice?.isOggAudio == true
        emit(
            "fileList",
            mapOf(
                "files" to files.map { f ->
                    mapOf(
                        "sn" to sn,
                        "sessionId" to f.sessionId,
                        "size" to f.fileSize,
                        "scenes" to f.scene,
                        "channels" to channels,
                        "isOgg" to isOgg,
                        "isMusic" to f.isMusic,
                        // Milliseconds → seconds, matching iOS BleFile.duration(). Ogg-container
                        // recordings read slightly long, since page headers count toward size.
                        "duration" to BleFile.calculateOpusDuration(f.fileSize, channels) / 1000L,
                    )
                },
            ),
        )
    }

    // MARK: - Helpers

    /** Android's stable per-device handle, standing in for the iOS peripheral UUID. */
    private fun deviceUuid(d: BleDevice): String =
        d.macAddress ?: d.serialNumber ?: ""

    private fun lookupDevice(uuid: String?, serialNumber: String?): BleDevice? {
        if (uuid != null) scannedDevices[uuid]?.let { return it }
        if (serialNumber != null) {
            return scannedDevices.values.firstOrNull { it.serialNumber == serialNumber }
        }
        return null
    }

    private fun exportFormat(raw: String?): AudioExportFormat =
        when (raw?.lowercase() ?: "mp3") {
            "pcm" -> AudioExportFormat.PCM
            "wav" -> AudioExportFormat.WAV
            "opus" -> AudioExportFormat.OPUS
            else -> AudioExportFormat.MP3
        }
}
