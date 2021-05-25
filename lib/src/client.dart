import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'logger.dart';
import 'signal/signal.dart';
import 'stream.dart';
import 'utils.dart';

abstract class Sender {
  MediaStream get stream;

  /// [kind in 'video' | 'audio']
  RTCRtpTransceiver get transceivers;
}

class RTCConfiguration {
  /// 'vp8' | 'vp9' | 'h264'
  late String codec;
}

class Transport {
  Transport(this.signal);

  static Future<Transport> create({required int role, required Signal signal, required Map<String, dynamic> config}) async {
    var transport = Transport(signal);
    var pc = await createPeerConnection(config);

    transport.pc = pc;

    if (role == RolePub) {
      transport.api = await pc.createDataChannel('ion-sfu', RTCDataChannelInit()..maxRetransmits = 30);
    }

    pc.onDataChannel = (channel) {
      transport.api = channel;
      transport.onapiopen?.call();
    };

    pc.onIceCandidate = (candidate) {
      if (candidate != null) {
        signal.trickle(Trickle(target: role, candidate: candidate));
      }
    };

    pc.onSignalingState = (state) {
      print('onSignalingState: $role, $state');
    };

    pc.onConnectionState = (state) {
      print('onConnectionState: $role, $state');
    };

    return transport;
  }

  // bool hasRemoteDescription = false;
  Function()? onapiopen;
  RTCDataChannel? api;
  Signal signal;
  RTCPeerConnection? pc;
  List<RTCIceCandidate> candidates = [];
}

class Client {
  Client(this.signal, this.config);

  static Future<Client> create(
      {required String sid, required String uid, required Signal signal, Map<String, dynamic>? config, Function(bool result)? onJoin}) async {
    var client = Client(signal, config ?? defaultConfig);

    client.transports = {
      RolePub: await Transport.create(role: RolePub, signal: signal, config: config ?? defaultConfig),
      RoleSub: await Transport.create(role: RoleSub, signal: signal, config: config ?? defaultConfig)
    };

    client.signal.onready = () async {
      if (!client.initialized) {
        var result = await client.join(sid, uid);
        onJoin?.call(result);
        client.initialized = true;
      }
    };
    signal.onnegotiate = (desc) => client.negotiate(desc);
    signal.ontrickle = (trickle) => client.trickle(trickle);
    client.signal.connect();
    return client;
  }

  Map<String, dynamic> config;

  static final defaultConfig = {
    'iceServers': [
      //{'urls': 'stun:stun.stunprotocol.org:3478'}
    ],
    'sdpSemantics': 'unified-plan'
  };

  bool initialized = false;
  Signal signal;
  Map<int, Transport> transports = {};
  Function(MediaStreamTrack track, RemoteStream stream)? ontrack;

  Future<List<StatsReport>> getPubStats(MediaStreamTrack selector) {
    return transports[RolePub]!.pc!.getStats(selector);
  }

  Future<List<StatsReport>> getSubStats(MediaStreamTrack selector) {
    return transports[RoleSub]!.pc!.getStats(selector);
  }

  Future<void> publish(LocalStream stream) async {
    await stream.publish(transports[RolePub]!.pc!);
    // await onnegotiationneeded();
  }

  Future close() async {
    await Future.wait(transports.values.map((e) => e.pc!.close()));
    // for (var element in transports.values) {
    //   await element.pc!.close();
    //   await element.pc!.dispose();
    // }
    transports.clear();
    // transports.forEach((key, element) {
    //   element.pc!.close();
    //   element.pc!.dispose();
    // });
    signal.close();
  }

  Future leave() async {
    await Future.wait(transports.values.map((e) => e.pc!.close()));
    transports.clear();
  }

  Future<bool> join(String sid, String uid) async {
    try {
      print('join: start');
      transports[RoleSub]!.pc!.onTrack = (RTCTrackEvent ev) {
        var remote = makeRemote(ev.streams[0], transports[RoleSub]!);
        ontrack?.call(ev.track, remote);
      };

      var pc = transports[RolePub]!.pc;
      if (pc != null) {
        var offer = await pc.createOffer({});
        await pc.setLocalDescription(offer);
        var answer = await signal.join(sid, uid, offer);
        await pc.setRemoteDescription(answer);
        // transports[RolePub]!.hasRemoteDescription = true;
        transports[RolePub]!.candidates.forEach((c) => pc.addCandidate(c));
        pc.onRenegotiationNeeded = () => onnegotiationneeded();
        print('join: end');
        return true;
      }
    } catch (e) {
      print('join: e => ${e.toString()}');
    }
    return false;
  }

  Future trickle(Trickle trickle) async {
    var pc = transports[trickle.target]!.pc;
    var remote;
    try {
      remote = pc != null ? (await pc.getRemoteDescription()) : null;
    } catch (e) {
      print(e);
    }

    if (remote != null) {
      await pc?.addCandidate(trickle.candidate);
    } else {
      transports[trickle.target]!.candidates.add(trickle.candidate);
    }
  }

  Future negotiate(RTCSessionDescription description) async {
    try {
      var pc = transports[RoleSub]!.pc;
      if (pc != null) {
        if (WebRTC.platformIsWeb || WebRTC.platformIsAndroid) {
          //description.sdp = description.sdp?.replaceAll('640c1f', '42e01f');
        }
        print('sub offer ${description.sdp}');
        await pc.setRemoteDescription(description);
        transports[RoleSub]!.candidates.forEach((c) => pc.addCandidate(c));
        transports[RoleSub]!.candidates = [];
        var answer = await pc.createAnswer({});
        await pc.setLocalDescription(answer);
        if (WebRTC.platformIsWeb || WebRTC.platformIsAndroid) {
          //answer.sdp = answer.sdp?.replaceAll('42e01f', '640c1f');
        }
        signal.answer(answer);
        print('sub answer ${answer.sdp}');
      }
    } catch (err) {
      log.error('negotiate: e => ${err.toString()}');
    }
  }

  Future<void> onnegotiationneeded() async {
    try {
      var pc = transports[RolePub]!.pc;
      if (pc != null) {
        var offer = await pc.createOffer({});
        setPreferredCodec(offer);
        print('pub offer ${offer.sdp}');
        await pc.setLocalDescription(offer);
        var answer = await signal.offer(offer);
        print('pub answer ${answer.sdp}');
        await pc.setRemoteDescription(answer);
      }
    } catch (err, st) {
      log.error('onnegotiationneeded: e => ${err.toString()} $st');
    }
  }

  void setPreferredCodec(RTCSessionDescription description) {
    var capSel = CodecCapabilitySelector(description.sdp!);
    var acaps = capSel.getCapabilities('audio');
    if (acaps != null) {
      acaps.codecs = acaps.codecs.where((e) => (e['codec'] as String).toLowerCase() == 'opus').toList();
      acaps.setCodecPreferences('audio', acaps.codecs);
      capSel.setCapabilities(acaps);
    }

    var vcaps = capSel.getCapabilities('video');
    if (vcaps != null) {
      vcaps.codecs = vcaps.codecs.where((e) => (e['codec'] as String).toLowerCase() == 'vp8').toList();
      vcaps.setCodecPreferences('video', vcaps.codecs);
      capSel.setCapabilities(vcaps);
    }
    description.sdp = capSel.sdp();
  }
}
