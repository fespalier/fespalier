/// The roles Keycloak puts in an access token (since 0.9.0): `realm_access.roles`, plus
/// `resource_access.<clientId>.roles` for the app's own client. Keycloak keeps them in the access
/// token, not the ID token, unless a mapper adds them: both are read, and the union is returned.
///
/// ```dart
/// OidcBackend(..., roles: keycloakRoles('shop-app'))
/// ```
Set<String> Function(
  Map<String, Object?> accessClaims,
  Map<String, Object?> idClaims,
)
keycloakRoles(String clientId) =>
    (accessClaims, idClaims) => {
      ..._rolesIn(accessClaims, clientId),
      ..._rolesIn(idClaims, clientId),
    };

Set<String> _rolesIn(Map<String, Object?> claims, String clientId) {
  final roles = <String>{};
  final realm = claims['realm_access'];
  if (realm is Map<String, Object?>) roles.addAll(_strings(realm['roles']));
  final resources = claims['resource_access'];
  if (resources is Map<String, Object?>) {
    final mine = resources[clientId];
    if (mine is Map<String, Object?>) roles.addAll(_strings(mine['roles']));
  }
  return roles;
}

Iterable<String> _strings(Object? value) =>
    value is List<Object?> ? value.whereType<String>() : const <String>[];
