/// Returns whether [address] is a usable GSMA notification-server FQDN.
///
/// Notification metadata comes from the eUICC. Some cards return damaged
/// metadata from ListNotification even though RetrieveNotificationsList still
/// contains the intact signed notification. Keep this check strict so callers
/// can fall back to that authoritative copy instead of attempting a request to
/// a malformed host.
bool isValidNotificationAddress(String? address) {
  if (address == null || address.isEmpty || address != address.trim()) {
    return false;
  }

  if (address.length > 253 || address.codeUnits.any((b) => b > 0x7f)) {
    return false;
  }

  final fqdn = address.endsWith('.')
      ? address.substring(0, address.length - 1)
      : address;
  final labels = fqdn.split('.');
  if (labels.length < 2) return false;

  final labelPattern = RegExp(r'^[A-Za-z0-9-]+$');
  for (final label in labels) {
    if (label.isEmpty ||
        label.length > 63 ||
        label.startsWith('-') ||
        label.endsWith('-') ||
        !labelPattern.hasMatch(label)) {
      return false;
    }
  }

  final topLevelLabel = labels.last;
  return RegExp(r'^[A-Za-z][A-Za-z0-9-]*$').hasMatch(topLevelLabel);
}
