package com.sondermium.chatblue

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * Resolves the user-visible device name every transport's identity exchange
 * shares (Nearby endpoint bytes, Wi‑Fi Direct identity frame): the OS device
 * name first, then the legacy Bluetooth name, then the adapter name, and the
 * hardware model code ("M2101K6G"-class) only as the LAST resort — raw model
 * codes make two phones indistinguishable in peer lists and chat titles.
 */
object DeviceNameResolver {
    fun resolve(context: Context): String {
        val resolver = context.contentResolver
        val fromSettings = runCatching {
            Settings.Global.getString(resolver, "device_name")
        }.getOrNull()
        if (!fromSettings.isNullOrBlank()) return fromSettings
        val fromSecure = runCatching {
            Settings.Secure.getString(resolver, "bluetooth_name")
        }.getOrNull()
        if (!fromSecure.isNullOrBlank()) return fromSecure
        val fromAdapter = runCatching {
            BluetoothAdapter.getDefaultAdapter()?.name
        }.getOrNull()
        if (!fromAdapter.isNullOrBlank()) return fromAdapter
        return runCatching { Build.MODEL }.getOrNull().orEmpty()
    }
}
