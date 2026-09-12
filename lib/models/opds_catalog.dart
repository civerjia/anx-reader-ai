/// An OPDS catalog the reader has added: a Calibre-Web, Komga, Kavita or any
/// other server that publishes its books as an OPDS feed.
class OpdsCatalog {
  const OpdsCatalog({
    required this.id,
    required this.title,
    required this.url,
    this.username = '',
    this.password = '',
  });

  final String id;
  final String title;
  final String url;

  /// Self-hosted servers usually sit behind HTTP Basic authentication.
  final String username;
  final String password;

  bool get hasCredentials => username.isNotEmpty;

  OpdsCatalog copyWith({
    String? title,
    String? url,
    String? username,
    String? password,
  }) =>
      OpdsCatalog(
        id: id,
        title: title ?? this.title,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'username': username,
        'password': password,
      };

  factory OpdsCatalog.fromJson(Map<String, dynamic> json) => OpdsCatalog(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );
}
