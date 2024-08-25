import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: BroadcastPage(),
    );
  }
}

class BroadcastPage extends StatefulWidget {
  @override
  _BroadcastPageState createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  late IO.Socket socket;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  bool isBroadcasting = false;
  final Map<int, Map<String, dynamic>> pendingOfferMap = {};
  final int myRoom = 1234;
  final String myID = '123456567934';
  int myFeed = 0;
  final String hostWS = 'ws://dtuct.ddns.net:17801';
//   final String hostWS = 'ws://192.168.1.178:17801';
  late RTCVideoRenderer _localRenderer;

  @override
  void initState() {
    super.initState();
    _localRenderer = RTCVideoRenderer();
    _localRenderer.initialize();
    _initSocket();
  }

  void _initSocket() {
    socket = IO.io(hostWS, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': false,
    });

    socket.on('connect', (_) {
      print('socket connected');
      _scheduleConnection(0.1);
    });

    socket.on('disconnect', (_) {
      print('socket disconnected');
      pendingOfferMap.clear();
      _removeAllMediaElements();
      _closeAllPCs();
    });

    socket.on('videoroom-error', (data) {
      final error = data['error'];
      final id = data['_id'];
      print('videoroom error: $error');
      if (error == 'backend-failure' || error == 'session-not-available') {
        socket.disconnect();
        return;
      }
      if (pendingOfferMap.containsKey(id)) {
        _removeAllLocalMediaElements();
        _closePubPc();
        pendingOfferMap.remove(id);
        return;
      }
    });

    socket.on('joined', (data) async {
      print('joined to room: ${data['data']}');
      _setLocalMediaElement(null, data['data']['feed'], data['data']['display'],
          data['data']['room']);
      await _publish(
          feed: data['data']['feed'], display: data['data']['display']);
    });

    socket.on('configured', (data) async {
      print('feed configured: ${data['data']}');
      pendingOfferMap.remove(data['_id']);
      if (data['data']['jsep'] != null) {
        await _peerConnection?.setRemoteDescription(RTCSessionDescription(
          data['data']['jsep']['sdp'],
          data['data']['jsep']['type'],
        ));
        // if (data['data']['jsep']['type'] == 'offer') {
        //   final answer = await _peerConnection?.createAnswer();
        //   await _peerConnection?.setLocalDescription(answer!);
        //   socket.emit('start', {'jsep': answer?.toMap()});
        // }
      }
      if (data['data']['display'] != null) {
        _setLocalMediaElement(
            null, data['data']['feed'], data['data']['display'], null);
      }
    });

    socket.on('destroyed', (data) {
      print('room destroyed: ${data['data']}');
      if (data['data']['room'] == myRoom) {
        socket.disconnect();
      }
    });

    socket.on('rtp-fwd-started', (data) {
      print('rtp forwarding started: ${data['data']}');
    });

    socket.on('rtp-fwd-stopped', (data) {
      print('rtp forwarding stopped: ${data['data']}');
    });

