import 'package:grpc/grpc.dart';

ClientChannel createChannel(String host, int port, bool secure, ChannelCredentials? credentials) {
  return ClientChannel(
    host, // Your IP here or localhost
    port: port,
    options: ChannelOptions(
      credentials: credentials ?? (secure
          ? ChannelCredentials.secure()
          : ChannelCredentials.insecure()),
      idleTimeout: Duration(seconds: 1),
    ),
  );
}
