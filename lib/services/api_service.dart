import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/ship_model.dart';
import '../models/port_model.dart';

class ApiService {
  final String _viewpointsUrl = "https://api.nyxk.com.br/nais/models/viewpoints";

  // 1. Busca a lista de portos
  Future<List<Port>> getPorts() async {
    try {
      final response = await http.get(Uri.parse(_viewpointsUrl));
      if (response.statusCode == 200) {
        List data = json.decode(response.body);
        return data.map((item) => Port.fromJson(item)).toList();
      }
    } catch (e) {
      print("Erro ao buscar lista de portos: $e");
    }
    return [];
  }

  // 2. Busca os barcos de um único porto específico
  Future<List<Ship>> getShips(String portCode) async {
    final String shipsUrl = "https://api.nyxk.com.br/nais/port/$portCode/seascape";
    
    try {
      final response = await http.get(Uri.parse(shipsUrl));
      if (response.statusCode == 200) {
        List data = json.decode(response.body);
        return data.map((item) => Ship.fromJson(item)).toList();
      }
    } catch (e) {
      print("Erro ao buscar barcos: $e");
    }
    return [];
  }

  // 3. O MÉTODO QUE FALTAVA: Busca barcos de uma lista de portos simultaneamente (Lazy Loading)
  Future<List<Ship>> getAllShipsFromPorts(List<Port> ports) async {
    try {
      // Cria uma lista de requisições paralelas
      final futures = ports.map((port) => getShips(port.portCode));
      
      // Executa todas e aguarda o resultado
      final results = await Future.wait(futures);
      
      // Junta todas as listas de barcos em uma só
      return results.expand((shipList) => shipList).toList();
    } catch (e) {
      print("Erro no carregamento múltiplo: $e");
      return [];
    }
  }
}