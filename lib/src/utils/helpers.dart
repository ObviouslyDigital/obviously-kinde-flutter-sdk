bool isSafeWebUrl(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null || !uri.isAbsolute) return false;

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;

  if (uri.host.isEmpty) return false;

  return true;
}

/// The URL web logout navigates to: Kinde's logout endpoint, which ends the
/// Kinde session and then redirects to [logoutRedirectUri], or
/// [logoutRedirectUri] directly when the session is kept.
String webLogoutUrl({
  required String endSessionEndpoint,
  required String logoutRedirectUri,
  required bool endSession,
}) {
  if (!endSession) return logoutRedirectUri;

  return Uri.parse(
    endSessionEndpoint,
  ).replace(queryParameters: {'redirect': logoutRedirectUri}).toString();
}
