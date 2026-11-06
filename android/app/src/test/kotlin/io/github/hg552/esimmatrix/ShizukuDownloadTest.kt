package io.github.hg552.esimmatrix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShizukuDownloadTest {
    private val apkUrl = "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/app.apk"

    @Test
    fun picksTheFirstApkAssetFromTheReleaseBody() {
        val body =
            """
            {
              "tag_name": "v13.6.0",
              "assets": [
                {"name": "checksums.txt", "browser_download_url": "https://github.com/x/sums"},
                {"name": "shizuku-release.apk", "browser_download_url": "$apkUrl"},
                {"name": "shizuku-debug.apk", "browser_download_url": "https://github.com/x/debug.apk"}
              ]
            }
            """
        assertEquals(apkUrl, ShizukuDownload.apkUrlFromReleaseJson(body))
    }

    @Test
    fun ignoresAssetsThatAreNotDownloadableApks() {
        val body =
            """
            {
              "assets": [
                {"name": "notes.apk.txt", "browser_download_url": "https://github.com/x/notes"},
                {"name": "shizuku.apk", "browser_download_url": "http://github.com/x/insecure.apk"},
                {"name": "shizuku.apk", "browser_download_url": ""}
              ]
            }
            """
        assertNull(ShizukuDownload.apkUrlFromReleaseJson(body))
    }

    @Test
    fun refusesAnApkHostedSomewhereElse() {
        // The release body is data, not authority: a compromised or replaced
        // asset must not be able to point the installer at an arbitrary host.
        val body =
            """
            {
              "assets": [
                {"name": "shizuku.apk", "browser_download_url": "https://evil.example/shizuku.apk"}
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
        assertEquals(
            listOf(apkUrl, ShizukuDownload.PINNED_APK_URL),
            ShizukuDownload.candidateUrls(apkUrl),
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
    fun rejectsInsecureOrForeignUrlsFromTheApi() {
        listOf(
            "http://github.com/shizuku.apk",
            "https://evil.example/shizuku.apk",
            "https://github.com.evil.example/shizuku.apk",
            "https://user@evil.example/shizuku.apk",
        ).forEach { url ->
            assertEquals(
                "candidate list for $url",
                listOf(ShizukuDownload.PINNED_APK_URL),
                ShizukuDownload.candidateUrls(url),
            )
        }
    }

    @Test
    fun acceptsTheHostsGithubActuallyRedirectsTo() {
        listOf(
            "https://github.com/a/b.apk",
            "https://objects.githubusercontent.com/a/b.apk?sig=1",
            "https://release-assets.githubusercontent.com/a/b.apk",
        ).forEach { url ->
            assertTrue("should accept $url", ShizukuDownload.isAllowedDownloadUrl(url))
        }
    }

    @Test
    fun rejectsBodiesOutsideThePlausibleApkRange() {
        // An HTML error page is a few kilobytes; the real APK is over 2 MB.
        assertFalse(ShizukuDownload.isPlausibleApk(0))
        assertFalse(ShizukuDownload.isPlausibleApk(ShizukuDownload.MIN_APK_BYTES - 1))
        assertTrue(ShizukuDownload.isPlausibleApk(ShizukuDownload.MIN_APK_BYTES))
        assertTrue(ShizukuDownload.isPlausibleApk(2_571_773))
        // Nothing legitimate is this large; the download aborts instead of
        // filling the data partition.
        assertFalse(ShizukuDownload.isPlausibleApk(ShizukuDownload.MAX_APK_BYTES + 1))
    }

    @Test
    fun pinsTheReleaseSigner() {
        // 32 bytes of SHA-256, lowercase hex; the value the installer compares
        // the downloaded APK against.
        assertEquals(64, ShizukuDownload.SIGNER_SHA256.length)
        assertTrue(
            ShizukuDownload.SIGNER_SHA256.all { it in '0'..'9' || it in 'a'..'f' },
        )
    }
}
