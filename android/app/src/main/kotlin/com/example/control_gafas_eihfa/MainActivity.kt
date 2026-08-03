package com.example.control_gafas_eihfa

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "com.example.control_gafas_eihfa/permissions"
	private val REQUEST_CODE = 1001
	private var pendingResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"requestPermissions" -> {
					pendingResult = result
					requestPermissions()
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun requestPermissions() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
			pendingResult?.success(true)
			pendingResult = null
			return
		}

		val perms = mutableListOf<String>()

		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
			perms.add(Manifest.permission.BLUETOOTH_SCAN)
			perms.add(Manifest.permission.BLUETOOTH_CONNECT)
			perms.add(Manifest.permission.BLUETOOTH_ADVERTISE)
		} else {
			// For older Android versions, location may be needed for BLE scans
			perms.add(Manifest.permission.ACCESS_FINE_LOCATION)
		}

		val toRequest = perms.filter {
			ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
		}

		if (toRequest.isEmpty()) {
			pendingResult?.success(true)
			pendingResult = null
			return
		}

		ActivityCompat.requestPermissions(this, toRequest.toTypedArray(), REQUEST_CODE)
	}

	override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode != REQUEST_CODE) return

		val allGranted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
		pendingResult?.success(allGranted)
		pendingResult = null
	}
}
