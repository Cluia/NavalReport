import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'models/port_model.dart';
import 'models/ship_model.dart';
import 'services/api_service.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ShipTrackerPage(),
  ));
}

class ShipTrackerPage extends StatefulWidget {
  const ShipTrackerPage({super.key});

  @override
  State<ShipTrackerPage> createState() => _ShipTrackerPageState();
}

class _ShipTrackerPageState extends State<ShipTrackerPage> {
  GoogleMapController? _mapController;
  final ApiService _apiService = ApiService();
  
  List<Port> _ports = [];
  Port? _selectedPort;
  Set<Marker> _markers = {};
  Timer? _refreshTimer;
  
  bool _isLoadingPorts = true;
  bool _isFetchingShips = false;
  double _currentZoom = 11.0;
  
  MapType _currentMapType = MapType.normal;
  int? _trackedShipMmsi;
  final TextEditingController _searchController = TextEditingController();

  // --- VARIÁVEIS DO NOVO PAINEL DE CONTROLE ---
  bool _isPanelVisible = false;
  int _panelTabIndex = 0; // 0: Portos, 1: Mapa, 2: Filtros
  
  // Lista em memória para filtragem instantânea sem chamar a API de novo
  List<Ship> _lastFetchedShips = [];

  // Filtros de embarcação (Todos começam ativados)
  final Map<String, bool> _shipFilters = {
    "Tanker": true,
    "Cargo": true,
    "Passenger": true,
    "Tug / Towing": true,
    "Fishing": true,
    "Outros": true,
  };

