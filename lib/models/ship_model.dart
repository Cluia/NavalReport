import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math; // IMPORTANTE PARA A MATEMÁTICA DA ESCALA
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class Ship {
  final String portCode;
  final int mmsi;
  final double lat;
  final double lon;
  final String vesselName;
  final String vesselTypeDesc;
  final double sog;
  final double? cog;
  final double? head;
  final String dest;
  final String eta;
  final double? draught;
  final ShipStyle style;
  final int dimBow;
  final int dimStern;
  final int dimPort;
  final int dimStarboard;
  final DateTime? lastUpdate;

  static final Map<String, BitmapDescriptor> _iconCache = {};

  Ship({
    required this.portCode,
    required this.mmsi,
    required this.lat,
    required this.lon,
    required this.vesselName,
    required this.vesselTypeDesc,
    required this.sog,
    this.cog,
    this.head,
    required this.dest,
    required this.eta,
    this.draught,
    required this.style,
    required this.dimBow,
    required this.dimStern,
    required this.dimPort,
    required this.dimStarboard,
    this.lastUpdate,
  });

  // --- FUNÇÕES DE SEGURANÇA PARA DADOS CORROMPIDOS ---
  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
  // ----------------------------------------------------

  factory Ship.fromJson(Map<String, dynamic> json) {
    DateTime? parsedDate;
    var rawTime = json['tstamp'] ?? json['timestamp'] ?? json['last_update'] ?? json['ts'];
    
    if (rawTime != null) {
      int? unixTime = int.tryParse(rawTime.toString());
      if (unixTime != null) {
        parsedDate = DateTime.fromMillisecondsSinceEpoch(unixTime * 1000);
      } else {
        parsedDate = DateTime.tryParse(rawTime.toString());
      }
    }

    return Ship(
      portCode: json['port_code']?.toString() ?? '',
      mmsi: _parseInt(json['mmsi']), // Uso seguro de números
      lat: _parseDouble(json['lat']), // Uso seguro de números
      lon: _parseDouble(json['lon']), // Uso seguro de números
      vesselName: json['vessel_name'] == "- ? -" || json['vessel_name'] == null 
          ? "Desconhecido" 
          : json['vessel_name'].toString(),
      vesselTypeDesc: json['vesseltype_desc']?.toString() ?? 'Outros',
      sog: _parseDouble(json['sog']),
      cog: json['cog'] != null ? _parseDouble(json['cog']) : null,
      head: json['head'] != null ? _parseDouble(json['head']) : null,
      dest: json['dest']?.toString() ?? 'N/A',
      eta: json['eta']?.toString() ?? '',
      draught: json['draught'] != null ? _parseDouble(json['draught']) : null,
      style: ShipStyle.fromJson(json['style'] ?? {}),
      dimBow: _parseInt(json['dimBow']),
      dimStern: _parseInt(json['dimStern']),
      dimPort: _parseInt(json['dimPort']),
      dimStarboard: _parseInt(json['dimStarboard']),
      lastUpdate: parsedDate,
    );
  }

  String get timeAgo {
    if (lastUpdate == null) return "Desconhecido";
    
    final now = DateTime.now();
    // O .abs() previne erros caso o satélite esteja uns minutos no "futuro"
    final difference = now.difference(lastUpdate!).abs();

    if (difference.inDays > 0) {
      return "Há ${difference.inDays} dia(s)";
    } else if (difference.inHours > 0) {
      return "Há ${difference.inHours} hora(s)";
    } else if (difference.inMinutes > 0) {
      return "Há ${difference.inMinutes} minuto(s)";
    } else {
      return "Agora mesmo";
    }
  }

  double get rotation => head ?? cog ?? 0.0;

  Offset get anchorOffset {
    final double length = (dimBow + dimStern).toDouble();
    final double width = (dimPort + dimStarboard).toDouble();
    
    if (length == 0 || width == 0) return const Offset(0.5, 0.5);
    
    return Offset(dimPort / width, dimBow / length);
  }

  double _getHue() {
    if (vesselTypeDesc.contains("Tanker")) return BitmapDescriptor.hueRed;
    if (vesselTypeDesc.contains("Cargo")) return BitmapDescriptor.hueGreen;
    if (vesselTypeDesc.contains("Tug") || vesselTypeDesc.contains("Towing")) return BitmapDescriptor.hueAzure;
    if (vesselTypeDesc.contains("Passenger")) return BitmapDescriptor.hueBlue;
    if (vesselTypeDesc.contains("Fishing")) return BitmapDescriptor.hueOrange;
    return BitmapDescriptor.hueYellow;
  }

  Future<BitmapDescriptor> getMarkerIcon(double currentZoom) async {
    // Zoom distante: pino simples
    if (currentZoom < 12.0) {
      return BitmapDescriptor.defaultMarkerWithHue(_getHue());
    }

    double rawLength = (dimBow + dimStern).toDouble();
    double rawWidth = (dimPort + dimStarboard).toDouble();

    if (rawLength < 10 || rawWidth < 2) {
      rawLength = 40;
      rawWidth = 15;
    }

    // Escala em metros reais
    double metersPerPx = 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, currentZoom);
    double height = (rawLength / metersPerPx).clamp(12.0, 180.0);
    double width = (rawWidth / metersPerPx).clamp(4.0, 60.0);

    // MÁGICA 1: Arredondar rotação de 10 em 10 graus (salva muita memória)
    int roundedRotation = ((rotation + 5) ~/ 10) * 10;
    if (roundedRotation == 360) roundedRotation = 0;

    // Chave de Cache agora inclui o ângulo de rotação
    String cacheKey = "${style.fillColor.value}_${height.toInt()}_${width.toInt()}_$roundedRotation";

    if (_iconCache.containsKey(cacheKey)) {
      return _iconCache[cacheKey]!;
    }

    // MÁGICA 2: Canvas quadrado usando a diagonal máxima para o barco não ser cortado ao girar
    final double diagonal = math.sqrt(width * width + height * height);
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    // Gira o "papel" a partir do centro
    final double center = diagonal / 2;
    canvas.translate(center, center); // Vai pro meio
    canvas.rotate(roundedRotation * math.pi / 180); // Gira o papel
    canvas.translate(-width / 2, -height / 2); // Volta pra desenhar o barco centralizado

    // Desenha o barco
    final Paint fillPaint = Paint()..color = style.fillColor.withOpacity(0.9)..style = PaintingStyle.fill;
    final Paint strokePaint = Paint()..color = style.strokeColor..strokeWidth = 1.0..style = PaintingStyle.stroke;

    final Path path = Path();
    final double bowHeight = height * 0.25;
    path.moveTo(width / 2, 0); 
    path.lineTo(width, bowHeight); 
    path.lineTo(width, height); 
    path.lineTo(0, height); 
    path.lineTo(0, bowHeight); 
    path.close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);

    // Exporta a imagem com o tamanho da diagonal
    final ui.Image image = await pictureRecorder.endRecording().toImage(diagonal.toInt(), diagonal.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List uint8List = byteData!.buffer.asUint8List();

    final BitmapDescriptor customIcon = BitmapDescriptor.fromBytes(uint8List);
    _iconCache[cacheKey] = customIcon;

    return customIcon;
  }
}

// ... a classe ShipStyle continua igual no final do arquivo ...
class ShipStyle {
  final Color fillColor;
  final Color strokeColor;

  ShipStyle({required this.fillColor, required this.strokeColor});

  factory ShipStyle.fromJson(Map<String, dynamic> json) {
    Color parseHex(String hex) {
      hex = hex.replaceFirst('#', '');
      if (hex.length == 8) {
        hex = hex.substring(6, 8) + hex.substring(0, 6);
      }
      return Color(int.tryParse("0x$hex") ?? 0xFF0000FF);
    }
    return ShipStyle(
      fillColor: parseHex(json['fill']?['color'] ?? "#FF000080"),
      strokeColor: parseHex(json['stroke']?['color'] ?? "#C0C0C0"),
    );
  }
}