package io.github.hg552.esimmatrix

import org.json.JSONObject

/**
 * The decisions behind fetching Shizuku's installer, kept free of Android and
 * of the network so they can be tested as plain JVM code.
 *
 * Everything here is a trust decision: the bytes this resolves are handed to
 * the package installer. GitHub's release JSON is therefore only allowed to
 * name hosts we expect, and the result is still checked against a pinned signer
 * before it is offered for install.
 */
internal object ShizukuDownload {
    const val LATEST_RELEASE_API =
        "https://api.github.com/repos/RikkaApps/Shizuku/releases/latest"

    /** Last known good build; follows upstream only when someone bumps it. */
    const val PINNED_APK_URL =
        "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/" +
            "shizuku-v13.6.0.r1086.2650830c-release.apk"

    /**
     * Certificate SHA-256 of Rikka's release signer
     * (`CN=Rikka`, SHA-1 `2900b8e762737549d63c41056906b5cdaeef6e18`).
     * A downloaded APK that does not carry this signer is not Shizuku.
     */
    const val SIGNER_SHA256 =
        "268b5590e868fb08bae7e0ac413564cd1ff88f5ccff74af9dbd0dc918e30db30"

    /** Hosts the release metadata may point at, and that redirects may reach. */
    val ALLOWED_HOSTS: Set<String> =
        setOf(
            "github.com",
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
        )

    /** A downloaded body this small is an error page, not an installer. */
    const val MIN_APK_BYTES = 500_000L

    /** Nothing legitimate is this large; stop rather than fill the data partition. */
    const val MAX_APK_BYTES = 40_000_000L

    /** Whether [url] is HTTPS on a host this download is allowed to use. */
    fun isAllowedDownloadUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        if (!url.startsWith("https://")) return false
        val host =
            url.removePrefix("https://")
                .substringBefore('/')
                .substringBefore('?')
                .substringBefore('#')
                .substringAfter('@') // drop any userinfo the URL tried to carry
                .substringBefore(':') // drop a port
                .lowercase()
        return ALLOWED_HOSTS.contains(host)
    }

    /** The first downloadable `.apk` asset in a release body, or null. */
    fun apkUrlFromReleaseJson(body: String): String? {
        val assets = JSONObject(body).optJSONArray("assets") ?: return null
        for (index in 0 until assets.length()) {
            val asset = assets.optJSONObject(index) ?: continue
            if (!asset.optString("name").endsWith(".apk")) continue
            val url = asset.optString("browser_download_url")
            if (isAllowedDownloadUrl(url)) return url
        }
        return null
    }

    /**
     * Sources to try in order: the release the API named first, the pin second.
     *
     * A URL that is missing, blank, not HTTPS, or not on an allowed host is
     * dropped rather than tried.
     */
    fun candidateUrls(latest: String?): List<String> {
        val urls = mutableListOf<String>()
        if (isAllowedDownloadUrl(latest)) urls.add(latest!!)
        if (!urls.contains(PINNED_APK_URL)) urls.add(PINNED_APK_URL)
        return urls
    }

    /** Whether a body of [bytes] is a plausible size for an APK. */
    fun isPlausibleApk(bytes: Long): Boolean =
        bytes in MIN_APK_BYTES..MAX_APK_BYTES
}
