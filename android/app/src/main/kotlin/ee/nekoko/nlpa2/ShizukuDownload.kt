package ee.nekoko.nlpa2

import org.json.JSONObject

/**
 * The decisions behind fetching Shizuku's installer, kept free of Android and
 * of the network so they can be tested as plain JVM code.
 *
 * Only one thing here can silently rot: GitHub's release JSON. The pin below is
 * the fallback for the day that shape changes or the API is rate limited.
 */
internal object ShizukuDownload {
    const val LATEST_RELEASE_API =
        "https://api.github.com/repos/RikkaApps/Shizuku/releases/latest"

    /** Last known good build; follows upstream only when someone bumps it. */
    const val PINNED_APK_URL =
        "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/" +
            "shizuku-v13.6.0.r1086.2650830c-release.apk"

    /** A downloaded body this small is an error page, not an installer. */
    const val MIN_APK_BYTES = 500_000L

    /** The first downloadable `.apk` asset in a release body, or null. */
    fun apkUrlFromReleaseJson(body: String): String? {
        val assets = JSONObject(body).optJSONArray("assets") ?: return null
        for (index in 0 until assets.length()) {
            val asset = assets.optJSONObject(index) ?: continue
            if (!asset.optString("name").endsWith(".apk")) continue
            val url = asset.optString("browser_download_url")
            if (url.startsWith("https://")) return url
        }
        return null
    }

    /**
     * Sources to try in order: the release the API named first, the pin second.
     *
     * A URL that is missing, blank, or not HTTPS is dropped rather than tried —
     * this download ends up handed to the package installer.
     */
    fun candidateUrls(latest: String?): List<String> {
        val urls = mutableListOf<String>()
        if (!latest.isNullOrBlank() && latest.startsWith("https://")) urls.add(latest)
        if (!urls.contains(PINNED_APK_URL)) urls.add(PINNED_APK_URL)
        return urls
    }

    /** Whether a body of [bytes] is large enough to be an APK at all. */
    fun isPlausibleApk(bytes: Long): Boolean = bytes >= MIN_APK_BYTES
}
