/// GET /waivers/current and the acceptance it's checked against.
library;

class CurrentWaiver {
  final String id;
  final int version;
  final String title;
  final String body;
  CurrentWaiver({required this.id, required this.version, required this.title, required this.body});
  factory CurrentWaiver.fromJson(Map<String, dynamic> j) =>
      CurrentWaiver(id: j['id'] as String, version: j['version'] as int, title: j['title'] as String, body: j['body'] as String);
}
