class Provider {
  String service;
  String? clientId;
  String? clientSecret;
  String? apiKey;
  List<String>? permissions;

  Provider({
    required this.service,
    this.clientId,
    this.clientSecret,
    this.apiKey,
    this.permissions,
  });

  factory Provider.fromDbMap(Map<String, dynamic> map) {
    final permissionsStr = map['permissions'] as String? ?? '';
    return Provider(
      service: map['service'] as String,
      clientId: map['client_id'] as String?,
      clientSecret: map['client_secret'] as String?,
      apiKey: map['api_key'] as String?,
      permissions: permissionsStr.isEmpty ? [] : permissionsStr.split(','),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'service': service,
      'client_id': clientId,
      'client_secret': clientSecret,
      'api_key': apiKey,
      'permissions': (permissions ?? []).join(','),
    };
  }
}
