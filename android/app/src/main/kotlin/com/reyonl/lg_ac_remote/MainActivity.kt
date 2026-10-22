package com.reyonl.lg_ac_remote

import android.content.Context
import android.hardware.ConsumerIrManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Drives the phone's IR blaster directly via ConsumerIrManager.
//
// Exposed over the `lg_ac_remote/ir` method channel:
//   hasIrEmitter        -> bool
//   carrierFrequencies  -> List<int>  (min/max Hz pairs, flattened)
//   transmit            -> "ok"       (args: { frequency: int, pattern: List<int> })
class MainActivity : FlutterActivity() {
    private val channel = "lg_ac_remote/ir"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                val cir = getSystemService(Context.CONSUMER_IR_SERVICE)
                    as? ConsumerIrManager
                if (cir == null) {
                    // No IR hardware at all; answer the probes honestly rather
                    // than throwing, so the UI can show its "no blaster" state.
                    when (call.method) {
                        "hasIrEmitter" -> result.success(false)
                        "carrierFrequencies" -> result.success(emptyList<Int>())
                        else -> result.error(
                            "NO_IR_HARDWARE",
                            "This device has no IR blaster.",
                            null,
                        )
                    }
                    return@setMethodCallHandler
                }

                when (call.method) {
                    "hasIrEmitter" -> result.success(cir.hasIrEmitter())

                    "carrierFrequencies" -> {
                        val ranges = cir.carrierFrequencies
                        val flat = ArrayList<Int>(ranges.size * 2)
                        for (r in ranges) {
                            flat.add(r.minFrequency)
                            flat.add(r.maxFrequency)
                        }
                        result.success(flat)
                    }

                    "transmit" -> {
                        val frequency = call.argument<Int>("frequency") ?: 38028
                        val pattern = call.argument<List<Int>>("pattern")
                        if (pattern == null || pattern.isEmpty()) {
                            result.error(
                                "BAD_PATTERN",
                                "pattern must be a non-empty List<int>",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        if (!cir.hasIrEmitter()) {
                            result.error(
                                "NO_IR_EMITTER",
                                "IR emitter reports hasIrEmitter() == false.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            cir.transmit(frequency, pattern.toIntArray())
                            result.success("ok")
                        } catch (e: SecurityException) {
                            result.error(
                                "NO_PERMISSION",
                                "TRANSMIT_IR permission denied.",
                                e.message,
                            )
                        } catch (e: IllegalArgumentException) {
                            result.error(
                                "BAD_PATTERN",
                                "Pattern rejected by ConsumerIrManager: ${e.message}",
                                null,
                            )
                        } catch (e: Exception) {
                            result.error("TRANSMIT_FAILED", e.toString(), null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}