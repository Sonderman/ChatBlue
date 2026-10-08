package com.sondermium.chatblue

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
                    val prefs = getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)
                    if (prefs.getBoolean("bt_enable_consent_granted", false)) {
                        // User consented before: enable silently instead of asking again
                        @Suppress("MissingPermission")
                        runCatching { BluetoothAdapter.getDefaultAdapter()?.enable() }
                        result.success(BluetoothAdapter.getDefaultAdapter()?.isEnabled == true)
                    } else {
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                        pendingEnableBtResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQUEST_ENABLE_BT)
                    }
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
                "getThisDeviceAddress" -> { result.success(wifiDirectManager.getThisDeviceAddress()) }
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
            listOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
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
                    val prefs = getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)
                    if (prefs.getBoolean("bt_enable_consent_granted", false)) {
                        @Suppress("MissingPermission")
                        runCatching { BluetoothAdapter.getDefaultAdapter()?.enable() }
                        result.success(BluetoothAdapter.getDefaultAdapter()?.isEnabled == true)
                    } else {
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                        pendingNjEnableBtResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQUEST_NJ_ENABLE_BT)
                    }
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
            // discovery and connections) need NEARBY_WIFI_DEVICES; without a
            // runtime grant the WiFi side cannot engage on 13+ devices.
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.NEARBY_WIFI_DEVICES
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
        } else {
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION
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
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        bluetoothManager.dispose()
        wifiDirectManager.dispose()
        nearbyManager.dispose()
    }
}
