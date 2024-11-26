import 'dart:io';

void main() async {
  const filePath = '<FULL_PATH_TO_FILE>'; // Specify the full path of the file to send
  const serverIp = '<SERVER_IP>'; // Replace with the mobile server's IP (e.g., 192.168.43.1)

  try {
    final socket = await Socket.connect(serverIp, 5555);
    print("Connected to server at $serverIp:5555");

    final file = File(filePath);
    if (!file.existsSync()) {
      print("File does not exist: $filePath");
      return;
    }

    print("Sending file...");
    await socket.addStream(file.openRead());
    await socket.flush();
    await socket.close();

    print("File sent successfully!");
  } catch (e) {
    print("Failed to send file: $e");
  }
}
