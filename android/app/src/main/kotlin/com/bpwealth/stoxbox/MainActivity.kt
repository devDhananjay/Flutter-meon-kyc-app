package com.bpwealth.stoxbox

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val paymentChannel = "com.bpwealth.stoxbox/payment"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, paymentChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchIntentUrl" -> {
                        val intentUrl = call.argument<String>("intentUrl")
                        if (intentUrl.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(launchParsedIntentUrl(intentUrl))
                    }
                    "launchUpi" -> {
                        val dataUri = call.argument<String>("dataUri")
                        val packageName = call.argument<String>("packageName")
                        if (dataUri.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(launchPaymentDataUri(dataUri, packageName))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Chrome-style handling for `intent:upi://pay?...#Intent;package=...;end`. */
    private fun launchParsedIntentUrl(intentUrl: String): Boolean {
        return try {
            val intent = Intent.parseUri(intentUrl, Intent.URI_INTENT_SCHEME)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun launchPaymentDataUri(dataUri: String, packageName: String?): Boolean {
        val candidates = buildPaymentUriCandidates(dataUri, packageName)
        val gpayPackage = "com.google.android.apps.nbu.paisa.user"

        // App-specific schemes (tez/gpay) — launch without package first; routes to Google Pay.
        for (candidate in candidates) {
            val lower = candidate.lowercase()
            if (lower.startsWith("tez://") || lower.startsWith("gpay://") || lower.startsWith("googlepay://")) {
                if (tryLaunch(candidate, null)) return true
            }
        }

        // Explicit package (Digio intent) — try every URI variant with setPackage.
        if (!packageName.isNullOrBlank()) {
            for (candidate in candidates) {
                if (tryLaunch(candidate, packageName)) return true
            }
            // Older Google Pay package on some devices.
            if (packageName == gpayPackage) {
                for (candidate in candidates) {
                    if (tryLaunch(candidate, "com.google.android.apps.walletnfcrel")) return true
                }
            }
        }

        // Generic upi:// only when no target package was requested.
        if (packageName.isNullOrBlank()) {
            for (candidate in candidates) {
                if (candidate.lowercase().startsWith("upi://") && tryLaunch(candidate, null)) {
                    return true
                }
            }
        }

        return false
    }

    private fun tryLaunch(dataUri: String, packageName: String?): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(dataUri))
            if (!packageName.isNullOrBlank()) {
                intent.setPackage(packageName)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun buildPaymentUriCandidates(
        dataUri: String,
        packageName: String?,
    ): List<String> {
        val uris = linkedSetOf(dataUri)
        val gpayPackage = "com.google.android.apps.nbu.paisa.user"
        val isGpay = packageName == gpayPackage ||
            dataUri.lowercase().let { it.startsWith("tez://") || it.startsWith("gpay://") }

        if (isGpay) {
            if (dataUri.startsWith("upi://pay", ignoreCase = true)) {
                val suffix = dataUri.substring("upi://".length) // pay?ver=...
                uris.add("tez://upi/$suffix")
                uris.add("tez://$suffix")
                uris.add("gpay://upi/$suffix")
                uris.add("gpay://$suffix")
                uris.add("googlepay://upi/$suffix")
                uris.add("googlepay://$suffix")
            } else {
                val path = stripPaymentScheme(dataUri)
                if (path != null) {
                    uris.add("tez://upi/$path")
                    uris.add("tez://$path")
                    uris.add("gpay://upi/$path")
                    uris.add("gpay://$path")
                }
            }
        } else {
            val path = stripPaymentScheme(dataUri)
            if (path != null && packageName != null) {
                when {
                    packageName.contains("phonepe") -> uris.add("phonepe://$path")
                    packageName.contains("paytm") -> {
                        uris.add("paytmmp://$path")
                        uris.add("paytm://$path")
                    }
                }
            }
        }
        return uris.toList()
    }

    private fun stripPaymentScheme(uri: String): String? {
        val idx = uri.indexOf("://")
        if (idx < 0) return null
        return uri.substring(idx + 3)
    }
}
