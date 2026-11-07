package org.trailmesh.app

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/**
 * Development product entry point; map, report workflows and radio integration are later issues.
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(
            TextView(this).apply {
                text = "TrailMesh\nReport storage development build\nMore features are coming soon"
                textSize = 22f
                gravity = android.view.Gravity.CENTER
                setPadding(24, 24, 24, 24)
            },
        )
    }
}
