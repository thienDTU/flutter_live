import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class WatchScreen extends StatefulWidget {
  @override
  _WatchScreenState createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  IO.Socket? socket;
  RTCPeerConnection? _peerConnection;
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isStreaming = false;

  @override
  void initState() {
    super.initState();
    _initializeRenderer();
    _connectSocket();
  }

  @override
  void dispose() {
    _disposeResources();
    super.dispose();
  }

  void _initializeRenderer() async {
    await _remoteRenderer.initialize();
  }

  void _disposeResources() {
    _remoteRenderer.dispose();
    _peerConnection?.close();
    socket?.disconnect();
  }

  void _connectSocket() {
    final input = {
      'hostWS': 'ws://dtuct.ddns.net:17802',
      'streamKey': 1234,
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          "urls": "turn:global.relay.metered.ca:80",
          "username": "c2c1a4f22d43dca671cb5ff3",
          "credential": "BG1UoU320MDamMZx"
        },
        {
          'urls': 'turn:34.125.2.193:3478',
          'username': 'username', // Sử dụng biến môi trường hoặc bảo mật khác
          'credential': 'password',
        },
      ],
    };

    socket = IO.io(input['hostWS'], <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': false,
    });

    socket?.on('connect', (_) {
      print('------------ Socket connected');
      _watch();
    });

    socket?.on('disconnect', (_) {
      print('------------ Socket disconnected');
      _stopAllStreams();
    });

    socket?.on('offer', (data) async {
      print('------------ Offer received');
      if (data != null &&
          data['data'] != null &&
          data['data']['jsep'] != null) {
        final jsep = data['data']['jsep'];
        if (jsep['sdp'] != null && jsep['type'] != null) {
          final answer = await _doAnswer(jsep);
          if (answer != null) {
            _start(answer);
          }
        } else {
          print('------------ Invalid JSEP data in offer');
        }
      } else {
        print('------------ Invalid offer received');
      }
    });

    socket?.on('starting', (_) {
      print('------------ Starting stream');
      setState(() {
        _isStreaming = true;
      });
    });

    socket?.on('started', (_) {
      print('------------ Stream started');
    });

    socket?.on('streaming-error', (data) {
      print('------------ Streaming error: $data');
      _showError('Streaming error: ${data['message'] ?? 'Unknown error'}');
      _stopAllStreams();
    });

    socket?.connect();
  }

  Future<void> _watch() async {
    socket?.emit('watch', {
      'data': {'id': 1234},
      '_id': _getId(),
    });
  }

  Future<void> _start(dynamic jsep) async {
    socket?.emit('start', {
      'data': {'jsep': jsep},
      '_id': _getId(),
    });
    setState(() {
      _isStreaming = true;
    });
  }

  Future<dynamic> _doAnswer(dynamic offer) async {
    if (offer == null || offer['sdp'] == null || offer['type'] == null) {
      print('------------ Invalid offer data');
      return null;
    }

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:global.relay.metered.ca:80',
          'username': 'c2c1a4f22d43dca671cb5ff3',
          'credential': 'BG1UoU320MDamMZx'
        },
        {
          'urls': 'turn:34.125.2.193:3478',
          'username': 'username', // Sử dụng biến môi trường
          'credential': 'password',
        },
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (candidate) {
      print('------------ ICE Candidate: $candidate');
      // print(JsonCodec().encode(candidate));
      if (candidate != null) {
        socket?.emit('trickle', {
          'candidate': candidate.toMap(),
          '_id': _getId(),
        });
      } else {
        socket?.emit('trickle-complete', {
          'candidate': {},
          '_id': _getId(),
        });
      }
    };

    _peerConnection?.onIceConnectionState = (state) {
      print('------------ ICE Connection State: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        print('------------ ICE Connection failed or closed');
        _stopAllStreams();
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        print('------------ ICE Connection disconnected');
      }
    };

    _peerConnection?.onTrack = (event) {
      print('------------ Track received: ${event.streams[0]}');
      setState(() {
        _remoteRenderer.srcObject = event.streams[0];
      });
    };

    await _peerConnection?.setRemoteDescription(RTCSessionDescription(
      offer['sdp'],
      offer['type'],
    ));

    final answer = await _peerConnection?.createAnswer();
    await _peerConnection?.setLocalDescription(answer!);

    return answer?.toMap();
  }

  void _stopAllStreams() {
    _remoteRenderer.srcObject?.getTracks().forEach((track) => track.stop());
    _remoteRenderer.srcObject = null;
    setState(() {
      _isStreaming = false;
    });
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Error'),
          content: Text(message),
          actions: [
            TextButton(
              child: Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  int _getId() {
    return (DateTime.now().millisecondsSinceEpoch / 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Watch Stream'),
      ),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _isStreaming ? null : _connectSocket,
            child: Text('START'),
          ),
          ElevatedButton(
            onPressed: !_isStreaming
                ? null
                : () {
                    socket?.disconnect();
                    setState(() {
                      _isStreaming = false;
                    });
                  },
            child: Text('STOP'),
          ),
          Expanded(
            child: _isStreaming
                ? RTCVideoView(_remoteRenderer)
                : Center(child: Text('No stream available')),
          ),
        ],
      ),
    );
  }
}
