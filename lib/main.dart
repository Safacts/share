import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class NetworkManager {
  final String deviceName;
  final Function(String) logFunction;  // Function to log messages

  NetworkManager(this.deviceName, this.logFunction);

  

  Future<void> sendBroadcast() async {
    try {
      final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final interfaces = await NetworkInterface.list();
      final interface = interfaces.firstWhere(
        (iface) => iface.addresses.any((addr) => addr.type == InternetAddressType.IPv4),
        orElse: () => throw Exception("No IPv4 interface found"),
      );
      final localIp = interface.addresses.firstWhere((addr) => addr.type == InternetAddressType.IPv4).address;

      final broadcastAddress = "255.255.255.255";
      udpSocket.broadcastEnabled = true;

      udpSocket.send(
        utf8.encode("$deviceName|$localIp"),
        InternetAddress(broadcastAddress),
        4445,
      );

      // Use the log function to log the message
      logFunction("Broadcast sent: DeviceName=$deviceName, IP=$localIp to $broadcastAddress");
    } catch (e) {
      logFunction("Error sending broadcast: $e");
    }
  }

  Future<void> listenForBroadcasts() async {
    try {
      final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4445);

      udpSocket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = udpSocket.receive();
          if (datagram != null) {
            final senderIp = datagram.address.address;
            final message = utf8.decode(datagram.data);

            // Use the log function to log the message
            logFunction("Received broadcast from $senderIp: $message");

            final nameIp = message.split("|");
            if (nameIp.length == 2) {
              final name = nameIp[0];
              final ip = nameIp[1];
              // Process device info here...
              logFunction("Discovered device: $name at $ip");
            }
          }
        }
      });
    } catch (e) {
      logFunction("Error listening for broadcasts: $e");
    }
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
    loadPreferences();
    initializeSaveFolder();
    final networkManager = NetworkManager(deviceName, addDebugLog);
    networkManager.sendBroadcast();
    networkManager.listenForBroadcasts();
  }

   void startDiscovery() {
    // Create an instance of NetworkManager and pass addDebugLog as the log function
    final networkManager = NetworkManager(deviceName, addDebugLog);
    networkManager.sendBroadcast();
    networkManager.listenForBroadcasts();
  }

  // Load saved preferences (device name and save folder)
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      deviceName = prefs.getString('deviceName') ?? deviceName;
      saveFolderPath = prefs.getString('saveFolderPath') ?? saveFolderPath;
    });
  }


  // Update and save the device name
  Future<void> updateDeviceName(String newName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceName', newName);
    setState(() {
      deviceName = newName;
    });
    addDebugLog("Device name updated to: $deviceName");
  }

  // Update and save the file saving directory
  Future<void> updateSaveFolder(String newPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saveFolderPath', newPath);
    setState(() {
      saveFolderPath = newPath;
    });
    addDebugLog("Save folder path updated to: $saveFolderPath");
  }

  void addDebugLog(String message) {
    setState(() {
      debugLogs.add("${DateTime.now().toIso8601String()}: $message");
    });
  }

  Future<void> initializeSaveFolder() async {
    // Request storage permissions for Android
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        addDebugLog("Storage permission not granted. Folder creation will fail.");
        return;
      }
    }


    final prefs = await SharedPreferences.getInstance();
    final customSavePath = prefs.getString('saveFolderPath');

    if (customSavePath != null && customSavePath.isNotEmpty) {
      saveFolderPath = customSavePath;
    } else {
      final directory = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : Directory.current;

      saveFolderPath = '${directory?.path}/ReceivedFiles';
    }

    // Log the folder path before attempting creation
    addDebugLog("Attempting to create folder at: $saveFolderPath");

    if (!Directory(saveFolderPath).existsSync()) {
      try {
        Directory(saveFolderPath).createSync(recursive: true);
        addDebugLog("Folder successfully created at: $saveFolderPath");
      } catch (e) {
        addDebugLog("Error creating folder at $saveFolderPath: $e");
      }
    } else {
      addDebugLog("Folder already exists at: $saveFolderPath");
    }

    addDebugLog("Save folder initialized at: $saveFolderPath");
  }



  Future<void> startServer() async {
    try {
      if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        addDebugLog("Storage permission not granted. Server initialization aborted.");
        return;
      }
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
                    initialSaveFolder: saveFolderPath,
                    onDeviceNameUpdated: updateDeviceName,
                    onSaveFolderUpdated: updateSaveFolder,
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
  final String initialSaveFolder;
  final ValueChanged<String> onDeviceNameUpdated;
  final ValueChanged<String> onSaveFolderUpdated;

  const SettingsPage({
    required this.initialDeviceName,
    required this.initialSaveFolder,
    required this.onDeviceNameUpdated,
    required this.onSaveFolderUpdated,
    Key? key,
  }) : super(key: key);

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _deviceNameController;
  late String _currentSaveFolder;

  @override
  void initState() {
    super.initState();
    _deviceNameController = TextEditingController(text: widget.initialDeviceName);
    _currentSaveFolder = widget.initialSaveFolder;
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    super.dispose();
  }

  void _updateSaveFolder() async {
    final newFolder = await FilePicker.platform.getDirectoryPath();
    if (newFolder != null) {
      setState(() {
        _currentSaveFolder = newFolder;
      });
      widget.onSaveFolderUpdated(newFolder);
    }
  }

  void _saveSettings() {
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
            const Text(
              "Save Folder",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _currentSaveFolder,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: _updateSaveFolder,
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveSettings,
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  }
}


// class NetworkManager {
//   final String deviceName;
//   NetworkManager(this.deviceName);

//   Future<void> sendBroadcast() async {
//     try {
//       final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
//       final interfaces = await NetworkInterface.list();
//       final interface = interfaces.firstWhere(
//         (iface) => iface.addresses.any((addr) => addr.type == InternetAddressType.IPv4),
//         orElse: () => throw Exception("No IPv4 interface found"),
//       );
//       final localIp = interface.addresses.firstWhere((addr) => addr.type == InternetAddressType.IPv4).address;

//       final broadcastAddress = "255.255.255.255";
//       udpSocket.broadcastEnabled = true;

//       udpSocket.send(
//         utf8.encode("$deviceName|$localIp"),
//         InternetAddress(broadcastAddress),
//         4445,
//       );

//       // Log debug message after broadcast
//       addDebugLog(
//           "Broadcast sent: DeviceName=$deviceName, IP=$localIp to $broadcastAddress");
//     } catch (e) {
//       addDebugLog("Error sending broadcast: $e");
//     }
//   }

//   Future<void> listenForBroadcasts() async {
//     try {
//       final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4445);

//       udpSocket.listen((event) {
//         if (event == RawSocketEvent.read) {
//           final datagram = udpSocket.receive();
//           if (datagram != null) {
//             final senderIp = datagram.address.address;
//             final message = utf8.decode(datagram.data);

//             // Log received message
//             addDebugLog("Received broadcast from $senderIp: $message");

//             final nameIp = message.split("|");
//             if (nameIp.length == 2) {
//               final name = nameIp[0];
//               final ip = nameIp[1];
//               // Process device info here...
//               addDebugLog("Discovered device: $name at $ip");
//             }
//           }
//         }
//       });
//     } catch (e) {
//       addDebugLog("Error listening for broadcasts: $e");
//     }
//   }
// }
