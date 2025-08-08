package com.sondermium.chatblue

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
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
    private lateinit var methodChannel: MethodChannel
    private lateinit var scanEventChannel: EventChannel
    private lateinit var socketEventChannel: EventChannel

    private var scanEventSink: EventChannel.EventSink? = null
    private var socketEventSink: EventChannel.EventSink? = null

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingEnableBtResult: MethodChannel.Result? = null
    private var pendingDiscoverableResult: MethodChannel.Result? = null

    private val REQUEST_ENABLE_BT = 1001
    private val REQUEST_DISCOVERABLE = 1002
    private val REQUEST_PERMISSIONS = 1003

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!::bluetoothManager.isInitialized) {
            bluetoothManager = BluetoothClassicManager(this)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_ENABLE_BT -> {
                val granted = resultCode == Activity.RESULT_OK
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
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PERMISSIONS) {
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (!::bluetoothManager.isInitialized) {
            bluetoothManager = BluetoothClassicManager(this)
        }
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/bt")
        scanEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/scan")
        socketEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sondermium.chatblue/socket")

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
                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    pendingEnableBtResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQUEST_ENABLE_BT)
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
    }
}
