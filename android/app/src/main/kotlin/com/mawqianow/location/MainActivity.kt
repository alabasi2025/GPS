package com.mawqianow.location

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import com.google.android.gms.location.DeviceOrientation
import com.google.android.gms.location.DeviceOrientationListener
import com.google.android.gms.location.DeviceOrientationRequest
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.FusedOrientationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Native positioning engine:
 *  - Google Fused Location (GPS + Wi-Fi + cell + sensors) for the initial precise fix
 *  - Raw GNSS chip (GPS_PROVIDER) + satellite status
 *  - Pedestrian Dead Reckoning sensors: step detection (accelerometer, adaptive
 *    peak/valley threshold), Weinberg step-length term, heading from Google Fused
 *    Orientation Provider (true north) with Rotation-Vector + declination fallback
 *  - APK self-install for the in-app updater
 */
class MainActivity : FlutterActivity() {
    private lateinit var lm: LocationManager
    private lateinit var sm: SensorManager
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }
    private var sink: EventChannel.EventSink? = null

    private var fused: FusedLocationProviderClient? = null
    private var fusedCb: LocationCallback? = null
    private var gpsListener: LocationListener? = null
    private var gnssCb: GnssStatus.Callback? = null
    private var fop: FusedOrientationProviderClient? = null
    private var fopListener: DeviceOrientationListener? = null
    private var sensorListener: SensorEventListener? = null

    // heading state
    private var headingDeg = Double.NaN
    private var headingErrDeg = 15.0
    private var headingSource = "none"
    private var declination = 0f
    private var lastHeadingEmit = 0L

    // step detector state
    private var gravity = DoubleArray(3)
    private var gInit = false
    private var smooth = 0.0
    private var prevSmooth = 0.0
    private var prevPrevSmooth = 0.0
    private var valley = 0.0
    private var lastStepNs = 0L
    private val recentDelta = ArrayDeque<Double>()
    private var stepSin = 0.0
    private var stepCos = 0.0
    private var stepCount = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "mawqi/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "isGpsEnabled" -> result.success(lm.isProviderEnabled(LocationManager.GPS_PROVIDER))
                "appVersion" -> result.success(appVersion())
                "sensorInfo" -> result.success(
                    mapOf(
                        "accelerometer" to (sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null),
                        "gyroscope" to (sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null),
                        "magnetometer" to (sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD) != null),
                        "rotationVector" to (sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) != null),
                    )
                )
                "installApk" -> result.success(installApk(call.argument<String>("path") ?: ""))
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "mawqi/stream").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                startAll()
            }

            override fun onCancel(arguments: Any?) {
                stopAll()
                sink = null
            }
        })
    }

    private fun emit(m: Map<String, Any?>) {
        main.post { sink?.success(m) }
    }

    // ------------------------------------------------------------------ location
    @SuppressLint("MissingPermission")
    private fun startAll() {
        stopAll()
        try {
            if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER) &&
                !lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            ) {
                main.post { sink?.error("GPS_DISABLED", "Location disabled", null) }
                return
            }
            // 1) Google Fused Location (high accuracy, 1 Hz)
            try {
                val c = LocationServices.getFusedLocationProviderClient(this)
                val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
                    .setMinUpdateIntervalMillis(500L)
                    .setWaitForAccurateLocation(false)
                    .build()
                val cb = object : LocationCallback() {
                    override fun onLocationResult(r: LocationResult) {
                        r.locations.forEach { emitLocation(it, "fused") }
                    }
                }
                c.requestLocationUpdates(req, cb, Looper.getMainLooper())
                fused = c
                fusedCb = cb
                c.lastLocation.addOnSuccessListener { it?.let { l -> emitLocation(l, "fused", cached = true) } }
            } catch (_: Throwable) {
                // No Google Play services -> raw GPS only
            }

            // 2) Raw GNSS chip
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                val l = object : LocationListener {
                    override fun onLocationChanged(location: Location) = emitLocation(location, "gps")
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {
                        emit(mapOf("type" to "disabled"))
                    }
                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                }
                gpsListener = l
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0L, 0f, l, Looper.getMainLooper())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    val cb = object : GnssStatus.Callback() {
                        override fun onSatelliteStatusChanged(status: GnssStatus) = emitGnss(status)
                    }
                    gnssCb = cb
                    lm.registerGnssStatusCallback(cb, main)
                }
            }
        } catch (e: SecurityException) {
            main.post { sink?.error("NO_PERMISSION", e.message, null) }
            return
        } catch (e: Exception) {
            main.post { sink?.error("ERROR", e.message, null) }
            return
        }
        startHeading()
        startStepDetector()
    }

    private fun stopAll() {
        try { fusedCb?.let { fused?.removeLocationUpdates(it) } } catch (_: Throwable) {}
        fusedCb = null
        gpsListener?.let { lm.removeUpdates(it) }
        gpsListener = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) gnssCb?.let { lm.unregisterGnssStatusCallback(it) }
        gnssCb = null
        try { fopListener?.let { fop?.removeOrientationUpdates(it) } } catch (_: Throwable) {}
        fopListener = null
        sensorListener?.let { sm.unregisterListener(it) }
        sensorListener = null
        rvListener?.let { sm.unregisterListener(it) }
        rvListener = null
    }

    private fun emitLocation(loc: Location, source: String, cached: Boolean = false) {
        declination = GeomagneticField(
            loc.latitude.toFloat(), loc.longitude.toFloat(), loc.altitude.toFloat(), System.currentTimeMillis()
        ).declination
        val m = hashMapOf<String, Any?>(
            "type" to "fix",
            "source" to source,
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "acc" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else 50.0,
            "alt" to if (loc.hasAltitude()) loc.altitude else null,
            "speed" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
            "time" to loc.time,
            "cached" to cached,
            "mock" to if (Build.VERSION.SDK_INT >= 31) loc.isMock else @Suppress("DEPRECATION") loc.isFromMockProvider,
        )
        emit(m)
    }

    private fun emitGnss(s: GnssStatus) {
        var used = 0
        var cn0 = 0f
        val consts = HashMap<String, IntArray>()
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
            if (s.usedInFix(i)) { used++; a[1]++; cn0 += s.getCn0DbHz(i) }
        }
        emit(
            mapOf(
                "type" to "gnss",
                "visible" to s.satelliteCount,
                "used" to used,
                "avgCn0" to if (used > 0) (cn0 / used).toDouble() else 0.0,
                "constellations" to consts.mapValues { listOf(it.value[0], it.value[1]) },
            )
        )
    }

    // ------------------------------------------------------------------ heading
    private fun startHeading() {
        // Preferred: Google Fused Orientation Provider (true-north heading + error estimate)
        try {
            val client = LocationServices.getFusedOrientationProviderClient(this)
            val listener = DeviceOrientationListener { o: DeviceOrientation ->
                headingDeg = o.headingDegrees.toDouble()
                headingErrDeg = o.headingErrorDegrees.toDouble().coerceIn(1.0, 180.0)
                headingSource = "google"
                onHeading()
            }
            val req = DeviceOrientationRequest.Builder(DeviceOrientationRequest.OUTPUT_PERIOD_DEFAULT).build()
            client.requestOrientationUpdates(req, mainExecutor, listener)
                .addOnFailureListener { startRotationVectorHeading() }
            fop = client
            fopListener = listener
        } catch (_: Throwable) {
            startRotationVectorHeading()
        }
    }

    private var rvListener: SensorEventListener? = null
    private fun startRotationVectorHeading() {
        if (rvListener != null) return
        val rv = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
        val rot = FloatArray(9)
        val ori = FloatArray(3)
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rot, e.values)
                SensorManager.getOrientation(rot, ori)
                var h = Math.toDegrees(ori[0].toDouble()) + declination
                h = (h + 360.0) % 360.0
                headingDeg = h
                // values[4] = estimated heading accuracy (radians) when provided
                headingErrDeg = if (e.values.size > 4 && e.values[4] > 0f)
                    Math.toDegrees(e.values[4].toDouble()).coerceIn(2.0, 180.0) else 12.0
                headingSource = "rotation_vector"
                onHeading()
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        rvListener = l
        sm.registerListener(l, rv, SensorManager.SENSOR_DELAY_GAME)
    }

    private fun onHeading() {
        if (headingDeg.isNaN()) return
        val r = Math.toRadians(headingDeg)
        stepSin += sin(r); stepCos += cos(r)
        val now = System.currentTimeMillis()
        if (now - lastHeadingEmit > 200) {
            lastHeadingEmit = now
            emit(mapOf("type" to "heading", "deg" to headingDeg, "err" to headingErrDeg, "src" to headingSource))
        }
    }

    // ------------------------------------------------------------------ steps (PDR)
    private fun startStepDetector() {
        val acc = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) = onAccel(e)
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        sensorListener = l
        sm.registerListener(l, acc, SensorManager.SENSOR_DELAY_GAME) // ~50 Hz
    }

    /**
     * Step detection: gravity-removed vertical acceleration (projection on the
     * gravity vector), low-passed (~3 Hz), peak detection with adaptive
     * peak-valley threshold  Δ ≥ max(Δmin, 0.5·mean(recent Δ)) and a step period
     * in [0.25 s, 2.0 s]. Emits the Weinberg term w = Δ^(1/4); the Dart side
     * applies the calibrated coefficient K (L = K·w).
     */
    private fun onAccel(e: SensorEvent) {
        val x = e.values[0].toDouble(); val y = e.values[1].toDouble(); val z = e.values[2].toDouble()
        val a = 0.9
        if (!gInit) { gravity = doubleArrayOf(x, y, z); gInit = true }
        gravity[0] = a * gravity[0] + (1 - a) * x
        gravity[1] = a * gravity[1] + (1 - a) * y
        gravity[2] = a * gravity[2] + (1 - a) * z
        val gn = sqrt(gravity[0] * gravity[0] + gravity[1] * gravity[1] + gravity[2] * gravity[2])
        if (gn < 1e-3) return
        val vert = ((x - gravity[0]) * gravity[0] + (y - gravity[1]) * gravity[1] + (z - gravity[2]) * gravity[2]) / gn

        prevPrevSmooth = prevSmooth
        prevSmooth = smooth
        smooth = 0.7 * smooth + 0.3 * vert

        // track valley
        if (prevSmooth < prevPrevSmooth && prevSmooth <= smooth) {
            valley = if (lastStepNs == 0L || prevSmooth < valley) prevSmooth else valley
        }
        // local maximum
        if (prevSmooth > prevPrevSmooth && prevSmooth >= smooth && prevSmooth > 0.3) {
            val t = e.timestamp
            val dt = (t - lastStepNs) / 1e9
            val delta = prevSmooth - valley
            val meanRecent = if (recentDelta.isEmpty()) 0.0 else recentDelta.average()
            val thr = max(1.0, 0.5 * meanRecent)
            if (delta >= thr && (lastStepNs == 0L || dt >= 0.25)) {
                if (recentDelta.size >= 8) recentDelta.removeFirst()
                recentDelta.addLast(delta)
                val validCadence = lastStepNs != 0L && dt <= 2.0
                lastStepNs = t
                valley = prevSmooth
                if (validCadence || stepCount == 0L) {
                    stepCount++
                    val h = if (stepSin == 0.0 && stepCos == 0.0) headingDeg
                            else (Math.toDegrees(atan2(stepSin, stepCos)) + 360.0) % 360.0
                    stepSin = 0.0; stepCos = 0.0
                    if (!h.isNaN()) {
                        emit(
                            mapOf(
                                "type" to "step",
                                "w" to delta.pow(0.25),
                                "delta" to delta,
                                "dt" to if (validCadence) dt else 0.0,
                                "heading" to h,
                                "headingErr" to headingErrDeg,
                                "headingSrc" to headingSource,
                                "count" to stepCount,
                            )
                        )
                    }
                }
            }
        }
        // reset valley after long pause
        if (lastStepNs != 0L && (e.timestamp - lastStepNs) / 1e9 > 2.0 && abs(smooth) < 0.2) {
            valley = smooth
        }
    }

    // ------------------------------------------------------------------ updater
    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "0"
    } catch (_: Exception) { "0" }

    private fun installApk(path: String): String {
        val f = File(path)
        if (!f.exists()) return "missing"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return "need_permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", f)
        val i = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
        return "ok"
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
}
