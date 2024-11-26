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
      theme: ThemeData(primarySwatch: Colors.blue),
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
    final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4445);
    udpSocket.broadcastEnabled = true;

    Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final localIp = (await NetworkInterface.list())
            .expand((e) => e.addresses)
            .firstWhere((addr) => addr.type == InternetAddressType.IPv4)
            .address;

        udpSocket.send(
          utf8.encode("$deviceName|$localIp"),
          InternetAddress("255.255.255.255"), // Broadcasting
          4445,
        );
      } catch (e) {
        addDebugLog("Broadcast error: $e");
      }
    });

    udpSocket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = udpSocket.receive();
        if (datagram != null) {
          try {
            final nameIp = utf8.decode(datagram.data).split("|");
            if (nameIp.length == 2) {
              final name = nameIp[0];
              final ip = nameIp[1];

              if (name != deviceName &&
                  !discoveredDevices.any((device) => device['ip'] == ip)) {
                setState(() {
                  discoveredDevices.add({"name": name, "ip": ip});
                });
              }
            }
          } catch (e) {
            addDebugLog("Error processing discovery message: $e");
          }
        }
      }
    });
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
    });
  }, onDone: () async {
    final fileData = buffer.toBytes();
    final metaDataLength = fileData.indexOf(0); // Assuming metadata ends with 0 byte
    final metaData = utf8.decode(fileData.sublist(0, metaDataLength));
    final fileName = metaData.split("|")[0]; // Metadata format: "filename|filesize"
    final file = File('$saveFolderPath/$fileName');

    await file.writeAsBytes(fileData.sublist(metaDataLength + 1));
    client.writeln("ACK"); // Send acknowledgment
    client.destroy();

    setState(() {
      status = "File received: $fileName";
    });

    addDebugLog("File received: $fileName");
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
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
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
                    .map((log) => Text(log, style: const TextStyle(color: Colors.white, fontSize: 12)))
                    .toList(),
              ),
            ),
          ),
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
