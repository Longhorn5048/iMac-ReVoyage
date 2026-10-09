"""Synthetic loopback fixtures only: does not enumerate or open physical devices."""
import hashlib
import hmac
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BINARY=str(Path(sys.argv.pop(1)).resolve())
KEY=b'0'*64

def send(sock,kind,payload=b''):
    sock.sendall(struct.pack('!I',len(payload)+1)+bytes([kind])+payload)

def exact(sock,count):
    data=b''
    while len(data)<count:
        part=sock.recv(count-len(data))
        if not part: raise EOFError()
        data+=part
    return data

def receive(sock):
    count=struct.unpack('!I',exact(sock,4))[0]
    if not 1<=count<=262153:raise ValueError('bad packet length')
    payload=exact(sock,count)
    return payload[0],payload[1:]

class MediaServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='revoyage-media-test-')
        cls.key=Path(cls.temp.name)/'pairing.key';cls.key.write_bytes(KEY+b'\n');cls.key.chmod(0o600)
        with socket.socket() as allocation:
            allocation.bind(('127.0.0.1',0));cls.port=allocation.getsockname()[1]
        cls.log=(Path(cls.temp.name)/'service.log').open('wb')
        cls.process=subprocess.Popen([BINARY,'--fixture','--port',str(cls.port),'--pairing-key-path',str(cls.key)],stdout=subprocess.DEVNULL,stderr=cls.log)
        for _ in range(100):
            if cls.process.poll() is not None:raise RuntimeError('fixture service failed to launch')
            if b'listening' in (Path(cls.temp.name)/'service.log').read_bytes():break
            time.sleep(0.02)
        else:raise RuntimeError('fixture startup timeout')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate();cls.process.wait(timeout=5);cls.log.close();cls.temp.cleanup()

    def connect(self):
        sock=socket.create_connection(('127.0.0.1',self.port),timeout=3);sock.settimeout(3)
        self.addCleanup(sock.close);return sock

    def assert_closed(self,sock):
        try:self.assertEqual(sock.recv(1),b'')
        except ConnectionResetError:pass

    def paired(self):
        sock=self.connect();kind,nonce=receive(sock);self.assertEqual(kind,0x51);self.assertEqual(len(nonce),32)
        client_nonce=bytes(range(32,64))
        send(sock,0x52,client_nonce+hmac.new(KEY,nonce+client_nonce+b'ReVoyageMediaSenderV1',hashlib.sha256).digest())
        kind,proof=receive(sock);self.assertEqual(kind,0x53)
        self.assertTrue(hmac.compare_digest(proof,hmac.new(KEY,nonce+client_nonce+b'ReVoyageMediaReceiverV1',hashlib.sha256).digest()))
        kind,registry=receive(sock);self.assertEqual(kind,0x54);self.assertEqual(len(json.loads(registry)['devices']),2)
        return sock

    def test_successful_mutual_authentication_heartbeat(self):
        sock=self.paired();send(sock,0x5a);self.assertEqual(receive(sock),(0x5a,b''))

    def test_wrong_key_receives_no_registry_or_media(self):
        sock=self.connect();_,nonce=receive(sock);client_nonce=bytes(32)
        send(sock,0x52,client_nonce+hmac.new(b'1'*64,nonce+client_nonce+b'ReVoyageMediaSenderV1',hashlib.sha256).digest())
        self.assertEqual(sock.recv(1),b'')

    def test_request_before_authentication_is_rejected(self):
        sock=self.connect();receive(sock);send(sock,0x55,b'{"schema":1,"cameraID":"fixture-camera"}')
        self.assertEqual(sock.recv(1),b'')

    def test_repeated_authentication_is_rejected(self):
        sock=self.paired();send(sock,0x52,bytes(64));self.assertEqual(sock.recv(1),b'')

    def test_microphone_start_pcm_and_stop(self):
        sock=self.paired();send(sock,0x55,b'{"schema":1,"microphoneID":"fixture-microphone"}')
        kind,data=receive(sock);self.assertEqual(kind,0x56);self.assertTrue(json.loads(data)['microphoneActive'])
        self.assertEqual(receive(sock)[0],0x54)
        kind,data=receive(sock);self.assertEqual(kind,0x58);self.assertEqual(len(data),968)
        send(sock,0x59);kind,data=receive(sock);self.assertEqual(kind,0x56);self.assertFalse(json.loads(data)['microphoneActive'])

    def test_microphone_running_camera_toggle_ack_precedes_new_pcm(self):
        sock = self.paired()
        for camera in (False, True, False, True):
            request = {"schema": 1, "microphoneID": "fixture-microphone"}
            if camera: request["cameraID"] = "fixture-camera"
            send(sock, 0x55, json.dumps(request).encode())
            kind, payload = receive(sock)
            self.assertEqual(kind, 0x56)
            status = json.loads(payload)
            self.assertEqual(status["cameraActive"], camera)
            self.assertTrue(status["microphoneActive"])
            self.assertEqual(receive(sock)[0], 0x54)
            kind, pcm = receive(sock)
            self.assertEqual(kind, 0x58)
            self.assertEqual(struct.unpack("!Q", pcm[:8])[0], 0)

    def test_missing_device_reports_failure_with_capture_off(self):
        sock=self.paired();send(sock,0x55,b'{"schema":1,"cameraID":"missing"}')
        _,data=receive(sock);status=json.loads(data);self.assertEqual(status['error'],'device_missing');self.assertFalse(status['cameraActive'])

    def test_invalid_schema_bool_and_unknown_keys_close_connection(self):
        for payload in [b'{"schema":true}',b'{"schema":2}',b'{"schema":1,"cameraID":false}',b'{"schema":1,"other":1}']:
            sock=self.paired();send(sock,0x55,payload);self.assertEqual(sock.recv(1),b'');sock.close()

    def test_malformed_length_and_partial_packet_do_not_crash(self):
        for packet in [bytes(4),struct.pack('!I',0xffffffff),struct.pack('!I',8)+b'\x55x']:
            sock=self.paired();sock.sendall(packet);sock.shutdown(socket.SHUT_WR);self.assert_closed(sock);sock.close()

    def test_disconnection_releases_client_for_next_connection(self):
        sock=self.paired();sock.close();self.paired()

    def test_insecure_pairing_file_is_rejected(self):
        insecure=Path(self.temp.name)/'insecure.key';insecure.write_bytes(KEY);insecure.chmod(0o644)
        result=subprocess.run([BINARY,'--fixture','--pairing-key-path',str(insecure)],capture_output=True,timeout=3)
        self.assertEqual(result.returncode,78)

if __name__=='__main__':unittest.main()
