package com.mawqianow.location

import android.annotation.SuppressLint
import android.content.Context
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Raw GPS chip access via LocationManager.GPS_PROVIDER (no Wi-Fi / cell / fused
 * blending), plus live GNSS satellite status.
 */
class MainActivity : FlutterActivity() {
    private lateinit var lm: LocationManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var locListener: LocationListener? = null
    private var gnssCallback: GnssStatus.Callback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "mawqi/gps_info").setMethodCallHandler { call, result ->
            when (call.method) {
                "isGpsEnabled" -> result.success(lm.isProviderEnabled(LocationManager.GPS_PROVIDER))
                "hasGps" -> result.success(lm.allProviders.contains(LocationManager.GPS_PROVIDER))
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "mawqi/gps").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                start()
            }

            override fun onCancel(arguments: Any?) {
                stop()
                sink = null
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        stop()
        try {
            if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                sink?.error("GPS_DISABLED", "GPS provider disabled", null)
                return
            }
            lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.let {
                emitLocation(it, cached = true)
            }
            val l = object : LocationListener {
                override fun onLocationChanged(location: Location) = emitLocation(location, false)
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {
                    sink?.success(mapOf("type" to "disabled"))
                }
                @Deprecated("Deprecated in Java")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            }
            locListener = l
            // minTime 0 / minDistance 0 => every fix the chip produces (~1 Hz).
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0L, 0f, l, Looper.getMainLooper())

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val cb = object : GnssStatus.Callback() {
                    override fun onSatelliteStatusChanged(status: GnssStatus) = emitGnss(status)
                    override fun onStopped() {}
                }
                gnssCallback = cb
                lm.registerGnssStatusCallback(cb, main)
            }
        } catch (e: SecurityException) {
            sink?.error("NO_PERMISSION", e.message, null)
        } catch (e: Exception) {
            sink?.error("ERROR", e.message, null)
        }
    }

    private fun stop() {
        locListener?.let { lm.removeUpdates(it) }
        locListener = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            gnssCallback?.let { lm.unregisterGnssStatusCallback(it) }
        }
        gnssCallback = null
    }

    private fun emitLocation(loc: Location, cached: Boolean) {
        val m = hashMapOf<String, Any?>(
            "type" to "location",
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "acc" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
            "alt" to if (loc.hasAltitude()) loc.altitude else null,
            "speed" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
            "bearing" to if (loc.hasBearing()) loc.bearing.toDouble() else null,
            "time" to loc.time,
            "provider" to loc.provider,
            "cached" to cached,
            "mock" to if (Build.VERSION.SDK_INT >= 31) loc.isMock
                      else @Suppress("DEPRECATION") loc.isFromMockProvider,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && loc.hasVerticalAccuracy()) {
            m["vAcc"] = loc.verticalAccuracyMeters.toDouble()
        }
        loc.extras?.let { if (it.containsKey("satellites")) m["fixSats"] = it.getInt("satellites") }
        sink?.success(m)
    }

    private fun emitGnss(s: GnssStatus) {
        var used = 0
        var cn0Sum = 0f
        val consts = HashMap<String, IntArray>() // name -> [visible, used]
        for (i in 0 until s.satelliteCount) {
            val name = when (s.getConstellationType(i)) {
                GnssStatus.CONSTELLATION_GPS -> "GPS"
                GnssStatus.CONSTELLATION_GLONASS -> "GLONASS"
                GnssStatus.CONSTELLATION_GALILEO -> "Galileo"
                GnssStatus.CONSTELLATION_BEIDOU -> "BeiDou"
                GnssStatus.CONSTELLATION_QZSS -> "QZSS"
                GnssStatus.CONSTELLATION_SBAS -> "SBAS"
                else -> "Other"
            }
            val a = consts.getOrPut(name) { intArrayOf(0, 0) }
            a[0]++
            if (s.usedInFix(i)) {
                used++
                a[1]++
                cn0Sum += s.getCn0DbHz(i)
            }
        }
        sink?.success(
            mapOf(
                "type" to "gnss",
                "visible" to s.satelliteCount,
                "used" to used,
                "avgCn0" to if (used > 0) (cn0Sum / used).toDouble() else 0.0,
                "constellations" to consts.mapValues { listOf(it.value[0], it.value[1]) },
            )
        )
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }
}
