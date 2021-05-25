import 'package:grpc/grpc.dart';

import 'websocket_channel.dart';

ClientChannel createChannel(String host, int port, bool secure, ChannelCredentials? credentials) {
  return WebSocketClientChannel(host,
      port: port, options: ChannelOptions(credentials: credentials ?? (secure ? ChannelCredentials.secure() : ChannelCredentials.insecure())));
}
