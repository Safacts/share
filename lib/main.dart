import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const ShareApp());
}

class ShareApp extends StatelessWidget {
  const ShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Share',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white, // Icons and text color
        ),
      ),
      home: const ShareHome(),
    );
  }

}




class ShareHome extends StatefulWidget {
  const ShareHome({super.key});

  @override
  _ShareHomeState createState() => _ShareHomeState();
}

class _ShareHomeState extends State<ShareHome> {
  ServerSocket? serverSocket;
  String status = "Idle";
  double progress = 0.0;
  String transferSpeed = "0.0 MB/s";
  String deviceName = "Device-${DateTime.now().millisecondsSinceEpoch}";
  List<Map<String, String>> discoveredDevices = [];
  String saveFolderPath = '';
  String? selectedDeviceIp;
  String? selectedDeviceName;
  List<File> selectedFiles = [];
  List<String> debugLogs = []; // To display debug messages

  @override
  void initState() {
    super.initState();
    initializeSaveFolder();
    startDiscovery();
    startServer();
  }

  void addDebugLog(String message) {
    setState(() {
      debugLogs.add("${DateTime.now().toIso8601String()}: $message");
    });
  }

  Future<void> initializeSaveFolder() async {
    final directory = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : Directory.current;

    setState(() {
      saveFolderPath = '${directory?.path}/ReceivedFiles';
    });

    addDebugLog("Save folder initialized at: $saveFolderPath");
  }
  Future<void> startDiscovery() async {
    try {
      // Get local IPv4 address
      final interfaces = await NetworkInterface.list();
      final interface = interfaces.firstWhere(
        (iface) => iface.addresses.any((addr) => addr.type == InternetAddressType.IPv4),
        orElse: () => throw Exception("No IPv4 interface found"),
      );
      final localIp = interface.addresses.firstWhere((addr) => addr.type == InternetAddressType.IPv4).address;

      // Calculate broadcast address for the subnet
      final broadcastAddress = '${localIp.substring(0, localIp.lastIndexOf('.') + 1)}255';

      // Bind to the socket
      final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4445);
      udpSocket.broadcastEnabled = true;
      addDebugLog("UDP socket bound to: ${udpSocket.address.address} on port 4445");

      // Start periodic broadcasts
      Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          final message = "$deviceName|$localIp";
          udpSocket.send(
            utf8.encode(message),
            InternetAddress(broadcastAddress),
            4445,
          );
          addDebugLog("Broadcast sent: $message to $broadcastAddress");
        } catch (e) {
          addDebugLog("Broadcast error: $e");
        }
      });

      // Listen for incoming messages
      udpSocket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = udpSocket.receive();
          if (datagram != null) {
            final senderIp = datagram.address.address;
            final message = utf8.decode(datagram.data);

            addDebugLog("Received broadcast from $senderIp: $message");

            // Process message
            final nameIp = message.split("|");
            if (nameIp.length == 2) {
              final name = nameIp[0];
              final ip = nameIp[1];

              // Ensure device is not already discovered and not itself
              if (name != deviceName &&
                  !discoveredDevices.any((device) => device['ip'] == ip)) {
                setState(() {
                  discoveredDevices.add({"name": name, "ip": ip});
                });
                addDebugLog("Discovered device: $name at $ip");
              }
            } else {
              addDebugLog("Malformed message received: $message");
            }
          }
        }
      });
    } catch (e) {
      addDebugLog("Error in startDiscovery: $e");
    }
  }




  Future<void> startServer() async {
    try {
      if (Platform.isAndroid) {
        await Permission.storage.request();
      }

      if (!Directory(saveFolderPath).existsSync()) {
        Directory(saveFolderPath).createSync(recursive: true);
      }

      final localIp = (await NetworkInterface.list())
          .expand((e) => e.addresses)
          .firstWhere((addr) => addr.type == InternetAddressType.IPv4)
          .address;

      serverSocket = await ServerSocket.bind(localIp, 5555);
      setState(() {
        status = "Server running";
      });
      addDebugLog("Server started on IP: $localIp, Port: 5555");

      serverSocket!.listen((client) {
        receiveFiles(client);
      });
    } catch (e) {
      setState(() {
        status = "Server failed to start: $e";
      });
      addDebugLog("Server error: $e");
    }
  }
  void receiveFiles(Socket client) async {
    addDebugLog("Client connected: ${client.remoteAddress.address}");
    final buffer = BytesBuilder();
    final startTime = DateTime.now(); // Track start time

    client.listen((data) {
      buffer.add(data);
      setState(() {
        final elapsedTime = DateTime.now().difference(startTime).inMilliseconds / 1000;
        transferSpeed = "${(buffer.length / 1024 / 1024 / elapsedTime).toStringAsFixed(2)} MB/s";

        // Calculate and display receiving percentage
        if (buffer.length > 0) {
          final totalSize = buffer.length;
          final receivedPercentage = ((buffer.length / totalSize) * 100).toStringAsFixed(2);
          addDebugLog("Receiving file: ${buffer.length} bytes received, $receivedPercentage% complete");
        }
      });
    }, onDone: () async {
      final fileData = buffer.toBytes();
      final metaDataLength = fileData.indexOf(0); // Assuming metadata ends with 0 byte
      final metaData = utf8.decode(fileData.sublist(0, metaDataLength));
      final fileName = metaData.split("|")[0]; // Metadata format: "filename|filesize"
      final fileSize = int.parse(metaData.split("|")[1]);
      final file = File('$saveFolderPath/$fileName');

      await file.writeAsBytes(fileData.sublist(metaDataLength + 1));
      client.writeln("ACK"); // Send acknowledgment
      client.destroy();

      setState(() {
        status = "File received: $fileName";
      });

      addDebugLog("File received: $fileName, total size: $fileSize bytes");
    });
  }


  Future<void> selectFilesAndSend() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );

    if (result != null) {
      selectedFiles = result.paths.map((path) => File(path!)).toList();

      if (selectedDeviceIp != null) {
        await sendFiles(selectedDeviceIp!);
      } else {
        setState(() {
          status = "No device selected!";
        });
        addDebugLog("No device selected for sending files.");
      }
    }
  }
  Future<void> sendFiles(String ip) async {
    try {
      final socket = await Socket.connect(ip, 5555);
      addDebugLog("Connected to $ip for sending files.");
      
      for (final file in selectedFiles) {
        final startTime = DateTime.now(); // Track start time
        final fileName = file.uri.pathSegments.last;
        final fileSize = await file.length();

        socket.add(utf8.encode("$fileName|${fileSize}0")); // Metadata
        await socket.addStream(file.openRead().map((data) {
          final elapsedTime = DateTime.now().difference(startTime).inMilliseconds / 1000;
          setState(() {
            transferSpeed = "${(data.length / 1024 / 1024 / elapsedTime).toStringAsFixed(2)} MB/s";
          });
          return data;
        }));
        await socket.flush();

        // Wait for acknowledgment
        final ack = await socket.first;
        if (utf8.decode(ack) == "ACK") {
          setState(() {
            status = "File $fileName sent successfully!";
          });
          addDebugLog("File $fileName sent successfully.");
        }
      }
      socket.destroy();
    } catch (e) {
      setState(() {
        status = "Error sending files: $e";
      });
      addDebugLog("Error during file sending: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue, Colors.purple, Colors.pink],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text("SHARE"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsPage(
                    initialDeviceName: deviceName,
                    onDeviceNameUpdated: (newName) {
                      setState(() {
                        deviceName = newName;
                      });
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Main content
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Display current device name
                Text("Device Name: $deviceName"),
                const SizedBox(height: 10),
                const Text("Available Devices:"),
                Expanded(
                  child: ListView.builder(
                    itemCount: discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final device = discoveredDevices[index];
                      return ListTile(
                        title: Text(device['name']!),
                        subtitle: Text(device['ip']!),
                        onTap: () {
                          setState(() {
                            selectedDeviceIp = device['ip'];
                            selectedDeviceName = device['name'];
                          });
                          selectFilesAndSend();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // Debug logs
          Positioned(
            bottom: 100,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: debugLogs
                    .take(5)
                    .map((log) => Text(
                          log,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ))
                    .toList(),
              ),
            ),
          ),

          // Progress bar
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey,
              color: Colors.blue,
            ),
          ),

          // Transfer speed
          Positioned(
            bottom: 50,
            left: 16,
            right: 16,
            child: Text(
              "Transfer Speed: $transferSpeed",
              style: const TextStyle(color: Colors.black, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final String initialDeviceName;
  final ValueChanged<String> onDeviceNameUpdated;

  const SettingsPage({
    required this.initialDeviceName,
    required this.onDeviceNameUpdated,
    Key? key,
  }) : super(key: key);

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _deviceNameController;

  @override
  void initState() {
    super.initState();
    _deviceNameController = TextEditingController(text: widget.initialDeviceName);
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    super.dispose();
  }

  void _saveDeviceName() {
    widget.onDeviceNameUpdated(_deviceNameController.text);
    Navigator.pop(context); // Return to the main screen
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Device Name",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _deviceNameController,
              decoration: const InputDecoration(
                labelText: "Enter device name",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveDeviceName,
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  }
}

