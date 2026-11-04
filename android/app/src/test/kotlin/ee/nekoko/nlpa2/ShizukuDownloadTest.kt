package ee.nekoko.nlpa2

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShizukuDownloadTest {
    @Test
    fun picksTheFirstApkAssetFromTheReleaseBody() {
        val body =
            """
            {
              "tag_name": "v13.6.0",
              "assets": [
                {"name": "checksums.txt", "browser_download_url": "https://example.test/sums"},
                {"name": "shizuku-release.apk", "browser_download_url": "https://example.test/shizuku.apk"},
                {"name": "shizuku-debug.apk", "browser_download_url": "https://example.test/debug.apk"}
              ]
            }
            """
        assertEquals(
            "https://example.test/shizuku.apk",
            ShizukuDownload.apkUrlFromReleaseJson(body),
        )
    }

    @Test
    fun ignoresAssetsThatAreNotDownloadableApks() {
        val body =
            """
            {
              "assets": [
                {"name": "notes.apk.txt", "browser_download_url": "https://example.test/notes"},
                {"name": "shizuku.apk", "browser_download_url": "http://example.test/insecure.apk"},
                {"name": "shizuku.apk", "browser_download_url": ""}
              ]
            }
            """
        assertNull(ShizukuDownload.apkUrlFromReleaseJson(body))
    }

    @Test
    fun toleratesAnAbsentOrUnrelatedReleaseBody() {
        assertNull(ShizukuDownload.apkUrlFromReleaseJson("{}"))
        assertNull(ShizukuDownload.apkUrlFromReleaseJson("""{"assets": []}"""))
    }

    @Test
    fun fallsBackToThePinWhenTheApiGivesNothing() {
        assertEquals(
            listOf(ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls(null),
        )
        assertEquals(
            listOf(ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls("   "),
        )
    }

    @Test
    fun triesTheLatestReleaseBeforeThePin() {
        val latest = "https://example.test/v14/shizuku.apk"
        assertEquals(
            listOf(latest, ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls(latest),
        )
    }

    @Test
    fun doesNotTryThePinnedUrlTwice() {
        assertEquals(
            listOf(ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls(ShizukuDownload.PINNED_APK_URL),
        )
    }

    @Test
    fun rejectsAnInsecureUrlFromTheApi() {
        assertEquals(
            listOf(ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls("http://example.test/shizuku.apk"),
        )
    }

    @Test
    fun rejectsBodiesTooSmallToBeAnInstaller() {
        // An HTML error page is a few kilobytes; the real APK is well over 2 MB.
        assertFalse(ShizukuDownload.isPlausibleApk(0))
        assertFalse(ShizukuDownload.isPlausibleApk(ShizukuDownload.MIN_APK_BYTES - 1))
        assertTrue(ShizukuDownload.isPlausibleApk(ShizukuDownload.MIN_APK_BYTES))
        assertTrue(ShizukuDownload.isPlausibleApk(2_571_773))
    }
}
