package org.trailmesh.app.maps

import android.content.Intent
import android.view.View
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.trailmesh.app.MainActivity

@RunWith(AndroidJUnit4::class)
class ExploreLaunchTest {
    @Test
    fun launcherOpensExplore() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val launcher = requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName))
        assertEquals(MainActivity::class.java.name, launcher.component?.className)
        ActivityScenario.launch<MainActivity>(launcher.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)).use {
            it.onActivity { activity ->
                val titles = arrayListOf<View>()
                activity.window.decorView.findViewsWithText(titles, "Explore", View.FIND_VIEWS_WITH_TEXT)
                assertEquals(1, titles.size)
            }
        }
    }
}
