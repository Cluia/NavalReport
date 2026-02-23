class Port {
  final String portCode;
  final String description;
  final double lat;
  final double lon;
  final double zoom;

  Port({
    required this.portCode,
    required this.description,
    required this.lat,
    required this.lon,
    required this.zoom,
  });

  factory Port.fromJson(Map<String, dynamic> json) {
    return Port(
      portCode: json['port_code'],
      description: json['viewpoint_desc'],
      lat: json['lat'].toDouble(),
      lon: json['lon'].toDouble(),
      zoom: json['zoom'].toDouble(),
    );
  }
}