    socket.on('rtp-fwd-list', (data) {
      print('rtp forwarders list: ${data['data']}');
    });
  }

  void _scheduleConnection(double secs) {
    Future.delayed(Duration(seconds: secs.toInt()), () {
      _join();
    });
  }

  void _join() {
    socket.emit('join', {
      'data': {'room': myRoom, 'display': myID},
      '_id': _getId(),
    });
  }

  void _trickle(Map<String, dynamic> data) {
    final trickleData =
        data['candidate'] != null ? {'candidate': data['candidate']} : {};
    if (data['feed'] != null) trickleData['feed'] = data['feed'];
    final trickleEvent =
        data['candidate'] != null ? 'trickle' : 'trickle-complete';

    socket.emit(trickleEvent, {
      'data': trickleData,
      '_id': _getId(),
    });
  }

  void _configure(Map<String, dynamic> data) {
    final configureData = {};
    if (data['feed'] != null) configureData['feed'] = data['feed'];
    if (myRoom != null) configureData['room'] = myRoom;
    if (data['display'] != null) configureData['display'] = data['display'];
    if (data['jsep'] != null) configureData['jsep'] = data['jsep'];
    if (data['streams'] != null) configureData['streams'] = data['streams'];
    if (data['restart'] is bool) configureData['restart'] = data['restart'];

    final configId = _getId();

    socket.emit('configure', {
      'data': configureData,
      '_id': configId,
    });

    if (data['jsep'] != null) {
      pendingOfferMap[configId] = {'feed': data['feed']};
    }
  }

  Future<void> _publish({int feed = 0, String display = ''}) async {
    try {
      final offer = await _doOffer(feed, display);
      _configure({'feed': feed, 'jsep': offer.toMap()});
    } catch (e) {
      print('error while doing offer: $e');
    }
  }

  Future<RTCSessionDescription> _doOffer(int feed, String display) async {
    if (_peerConnection == null) {
      _peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {
            'urls': 'turn:34.125.2.193:3478',
            'username': 'username', // Sử dụng biến môi trường
            'credential': 'password',
          },
        ],
      });

      _peerConnection!.onIceCandidate = (candidate) {
        Map candidateMap = candidate.toMap();
        print("candidate: $candidateMap");
        _trickle({'feed': feed, 'candidate': candidate.toMap()});
      };

      _peerConnection!.onIceConnectionState = (state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          _removeAllLocalMediaElements();
          _closePubPc();
        }
      };

      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': true,
        'audio': true,
      });
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      // _peerConnection!.addStream(_localStream!);

      _setLocalMediaElement(_localStream, feed, display, null);
    } else {
      print('Performing ICE restart');
      // _peerConnection!.restartIce(); // Không sử dụng phương thức này vì nó không tồn tại
    }
    myFeed = feed;

    try {
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      return offer;
    } catch (e) {
      print('error while doing offer: $e');
      _removeAllLocalMediaElements();
      _closePubPc();
      throw e;
    }
  }

  void _setLocalMediaElement(
      MediaStream? localStream, int? feed, String? display, int? room) {
    if (room != null) {
      setState(() {
        // Update the room display
      });
    }
    if (feed == null) return;
    if (localStream != null) {
      setState(() {
        _localRenderer.srcObject = localStream;
        // Update the local video stream
      });
    }
  }

  void _removeMediaElement(bool stopTracks) {
    if (stopTracks && _localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      _localStream = null;
    }
  }

  void _removeAllMediaElements() {
    _removeMediaElement(true);
    setState(() {
      // Update the room display
    });
  }

  void _removeAllLocalMediaElements() {
    _removeMediaElement(true);
  }

  Future<void> _closePubPc() async {
    if (_peerConnection != null) {
      await _closePC(_peerConnection!);
      _peerConnection = null;
    }
  }

  Future<void> _closePC(RTCPeerConnection pc) async {
    // Dừng tất cả các track của sender
    List<RTCRtpSender> senders = await pc.getSenders();
    for (RTCRtpSender sender in senders) {
      sender.track?.stop();
    }

    // Dừng tất cả các track của receiver
    List<RTCRtpReceiver> receivers = await pc.getReceivers();
    for (RTCRtpReceiver receiver in receivers) {
      receiver.track?.stop();
    }

    // Đóng kết nối WebRTC
    await pc.close();
  }

  Future<void> _closeAllPCs() async {
    await _closePubPc();
  }

  int _getId() {
    return (DateTime.now().millisecondsSinceEpoch / 1000).round();
  }

  void _toggleBroadcast() {
    if (isBroadcasting) {
      socket.disconnect();
    } else {
      socket.connect();
    }
    setState(() {
      isBroadcasting = !isBroadcasting;
    });
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _closeAllPCs();
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Broadcast'),
      ),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _toggleBroadcast,
            child: Text(isBroadcasting ? 'STOP' : 'START'),
          ),
          Expanded(
            child: _localStream != null
                ? RTCVideoView(
                    _localRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  )
                : Center(child: Text('No video stream')),
          ),
        ],
      ),
    );
  }
}
