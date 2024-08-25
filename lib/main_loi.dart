import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
// import 'watch.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC Stream',
      home: VideoStreamPage(),
      // routes: {
      //   '/watch': (context) => WatchScreen(),
      // },
    );
  }
}

class VideoStreamPage extends StatefulWidget {
  @override
  _VideoStreamPageState createState() => _VideoStreamPageState();
}

class _VideoStreamPageState extends State<VideoStreamPage> {
  late IO.Socket _socket;
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  late RTCVideoRenderer _localVideoRenderer;
  bool isBroadcasting = false;
  final String _hostWS = 'ws://dtuct.ddns.net:17801';
  final int _streamKey = 1234;
  final String _userId = '1179152313659678';

  @override
  void initState() {
    super.initState();
    _localVideoRenderer = RTCVideoRenderer();
    _localVideoRenderer.initialize();
    _initializeSocket();
  }

  @override
  void dispose() {
    _localVideoRenderer.dispose();
    _peerConnection?.dispose();
    _socket.disconnect();
    super.dispose();
  }

  void _scheduleConnection(double secs) {
    Future.delayed(Duration(seconds: secs.toInt()), () {
      _joinRoom();
    });
  }

  void _initializeSocket() {
    _socket = IO.io(_hostWS, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': false,
    });

    _socket.on('connect', (_) {
      print('-------------------- Socket connected');
      _scheduleConnection(0.1);
    });

    _socket.on('disconnect', (_) {
      print('-------------------- Socket disconnected');
      _closePeerConnection();
    });

    _socket.on('joined', (data) async {
      print('joined to room: ${data['data']}');
      _setLocalMediaElement(null, data['data']['feed'], data['data']['display'],
          data['data']['room']);
      await _publish(
          feed: data['data']['feed'], display: data['data']['display']);
    });

    _socket.on('configured', (data) async {
      print('-------------------- Feed configured: $data');
      if (data['jsep'] != null) {
        final sdp =
            RTCSessionDescription(data['jsep']['sdp'], data['jsep']['type']);
        await _peerConnection?.setRemoteDescription(sdp);
      }
    });

    _socket.on('videoroom-error', (data) {
      final error = data['error'];
      print('-------------------- Error: ${data['error']}');
      if (error == 'backend-failure' || error == 'session-not-available') {
        _closePeerConnection();
        return;
      }
    });
  }

  void _joinRoom() {
    final joinData = {
      'room': _streamKey,
      'display': _userId,
      'token': null,
    };

    _socket.emit('join', {
      'data': joinData,
      '_id': _getId(),
    });
  }

  Future<void> _publish({int feed = 0, String display = ''}) async {
    try {
      final offer = await _doOffer(feed, display);
      _configure({'feed': feed, 'jsep': offer.toMap(), 'display': display});
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
          print(
              '-------------------- ICE Connection failed or closed close mẹ roi');
          _closePeerConnection();
        }
      };

      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': true,
        'audio': true,
      });

      // add track
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      _setLocalMediaElement(_localStream, feed, display, null);
    } else {
      print('Performing ICE restart');
      // _peerConnection!.restartIce(); // Không sử dụng phương thức này vì nó không tồn tại
    }
    // myFeed = feed;

    try {
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      return offer;
    } catch (e) {
      print('error while doing offer: $e');
      // _removeAllLocalMediaElements();
      // _closePubPc();
      _closePeerConnection();
      throw e;
    }
  }

  void _configure(Map<String, dynamic> data) {
    final configureData = {};
    configureData['room'] = _streamKey;
    if (data['feed'] != null) configureData['feed'] = data['feed'];
    if (data['display'] != null) configureData['display'] = data['display'];
    if (data['jsep'] != null) configureData['jsep'] = data['jsep'];
    if (data['streams'] != null) configureData['streams'] = data['streams'];
    if (data['restart'] is bool) configureData['restart'] = data['restart'];

    _socket.emit('configure', {
      'data': configureData,
      '_id': _getId(),
    });
  }

  void _trickle(Map<String, dynamic> data) {
    final trickleData =
        data['candidate'] != null ? {'candidate': data['candidate']} : {};
    if (data['feed'] != null) trickleData['feed'] = data['feed'];
    final trickleEvent =
        data['candidate'] != null ? 'trickle' : 'trickle-complete';

    _socket.emit(trickleEvent, {
      'data': trickleData,
      '_id': _getId(),
    });
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
        _localVideoRenderer.srcObject = localStream;
        // Update the local video stream
      });
    }
  }

  void _closePeerConnection() {
    _peerConnection?.close();
    _peerConnection = null;
  }

  int _getId() {
    return (DateTime.now().millisecondsSinceEpoch / 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebRTC Stream'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: RTCVideoView(_localVideoRenderer),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () {
                  if (!_socket.connected) _socket.connect();
                },
                child: Text('Start'),
              ),
              SizedBox(width: 10),
              ElevatedButton(
                onPressed: () {
                  if (_socket.connected) _socket.disconnect();
                },
                child: Text('Stop'),
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.pushNamed(context, '/watch');
                },
                child: Text('Go to Watch Page'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
