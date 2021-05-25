import 'package:grpc/grpc.dart';

import 'websocket_channel.dart';

ClientChannel createChannel(String host, int port, bool secure, List<int>? certificates) {
  return WebSocketClientChannel(host,
      port: port,
      options: ChannelOptions(
          credentials: secure
              ? ChannelCredentials.secure(certificates: certificates, password: 'minorlab', onBadCertificate: (cert, host) => true)
              : ChannelCredentials.insecure()));
}
