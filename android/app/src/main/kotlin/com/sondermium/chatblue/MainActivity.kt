package com.sondermium.chatblue

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private lateinit var bluetoothManager: BluetoothClassicManager
    private lateinit var wifiDirectManager: WifiDirectManager
    private lateinit var methodChannel: MethodChannel
    private lateinit var scanEventChannel: EventChannel
    private lateinit var socketEventChannel: EventChannel
    private lateinit var wdMethodChannel: MethodChannel
    private lateinit var wdScanEventChannel: EventChannel
    private lateinit var wdSocketEventChannel: EventChannel

    // Nearby Connections transport (third channel): manager + channels
    // mirror the BT/WD wiring one-to-one.
    private lateinit var nearbyManager: NearbyManager
    private lateinit var njMethodChannel: MethodChannel
    private lateinit var njScanEventChannel: EventChannel
    private lateinit var njSocketEventChannel: EventChannel

    // App-level utility channel (open received files, launch maps).
    private lateinit var utilMethodChannel: MethodChannel

    private var scanEventSink: EventChannel.EventSink? = null
    private var socketEventSink: EventChannel.EventSink? = null
    private var njScanEventSink: EventChannel.EventSink? = null
    private var njSocketEventSink: EventChannel.EventSink? = null

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingEnableBtResult: MethodChannel.Result? = null
    private var pendingDiscoverableResult: MethodChannel.Result? = null
    private var pendingNjPermissionResult: MethodChannel.Result? = null
    private var pendingNjEnableBtResult: MethodChannel.Result? = null

    private val REQUEST_ENABLE_BT = 1001
    private val REQUEST_DISCOVERABLE = 1002
    private val REQUEST_PERMISSIONS = 1003
    private val REQUEST_NEARBY_PERMISSIONS = 3001
    private val REQUEST_NJ_ENABLE_BT = 3002

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!::bluetoothManager.isInitialized) {
            bluetoothManager = BluetoothClassicManager(this)
        }
        if (!::wifiDirectManager.isInitialized) {
            wifiDirectManager = WifiDirectManager(this)
        }
        if (!::nearbyManager.isInitialized) {
            nearbyManager = NearbyManager(this)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_ENABLE_BT -> {
                val granted = resultCode == Activity.RESULT_OK
                if (granted) {
                    // Remember consent so future launches enable Bluetooth silently
                    getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean("bt_enable_consent_granted", true)
                        .apply()
                }
                pendingEnableBtResult?.success(granted)
                pendingEnableBtResult = null
            }
            REQUEST_DISCOVERABLE -> {
                val duration = resultCode
                val allowed = duration != Activity.RESULT_CANCELED && duration > 0
                pendingDiscoverableResult?.success(mapOf(
                    "allowed" to allowed,
                    "durationSec" to duration
                ))
                pendingDiscoverableResult = null
            }
            REQUEST_NJ_ENABLE_BT -> {
                val granted = resultCode == Activity.RESULT_OK
                if (granted) {
                    // Same consent pref the BT channel writes: future
                    // launches enable Bluetooth silently.
                    getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean("bt_enable_consent_granted", true)
                        .apply()
                }
                pendingNjEnableBtResult?.success(granted)
                pendingNjEnableBtResult = null
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_PERMISSIONS -> {
                val resultMap = mutableMapOf<String, Boolean>()
                for (i in permissions.indices) {
                    val perm = permissions[i]
                    val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
                    resultMap[perm] = granted
                }
                val allGranted = resultMap.values.all { it }
                pendingPermissionResult?.success(mapOf(
                    "granted" to allGranted,
                    "details" to resultMap
                ))
                pendingPermissionResult = null
            }
            REQUEST_WD_PERMISSIONS -> {
                val resultMap = mutableMapOf<String, Boolean>()
                for (i in permissions.indices) {
                    val perm = permissions[i]
                    val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
                    resultMap[perm] = granted
                }
                val allGranted = resultMap.values.all { it }
                pendingWdPermissionResult?.success(mapOf("granted" to allGranted, "details" to resultMap))
                pendingWdPermissionResult = null
            }
            REQUEST_NEARBY_PERMISSIONS -> {
                val resultMap = mutableMapOf<String, Boolean>()
                for (i in permissions.indices) {
                    val perm = permissions[i]
                    val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
                    resultMap[perm] = granted
                }
                val allGranted = resultMap.values.all { it }
                pendingNjPermissionResult?.success(mapOf("granted" to allGranted, "details" to resultMap))
                pendingNjPermissionResult = null
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (!::bluetoothManager.isInitialized) {
            bluetoothManager = BluetoothClassicManager(this)
        }
        if (!::wifiDirectManager.isInitialized) {
            wifiDirectManager = WifiDirectManager(this)
        }
        if (!::nearbyManager.isInitialized) {
            nearbyManager = NearbyManager(this)
        }
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/bt")
        scanEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/scan")
        socketEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/socket")
        wdMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/wd")
        wdScanEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/wd_scan")
        wdSocketEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/wd_socket")
        njMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/nearby")
        njScanEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/nearby_scan")
        njSocketEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/nearby_socket")
        utilMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/util")

        bluetoothManager.setScanCallbacks(
            onStarted = {
                runOnUiThread {
                    scanEventSink?.success(mapOf("event" to "started"))
                }
            },
            onDeviceFound = { deviceMap ->
                runOnUiThread {
                    scanEventSink?.success(mapOf("event" to "device", "data" to deviceMap))
                }
            },
            onFinished = {
                runOnUiThread {
                    scanEventSink?.success(mapOf("event" to "finished"))
                }
            },
            onError = { message ->
                runOnUiThread {
                    scanEventSink?.error("SCAN_ERROR", message, null)
                }
            }
        )

        bluetoothManager.setSocketCallbacks(
            onConnected = { remote ->
                runOnUiThread {
                    socketEventSink?.success(mapOf("event" to "connected", "remote" to remote))
                }
            },
            onDisconnected = { reason ->
                runOnUiThread {
                    socketEventSink?.success(mapOf("event" to "disconnected", "reason" to reason))
                }
            },
            onBytesReceived = { bytes ->
                runOnUiThread {
                    socketEventSink?.success(mapOf("event" to "data", "kind" to "bytes", "bytes" to bytes, "string" to ""))
                }
            },
            onError = { message ->
                runOnUiThread {
                    socketEventSink?.error("SOCKET_ERROR", message, null)
                }
            },
            onTextReceived = { text ->
                runOnUiThread {
                    socketEventSink?.success(mapOf("event" to "data", "kind" to "text", "bytes" to text.toByteArray(Charsets.UTF_8), "string" to text))
                }
            },
            onProgress = { direction, current, total, kind ->
                runOnUiThread {
                    socketEventSink?.success(
                        mapOf(
                            "event" to "progress",
                            "direction" to direction,
                            "current" to current,
                            "total" to total,
                            "kind" to kind
                        )
                    )
                }
            }
        )

        setupMethodChannelHandlers()
        setupEventChannels()

        setupWdCallbacks()
        setupWdMethodChannelHandlers()
        setupWdEventChannels()

        setupNearbyCallbacks()
        setupNearbyMethodChannelHandlers()
        setupNearbyEventChannels()

        setupUtilMethodChannelHandlers()
    }

    /// Utility channel: open a received file via the system viewer
    /// (FileProvider content uri + temporary read grant), save received
    /// package archives into the public Downloads folder, and launch a maps
    /// app for coordinates (geo: intent with an https fallback).
    private fun setupUtilMethodChannelHandlers() {
        utilMethodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "openFile" -> {
                    openFileWithViewer(call.argument<String>("path"), result)
                }
                "openMap" -> {
                    val lat = call.argument<Double>("lat")
                    val lng = call.argument<Double>("lng")
                    if (lat == null || lng == null) {
                        result.success(false)
                    } else {
                        openMapIntent(lat, lng, result)
                    }
                }
                "saveApkToDownloads" -> {
                    saveApkToDownloads(call.argument<String>("path"), result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Opens [path] with the system viewer. The file is copied into the
    /// cache first and served through the app's FileProvider (received files
    /// live under the app data dir, which an outgoing intent cannot hand out
    /// directly). Returns "opened" or "failed". Package archives do NOT go
    /// through here — the Dart side routes them to saveApkToDownloads
    /// (the app holds no install-packages permission; Play restricts it).
    private fun openFileWithViewer(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success("failed")
            return
        }
        try {
            val source = File(path)
            if (!source.exists()) {
                result.success("failed")
                return
            }
            val mime = guessMimeFromName(source.name)
            val shareDir = File(cacheDir, "open")
            if (!shareDir.exists()) shareDir.mkdirs()
            val shared = File(shareDir, source.name)
            source.copyTo(shared, overwrite = true)

            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", shared)
            val resolved = contentResolver.getType(uri) ?: mime
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, resolved)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, null))
            result.success("opened")
        } catch (e: Exception) {
            result.success("failed")
        }
    }

    /// Saves a received package archive (APK) into the public Downloads
    /// folder — Android 10+ through MediaStore (no permission required),
    /// older releases via the legacy public dir (the Dart side requests the
    /// storage grant and retries once when it gets "permission"). Returns
    /// "saved", "permission" or "failed". The app deliberately does not
    /// install packages itself: Google Play restricts the install-packages
    /// permission, so the user installs from the system file manager.
    private fun saveApkToDownloads(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success("failed")
            return
        }
        try {
            val source = File(path)
            if (!source.exists()) {
                result.success("failed")
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
                    put(
                        MediaStore.MediaColumns.MIME_TYPE,
                        "application/vnd.android.package-archive"
                    )
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri == null) {
                    result.success("failed")
                    return
                }
                try {
                    resolver.openOutputStream(uri)?.use { out ->
                        source.inputStream().use { it.copyTo(out) }
                    } ?: throw IllegalStateException("no output stream")
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e
                }
                result.success("saved")
            } else {
                val dir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!dir.exists()) dir.mkdirs()
                var target = File(dir, source.name)
                if (target.exists()) {
                    target = File(
                        dir,
                        "${source.nameWithoutExtension}-${System.currentTimeMillis()}.${source.extension}"
                    )
                }
                target.outputStream().use { out ->
                    source.inputStream().use { it.copyTo(out) }
                }
                MediaScannerConnection.scanFile(
                    this,
                    arrayOf(target.absolutePath),
                    arrayOf("application/vnd.android.package-archive"),
                    null
                )
                result.success("saved")
            }
        } catch (e: SecurityException) {
            result.success("permission")
        } catch (e: Exception) {
            result.success("failed")
        }
    }

    /// Best-effort mime type for the viewer (contentResolver often returns
    /// null for our FileProvider uris, and a wrong generic type can hide
    /// the right app from the chooser).
    private fun guessMimeFromName(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "pdf" -> "application/pdf"
            "txt" -> "text/plain"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "mp3" -> "audio/mpeg"
            "m4a" -> "audio/mp4"
            "wav" -> "audio/x-wav"
            "zip" -> "application/zip"
            "apk" -> "application/vnd.android.package-archive"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            else -> "*/*"
        }
    }

    /// Opens the coordinates in a maps app (geo:), falling back to the
    /// https maps url when no app handles the geo scheme.
    private fun openMapIntent(lat: Double, lng: Double, result: MethodChannel.Result) {
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lng?q=$lat,$lng"))
            )
            result.success(true)
            return
        } catch (_: Exception) {
            // No geo handler: fall through to the https url below.
        }
        try {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://maps.google.com/?q=$lat,$lng")
                )
            )
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun setupMethodChannelHandlers() {
        methodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "isBluetoothAvailable" -> {
                    result.success(BluetoothAdapter.getDefaultAdapter() != null)
                }
                "isBluetoothEnabled" -> {
                    result.success(BluetoothAdapter.getDefaultAdapter()?.isEnabled == true)
                }
                "requestEnableBluetooth" -> {
                    // Startup path (no user gesture): enable silently when a
                    // consent is remembered — never a nagging dialog on
                    // every cold start with Bluetooth off; the scan
                    // screens' own buttons carry the consent flow.
                    requestEnableBluetoothFlow(result, nearby = false, dialogFallback = false)
                }
                "requestBluetoothPermissions" -> {
                    val needed = requiredRuntimePermissions()
                        .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
                        .toTypedArray()
                    if (needed.isEmpty()) {
                        result.success(mapOf("granted" to true, "details" to emptyMap<String, Boolean>()))
                    } else {
                        pendingPermissionResult = result
                        ActivityCompat.requestPermissions(this, needed, REQUEST_PERMISSIONS)
                    }
                }
                "requestDiscoverable" -> {
                    val seconds: Int = (call.argument<Int>("seconds") ?: 120).coerceIn(1, 300)
                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    intent.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, seconds)
                    pendingDiscoverableResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQUEST_DISCOVERABLE)
                }
                "startScan" -> {
                    bluetoothManager.startDiscovery()
                    result.success(true)
                }
                "stopScan" -> {
                    bluetoothManager.stopDiscovery()
                    result.success(true)
                }
                "getDiscoveredDevices" -> {
                    result.success(bluetoothManager.getDiscoveredDevices())
                }
                "clearDiscoveredDevices" -> {
                    bluetoothManager.clearDiscoveredDevices()
                    result.success(true)
                }
                "getPairedDevices" -> {
                    result.success(bluetoothManager.getPairedDevices())
                }
                "startServer" -> {
                    val name: String = call.argument<String>("serviceName") ?: "ChatBlueSPP"
                    val uuid: String? = call.argument<String>("uuid")
                    bluetoothManager.startServer(name, uuid)
                    result.success(true)
                }
                "stopServer" -> {
                    bluetoothManager.stopServer()
                    result.success(true)
                }
                "connect" -> {
                    val address: String? = call.argument("address")
                    if (address.isNullOrBlank()) {
                        result.error("ARG_ERROR", "'address' is required", null)
                    } else {
                        val uuid: String? = call.argument("uuid")
                        bluetoothManager.connect(address, uuid)
                        result.success(true)
                    }
                }
                "disconnect" -> {
                    bluetoothManager.disconnect()
                    result.success(true)
                }
                "isConnected" -> {
                    result.success(bluetoothManager.isConnected())
                }
                "getLiveRssi" -> {
                    val address: String? = call.argument("address")
                    if (address.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        result.success(bluetoothManager.getLiveRssi(address))
                    }
                }
                "sendString" -> {
                    val text: String? = call.argument("text")
                    if (text == null) {
                        result.error("ARG_ERROR", "'text' is required", null)
                    } else {
                        bluetoothManager.sendText(text)
                        result.success(true)
                    }
                }
                "sendBytes" -> {
                    val data: ByteArray? = call.argument("bytes")
                    if (data == null) {
                        result.error("ARG_ERROR", "'bytes' is required", null)
                    } else {
                        bluetoothManager.sendRawBytes(data)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupEventChannels() {
        scanEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                scanEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                scanEventSink = null
            }
        })

        socketEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                socketEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                socketEventSink = null
            }
        })
    }

    private fun setupWdCallbacks() {
        wifiDirectManager.setScanCallbacks(
            onStarted = {
                runOnUiThread { wdScanEventSink?.success(mapOf("event" to "started")) }
            },
            onPeerFound = { peer ->
                runOnUiThread { wdScanEventSink?.success(mapOf("event" to "peer", "data" to peer)) }
            },
            onFinished = {
                runOnUiThread { wdScanEventSink?.success(mapOf("event" to "finished")) }
            },
            onError = { message ->
                runOnUiThread { wdScanEventSink?.error("WD_SCAN_ERROR", message, null) }
            }
        )

        wifiDirectManager.setSocketCallbacks(
            onConnected = { remote ->
                runOnUiThread { wdSocketEventSink?.success(mapOf("event" to "connected", "remote" to remote)) }
            },
            onDisconnected = { reason ->
                runOnUiThread { wdSocketEventSink?.success(mapOf("event" to "disconnected", "reason" to reason)) }
            },
            onBytesReceived = { bytes ->
                runOnUiThread { wdSocketEventSink?.success(mapOf("event" to "data", "kind" to "bytes", "bytes" to bytes, "string" to "")) }
            },
            onError = { message ->
                runOnUiThread { wdSocketEventSink?.error("WD_SOCKET_ERROR", message, null) }
            },
            onTextReceived = { text ->
                runOnUiThread { wdSocketEventSink?.success(mapOf("event" to "data", "kind" to "text", "bytes" to text.toByteArray(Charsets.UTF_8), "string" to text)) }
            },
            onProgress = { direction, current, total, kind ->
                runOnUiThread {
                    wdSocketEventSink?.success(
                        mapOf(
                            "event" to "progress",
                            "direction" to direction,
                            "current" to current,
                            "total" to total,
                            "kind" to kind
                        )
                    )
                }
            }
        )
    }

    private var wdScanEventSink: EventChannel.EventSink? = null
    private var wdSocketEventSink: EventChannel.EventSink? = null

    private fun setupWdEventChannels() {
        wdScanEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                wdScanEventSink = events
            }
            override fun onCancel(arguments: Any?) { wdScanEventSink = null }
        })
        wdSocketEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                wdSocketEventSink = events
            }
            override fun onCancel(arguments: Any?) { wdSocketEventSink = null }
        })
    }

    private fun setupWdMethodChannelHandlers() {
        wdMethodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "isWifiP2pSupported" -> {
                    result.success(wifiDirectManager.isP2pSupported())
                }
                "requestWifiDirectPermissions" -> {
                    val needed = requiredWdRuntimePermissions()
                        .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
                        .toTypedArray()
                    if (needed.isEmpty()) {
                        result.success(mapOf("granted" to true, "details" to emptyMap<String, Boolean>()))
                    } else {
                        pendingWdPermissionResult = result
                        androidx.core.app.ActivityCompat.requestPermissions(this, needed, REQUEST_WD_PERMISSIONS)
                    }
                }
                "isWifiEnabled" -> { result.success(wifiDirectManager.isWifiEnabled()) }
                "requestEnableWifi" -> { result.success(wifiDirectManager.requestEnableWifi()) }
                "isLocationEnabled" -> { result.success(wifiDirectManager.isLocationOn()) }
                "requestEnableLocation" -> { result.success(wifiDirectManager.requestEnableLocation()) }
                "getThisDeviceAddress" -> { result.success(wifiDirectManager.getThisDeviceAddress()) }
                "getDeviceName" -> { result.success(DeviceNameResolver.resolve(this)) }
                "startDiscovery" -> { wifiDirectManager.startDiscovery(); result.success(true) }
                "stopDiscovery" -> { wifiDirectManager.stopDiscovery(); result.success(true) }
                "getDiscoveredPeers" -> { result.success(wifiDirectManager.getDiscoveredPeers()) }
                "requestPeers" -> { wifiDirectManager.requestPeers(); result.success(true) }
                "clearDiscoveredPeers" -> { wifiDirectManager.clearDiscoveredPeers(); result.success(true) }
                "createGroup" -> { wifiDirectManager.createGroup(); result.success(true) }
                "removeGroup" -> { wifiDirectManager.removeGroup(); result.success(true) }
                "connect" -> {
                    val addr: String? = call.argument("deviceAddress")
                    if (addr.isNullOrBlank()) result.error("ARG_ERROR", "'deviceAddress' is required", null)
                    else { wifiDirectManager.connect(addr); result.success(true) }
                }
                "disconnect" -> { wifiDirectManager.disconnect(); result.success(true) }
                "isConnected" -> { result.success(wifiDirectManager.isConnected()) }
                "getLiveRssi" -> { result.success(wifiDirectManager.getLiveRssi()) }
                "sendString" -> {
                    val text: String? = call.argument("text")
                    if (text == null) result.error("ARG_ERROR", "'text' is required", null) else { wifiDirectManager.sendText(text); result.success(true) }
                }
                "sendBytes" -> {
                    val data: ByteArray? = call.argument("bytes")
                    if (data == null) result.error("ARG_ERROR", "'bytes' is required", null) else { wifiDirectManager.sendRawBytes(data); result.success(true) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var pendingWdPermissionResult: MethodChannel.Result? = null
    private val REQUEST_WD_PERMISSIONS = 2001

    private fun requiredWdRuntimePermissions(): List<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            listOf(android.Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            // On Android 12+ FINE is only granted when requested together
            // with COARSE; older versions accept the pair as well.
            listOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION
            )
        }
    }

    private fun setupNearbyCallbacks() {
        nearbyManager.setScanCallbacks(
            onStarted = {
                runOnUiThread { njScanEventSink?.success(mapOf("event" to "started")) }
            },
            onEndpointFound = { data ->
                runOnUiThread { njScanEventSink?.success(mapOf("event" to "endpoint", "data" to data)) }
            },
            onEndpointLost = { endpointId ->
                runOnUiThread {
                    njScanEventSink?.success(
                        mapOf("event" to "endpointLost", "data" to mapOf("endpointId" to endpointId))
                    )
                }
            },
            onFinished = {
                runOnUiThread { njScanEventSink?.success(mapOf("event" to "finished")) }
            },
            onError = { message ->
                runOnUiThread { njScanEventSink?.error("NEARBY_SCAN_ERROR", message, null) }
            }
        )

        nearbyManager.setConnectionCallbacks(
            onInitiated = { data ->
                runOnUiThread { njSocketEventSink?.success(mapOf("event" to "initiated", "data" to data)) }
            },
            onConnected = { data ->
                runOnUiThread { njSocketEventSink?.success(mapOf("event" to "connected", "data" to data)) }
            },
            onRejected = { endpointId ->
                runOnUiThread {
                    njSocketEventSink?.success(
                        mapOf("event" to "rejected", "data" to mapOf("endpointId" to endpointId))
                    )
                }
            },
            onDisconnected = { reason ->
                runOnUiThread { njSocketEventSink?.success(mapOf("event" to "disconnected", "reason" to reason)) }
            },
            onBandwidth = { quality ->
                runOnUiThread {
                    njSocketEventSink?.success(
                        mapOf("event" to "bandwidth", "data" to mapOf("quality" to quality))
                    )
                }
            }
        )

        nearbyManager.setPayloadCallbacks(
            onTextReceived = { text ->
                runOnUiThread {
                    njSocketEventSink?.success(
                        mapOf("event" to "data", "kind" to "text", "bytes" to text.toByteArray(Charsets.UTF_8), "string" to text)
                    )
                }
            },
            onBytesReceived = { bytes ->
                runOnUiThread {
                    njSocketEventSink?.success(mapOf("event" to "data", "kind" to "bytes", "bytes" to bytes, "string" to ""))
                }
            },
            onError = { message ->
                runOnUiThread { njSocketEventSink?.error("NEARBY_SOCKET_ERROR", message, null) }
            },
            onProgress = { direction, current, total, kind ->
                runOnUiThread {
                    njSocketEventSink?.success(
                        mapOf(
                            "event" to "progress",
                            "direction" to direction,
                            "current" to current,
                            "total" to total,
                            "kind" to kind
                        )
                    )
                }
            }
        )
    }

    private fun setupNearbyEventChannels() {
        njScanEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                njScanEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                njScanEventSink = null
            }
        })
        njSocketEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                njSocketEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                njSocketEventSink = null
            }
        })
    }

    private fun setupNearbyMethodChannelHandlers() {
        njMethodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "getNearbyStatus" -> {
                    result.success(nearbyManager.getStatus())
                }
                "getDeviceName" -> {
                    result.success(nearbyManager.getDeviceName())
                }
                "requestEnableLocation" -> {
                    result.success(nearbyManager.requestEnableLocation())
                }
                "openAppSettings" -> {
                    // Escape hatch for a permanently denied permission: the
                    // system dialog no longer appears, but the app's own
                    // settings page still grants it.
                    val intent = Intent(
                        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.fromParts("package", packageName, null)
                    )
                    runCatching { startActivity(intent) }
                    result.success(true)
                }
                "cancelConnect" -> {
                    nearbyManager.cancelConnect()
                    result.success(true)
                }
                "requestNearbyPermissions" -> {
                    val needed = requiredNearbyRuntimePermissions()
                        .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
                        .toTypedArray()
                    if (needed.isEmpty()) {
                        result.success(mapOf("granted" to true, "details" to emptyMap<String, Boolean>()))
                    } else {
                        pendingNjPermissionResult = result
                        ActivityCompat.requestPermissions(this, needed, REQUEST_NEARBY_PERMISSIONS)
                    }
                }
                "requestEnableBluetooth" -> {
                    // The Nearby screen's "turn on Bluetooth" button: an
                    // explicit user gesture — the flow must always end in a
                    // visible outcome (system dialog when a silent enable
                    // is impossible), never in a dead tap.
                    requestEnableBluetoothFlow(result, nearby = true, dialogFallback = true)
                }
                "startScan" -> {
                    val uid: String = call.argument<String>("uid") ?: ""
                    val name: String = call.argument<String>("name") ?: ""
                    nearbyManager.startScan(name, uid)
                    result.success(true)
                }
                "stopScan" -> {
                    nearbyManager.stopScan()
                    result.success(true)
                }
                "connect" -> {
                    val endpointId: String? = call.argument("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.error("ARG_ERROR", "'endpointId' is required", null)
                    } else {
                        val uid: String = call.argument<String>("uid") ?: ""
                        val name: String = call.argument<String>("name") ?: ""
                        nearbyManager.connect(endpointId, uid, name)
                        result.success(true)
                    }
                }
                "accept" -> {
                    val endpointId: String? = call.argument("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.error("ARG_ERROR", "'endpointId' is required", null)
                    } else {
                        nearbyManager.accept(endpointId)
                        result.success(true)
                    }
                }
                "reject" -> {
                    val endpointId: String? = call.argument("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.error("ARG_ERROR", "'endpointId' is required", null)
                    } else {
                        nearbyManager.reject(endpointId)
                        result.success(true)
                    }
                }
                "disconnect" -> {
                    nearbyManager.disconnect()
                    result.success(true)
                }
                "isConnected" -> {
                    result.success(nearbyManager.isConnected())
                }
                "sendString" -> {
                    val text: String? = call.argument("text")
                    if (text == null) result.error("ARG_ERROR", "'text' is required", null)
                    else { nearbyManager.sendText(text); result.success(true) }
                }
                "sendBytes" -> {
                    val data: ByteArray? = call.argument("bytes")
                    if (data == null) result.error("ARG_ERROR", "'bytes' is required", null)
                    else { nearbyManager.sendRawBytes(data); result.success(true) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requiredNearbyRuntimePermissions(): List<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            // Android 13+: Nearby's WiFi mediums (WiFi LAN / hotspot used by
            // discovery and connections) need NEARBY_WIFI_DEVICES, and
            // discovery additionally needs a location permission: GMS
            // checks ACCESS_COARSE_LOCATION specifically (refusing with
            // "8034: MISSING_PERMISSION_ACCESS_COARSE_LOCATION" otherwise).
            // On Android 12+ FINE must be requested together with COARSE —
            // a lone FINE request is ignored by the system, and the
            // "approximate" grant delivers COARSE only, which is enough.
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.NEARBY_WIFI_DEVICES,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        } else {
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        }
    }

    private fun requiredRuntimePermissions(): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
        } else {
            // On Android 12+ FINE is only granted when requested together
            // with COARSE; older versions accept the pair as well.
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        }
    }

    /// Completes [result] with the outcome of a Bluetooth enable request.
    /// Below Android 13 a remembered consent enables silently; from
    /// TIRAMISU on, `BluetoothAdapter.enable()` is a documented no-op for
    /// targetSdk 33+ apps ("applications are not allowed to enable/disable
    /// Bluetooth", always returns false), so a silent attempt that fails to
    /// take must fall back to the visible system dialog — the old silent
    /// branch returned the pre-enable snapshot, which made the scan
    /// screens' "turn on Bluetooth" buttons look completely dead (stale
    /// false → the Dart side bailed with no UI at all).
    private fun requestEnableBluetoothFlow(
        result: MethodChannel.Result,
        nearby: Boolean,
        dialogFallback: Boolean,
    ) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.success(false)
            return
        }
        if (adapter.isEnabled) {
            result.success(true)
            return
        }
        val prefs = getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)
        val consented = prefs.getBoolean("bt_enable_consent_granted", false)
        // Android 13+: `enable()` is a documented no-op for targetSdk 33+
        // apps — there is NO silent path there, so the system dialog
        // (ACTION_REQUEST_ENABLE) opens directly: for every user gesture
        // (scan-screen buttons) and every first-time request. Only the 13+
        // cold-start path (no gesture, consent already remembered) gives up
        // quietly, so a prompt never nags on app launch.
        val api33Plus = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        if (!consented || (api33Plus && dialogFallback)) {
            launchBluetoothEnableDialog(result, nearby)
            return
        }
        // Below 13 (or the quiet 13+ cold-start path): try the silent
        // enable; poll the adapter state instead of trusting the
        // pre-enable snapshot.
        @Suppress("MissingPermission")
        val silent = runCatching { adapter.enable() }.getOrDefault(false)
        if (!silent) {
            if (dialogFallback) {
                launchBluetoothEnableDialog(result, nearby)
            } else {
                result.success(false)
            }
            return
        }
        if (nearby) pendingNjEnableBtResult = result else pendingEnableBtResult = result
        pollSilentBluetoothEnable(adapter, 0, nearby, dialogFallback)
    }

    private fun launchBluetoothEnableDialog(result: MethodChannel.Result, nearby: Boolean) {
        if (nearby) pendingNjEnableBtResult = result else pendingEnableBtResult = result
        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
        @Suppress("DEPRECATION")
        startActivityForResult(intent, if (nearby) REQUEST_NJ_ENABLE_BT else REQUEST_ENABLE_BT)
    }

    /// The adapter state flips a beat after a silent enable — poll instead
    /// of reporting the pre-enable snapshot; if it never takes, fall back
    /// to the visible dialog (the pending result stays armed for it).
    private fun pollSilentBluetoothEnable(
        adapter: BluetoothAdapter,
        attempt: Int,
        nearby: Boolean,
        dialogFallback: Boolean,
    ) {
        Handler(Looper.getMainLooper()).postDelayed({
            if (adapter.isEnabled) {
                completeBtEnable(nearby, true)
                return@postDelayed
            }
            if (attempt >= 5) {
                if (dialogFallback) {
                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    @Suppress("DEPRECATION")
                    startActivityForResult(
                        intent,
                        if (nearby) REQUEST_NJ_ENABLE_BT else REQUEST_ENABLE_BT,
                    )
                } else {
                    completeBtEnable(nearby, false)
                }
                return@postDelayed
            }
            pollSilentBluetoothEnable(adapter, attempt + 1, nearby, dialogFallback)
        }, 500)
    }

    private fun completeBtEnable(nearby: Boolean, value: Boolean) {
        if (nearby) {
            pendingNjEnableBtResult?.success(value)
            pendingNjEnableBtResult = null
        } else {
            pendingEnableBtResult?.success(value)
            pendingEnableBtResult = null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        bluetoothManager.dispose()
        wifiDirectManager.dispose()
        nearbyManager.dispose()
    }
}
