package io.github.hg552.esimmatrix

private val unsafeOriginCharacters = Regex("[\\p{Cc}\\p{Cf}]+")

/** Missing broadcast metadata stays unknown; never substitute the default SIM. */
internal data class SmsRelayOrigin(
    val subscriptionId: Int? = null,
    val slotIndex: Int? = null,
    val carrierName: String? = null,
) {
    val label: String = run {
        val sim = slotIndex?.takeIf { it >= 0 && it < Int.MAX_VALUE }
            ?.let { "SIM ${it + 1}" } ?: "SIM unknown"
        val subscription = subscriptionId?.takeIf { it >= 0 }?.let { " · subId $it" }.orEmpty()
        val carrier = carrierName?.replace(unsafeOriginCharacters, " ")?.trim()
            ?.take(128)?.trimEnd { Character.isHighSurrogate(it) }
            ?.takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty()
        "[$sim$subscription$carrier]"
    }
}