  @override
  void initState() {
    super.initState();
    _fetchInitialPorts();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialPorts() async {
    try {
      final ports = await _apiService.getPorts();
      setState(() {
        _ports = ports;
        _isLoadingPorts = false;
        if (_ports.isNotEmpty) {
          _selectedPort = _ports.firstWhere((p) => p.portCode == "BRSSZ", orElse: () => _ports.first);
        }
      });
      _startUpdateLoop();
    } catch (e) {
      debugPrint("Erro ao carregar portos: $e");
    }
  }

  bool _isPortNearVisible(Port port, LatLngBounds bounds) {
    const double margin = 1.0; 
    return (port.lat >= bounds.southwest.latitude - margin && port.lat <= bounds.northeast.latitude + margin) &&
           (port.lon >= bounds.southwest.longitude - margin && port.lon <= bounds.northeast.longitude + margin);
  }

  void _startUpdateLoop() {
    _refreshTimer?.cancel();
    _updateShipPositions();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _updateShipPositions();
    });
  }

  Future<void> _searchShip(String query) async {
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isFetchingShips = true);

    try {
      final allShips = await _apiService.getAllShipsFromPorts(_ports);
      try {
        final foundShip = allShips.firstWhere(
          (s) => s.vesselName.toLowerCase().contains(query.toLowerCase()) || s.mmsi.toString() == query
        );
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(foundShip.lat, foundShip.lon), 13.5));
        _searchController.clear();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Navio "$query" não encontrado.'), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      debugPrint("Erro na pesquisa: $e");
    } finally {
      setState(() => _isFetchingShips = false);
    }
  }

  // --- NOVA FUNÇÃO: Categoriza os navios para o filtro ---
  String _getShipCategory(String type) {
    if (type.contains("Tanker")) return "Tanker";
    if (type.contains("Cargo")) return "Cargo";
    if (type.contains("Passenger")) return "Passenger";
    if (type.contains("Tug") || type.contains("Towing")) return "Tug / Towing";
    if (type.contains("Fishing")) return "Fishing";
    return "Outros";
  }

  Future<void> _updateShipPositions() async {
    if (_mapController == null || _ports.isEmpty || _isFetchingShips) return;

    if (_currentZoom < 7.0 && _trackedShipMmsi == null) {
      if (_markers.isNotEmpty) setState(() => _markers = {});
      return;
    }

    setState(() => _isFetchingShips = true);

    try {
      LatLngBounds visibleBounds = await _mapController!.getVisibleRegion();
      List<Port> visiblePorts = _ports.where((p) => _isPortNearVisible(p, visibleBounds)).toList();

      if (visiblePorts.isEmpty) {
        setState(() {
          _markers = {};
          _isFetchingShips = false;
        });
        return;
      }

      // 1. Busca os dados na AWS e guarda na memória
      _lastFetchedShips = await _apiService.getAllShipsFromPorts(visiblePorts);
      
      // 2. Chama a função separada que desenha baseada nos filtros
      await _drawFilteredMarkers();

      if (_trackedShipMmsi != null) {
        try {
          final trackedShip = _lastFetchedShips.firstWhere((s) => s.mmsi == _trackedShipMmsi);
          _mapController?.animateCamera(CameraUpdate.newLatLng(LatLng(trackedShip.lat, trackedShip.lon)));
        } catch (e) { /* ignorar se perder o navio */ }
      }
    } catch (e) {
      debugPrint("Erro ao atualizar barcos: $e");
    } finally {
      setState(() => _isFetchingShips = false);
    }
  }

  // --- NOVA FUNÇÃO: Desenha os marcadores aplicando os filtros ---
  Future<void> _drawFilteredMarkers() async {
    List<Marker> newMarkers = [];
    
    for (var ship in _lastFetchedShips) {
      // Verifica se a categoria do navio está ativada no painel de filtros
      String category = _getShipCategory(ship.vesselTypeDesc);
      if (_shipFilters[category] == false) continue; // Pula o desenho se o filtro estiver desativado

      BitmapDescriptor shipIcon = await ship.getMarkerIcon(_currentZoom);

      newMarkers.add(
        Marker(
          markerId: MarkerId(ship.mmsi.toString()),
          position: LatLng(ship.lat, ship.lon),
          flat: true,
          anchor: const Offset(0.5, 0.5),
          onTap: () => _showShipDetails(ship),
          icon: shipIcon,
        ),
      );
    }

    setState(() => _markers = newMarkers.toSet());
  }

  void _showShipDetails(Ship ship) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      backgroundColor: Colors.transparent, 
      builder: (context) {
        final int length = ship.dimBow + ship.dimStern;
        final int width = ship.dimPort + ship.dimStarboard;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min, 
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(backgroundColor: Colors.blue[900], child: const Icon(Icons.directions_boat, color: Colors.white)),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ship.vesselName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        Text("MMSI: ${ship.mmsi} | Porto: ${ship.portCode}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 30, thickness: 1),
              _buildDetailRow(Icons.category, "Tipo", ship.vesselTypeDesc),
              _buildDetailRow(Icons.straighten, "Dimensões", "${length}m (comprimento) x ${width}m (largura)"),
              _buildDetailRow(Icons.speed, "Velocidade", "${ship.sog} nós"),
              _buildDetailRow(Icons.assistant_navigation, "Destino", ship.dest),
              _buildDetailRow(Icons.update, "Última Att", ship.timeAgo),
              if (ship.draught != null && ship.draught! > 0) _buildDetailRow(Icons.water, "Calado", "${ship.draught}m"),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity, height: 50,
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() => _trackedShipMmsi = ship.mmsi);
                    Navigator.pop(context);
                    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(ship.lat, ship.lon), 14.5));
                  },
                  icon: const Icon(Icons.my_location), label: const Text("Seguir este navio", style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[900], foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.blueGrey),
          const SizedBox(width: 15),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.black87, fontSize: 14),
                children: [TextSpan(text: "$label: ", style: const TextStyle(fontWeight: FontWeight.bold)), TextSpan(text: value)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _changePort(Port port) {
    setState(() {
      _selectedPort = port;
      _trackedShipMmsi = null;
      // Removida a linha que fechava o painel para permitir seleção contínua
    });
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(port.lat, port.lon), port.zoom));
  }

  // ==========================================
  // CONSTRUÇÃO DO PAINEL LATERAL (UI)
  // ==========================================
  
  Widget _buildTabButton(IconData icon, int index, String tooltip) {
    final isSelected = _panelTabIndex == index;
    return IconButton(
      icon: Icon(icon, color: isSelected ? Colors.amber : Colors.white54),
      tooltip: tooltip,
      onPressed: () => setState(() => _panelTabIndex = index),
    );
  }

  Widget _buildControlPanel() {
    if (!_isPanelVisible) return const SizedBox.shrink();

    return Positioned(
      top: 10, // Fica abaixo da barra de pesquisa
      right: 16,
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFF242629).withOpacity(0.95),
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cabeçalho de Abas
              Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white24, width: 1)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildTabButton(Icons.anchor, 0, "Portos"),
                    _buildTabButton(Icons.layers, 1, "Tipo de Mapa"),
                    _buildTabButton(Icons.filter_alt, 2, "Filtros"),
                    Container(width: 1, height: 24, color: Colors.white24), // Separador
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () => setState(() => _isPanelVisible = false),
                    ),
                  ],
                ),
              ),
              
              // Conteúdo Dinâmico das Abas
              Container(
                constraints: const BoxConstraints(maxHeight: 350), // Impede que o painel ocupe toda a tela
                child: _buildPanelContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanelContent() {
    // ABA 0: LISTA DE PORTOS
    if (_panelTabIndex == 0) {
      return ListView.builder(
        shrinkWrap: true,
        itemCount: _ports.length,
        itemBuilder: (context, index) {
          final p = _ports[index];
          return RadioListTile<Port>(
            title: Text(p.description, style: const TextStyle(color: Colors.white, fontSize: 13)),
            value: p,
            groupValue: _selectedPort,
            activeColor: Colors.amber,
            onChanged: (val) => _changePort(val!),
          );
        },
      );
    } 
    // ABA 1: TIPO DE MAPA
    else if (_panelTabIndex == 1) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<MapType>(
            title: const Text("Vetor (Padrão)", style: TextStyle(color: Colors.white)),
            value: MapType.normal,
            groupValue: _currentMapType,
            activeColor: Colors.amber,
            onChanged: (val) => setState(() => _currentMapType = val!),
          ),
          RadioListTile<MapType>(
            title: const Text("Satélite Híbrido", style: TextStyle(color: Colors.white)),
            value: MapType.hybrid,
            groupValue: _currentMapType,
            activeColor: Colors.amber,
            onChanged: (val) => setState(() => _currentMapType = val!),
          ),
        ],
      );
    } 
    // ABA 2: FILTROS DE NAVIO
    else {
      return ListView(
        shrinkWrap: true,
        children: _shipFilters.keys.map((String key) {
          return CheckboxListTile(
            title: Text(key, style: const TextStyle(color: Colors.white, fontSize: 13)),
            value: _shipFilters[key],
            activeColor: Colors.amber,
            checkColor: Colors.black,
            onChanged: (bool? value) {
              setState(() {
                _shipFilters[key] = value!;
              });
              // Redesenha o mapa na hora sem precisar buscar na API de novo!
              _drawFilteredMarkers();
            },
          );
        }).toList(),
      );
    }
  }
  // ==========================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Monitoramento Naval"),
        backgroundColor: Colors.blue[900], 
        actions: [
          // Substituímos as antigas ações pelo botão que abre o novo Painel
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            tooltip: 'Painel de Controle',
            onPressed: () => setState(() => _isPanelVisible = !_isPanelVisible),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: _isLoadingPorts 
        ? const Center(child: CircularProgressIndicator()) 
        : Stack(
            children: [
              GoogleMap(
                initialCameraPosition: const CameraPosition(target: LatLng(-23.98, -46.29), zoom: 11),
                markers: _markers,
                mapType: _currentMapType,
                onMapCreated: (controller) => _mapController = controller,
                myLocationButtonEnabled: false,
                onCameraMove: (pos) => _currentZoom = pos.zoom,
                onCameraIdle: () => _updateShipPositions(),
              ),

              Positioned(
                top: 10, 
                left: 16,
                width: MediaQuery.of(context).size.width > 450 ? 400 : MediaQuery.of(context).size.width - 32,
                child: Card(
                  color: const Color.fromARGB(134, 255, 255, 255), // Garante 100% de opacidade (nada transparente)
                  elevation: 8, // Aumentamos a sombra para destacar ainda mais do mar
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.search, color: Colors.blueGrey),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: const InputDecoration(
                              hintText: "Pesquisar MMSI ou Nome...", 
                              border: InputBorder.none,
                            ),
                            onSubmitted: _searchShip,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            FocusScope.of(context).unfocus();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // O NOVO PAINEL DE CONTROLE FLUTUANTE
              _buildControlPanel(),

              if (_trackedShipMmsi != null)
                Positioned(
                  top: 85, left: 20, right: 20,
                  child: Card(
                    color: Colors.red[700], shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      leading: const Icon(Icons.radar, color: Colors.white),
                      title: const Text("Rastreando Navio...", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => setState(() => _trackedShipMmsi = null),
                      ),
                    ),
                  ),
                ),

              if (_isFetchingShips && _trackedShipMmsi == null)
                Positioned(
                  top: 85, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                          SizedBox(width: 10), Text("Buscando barcos...", style: TextStyle(color: Colors.white, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),

              if (_currentZoom < 7.0 && _trackedShipMmsi == null)
                Positioned(
                  bottom: 30, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black87, borderRadius: BorderRadius.circular(30),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))],
                      ),
                      child: const Text("Aproxime o zoom para ver os barcos", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ],
          ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 50.0),
        child: FloatingActionButton.extended(
          onPressed: _updateShipPositions,
          label: const Text("Atualizar"),
          icon: const Icon(Icons.refresh),
          backgroundColor: Colors.white,
          foregroundColor: Colors.blue[900],
        ),
      ),
    );
  }
}