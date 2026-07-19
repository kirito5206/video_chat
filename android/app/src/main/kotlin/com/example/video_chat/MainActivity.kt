package com.example.video_chat

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "video_chat/network_discovery",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getWifiNetwork") {
                result.success(getWifiNetwork())
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getWifiNetwork(): Map<String, Any>? {
        val manager = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
        val wifiNetwork = manager.allNetworks.firstOrNull { network ->
            manager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        } ?: return null
        val linkAddress = manager.getLinkProperties(wifiNetwork)
            ?.linkAddresses
            ?.firstOrNull { it.address is Inet4Address && !it.address.isLoopbackAddress }
            ?: return null
        return mapOf(
            "address" to (linkAddress.address.hostAddress ?: return null),
            "prefixLength" to linkAddress.prefixLength,
        )
    }
}
