class_name ViewerLink
extends RefCounted

## Where viewers' chat lines come in (`reserve.json` `link`): a TCP port on this machine that the
## chat bridge (`tools/stream_bridge`) connects to and writes one line of JSON per message -
## `{"platform": "twitch", "user_id": "123", "user": "Вася", "text": "!имя Ветка"}`. Only the
## local address is listened on. `poll()` takes what arrived since the last call; a line that is
## not an object with `text` is dropped.

const MAX_LINE := 2048

var _server := TCPServer.new()
var _peers: Array = []
var _buffers: Array = []


## Starts listening; false (and nothing listening) when the port cannot be had.
func listen(config: Dictionary) -> bool:
	var link: Dictionary = config.get("link", {})
	return _server.listen(int(link.get("port", 47821)), str(link.get("host", "127.0.0.1"))) == OK


func stop() -> void:
	for peer in _peers:
		peer.disconnect_from_host()
	_peers.clear()
	_buffers.clear()
	_server.stop()


func is_listening() -> bool:
	return _server.is_listening()


func poll() -> Array:
	var messages: Array = []
	while _server.is_listening() and _server.is_connection_available():
		_peers.append(_server.take_connection())
		_buffers.append(PackedByteArray())
	var index := 0
	while index < _peers.size():
		var peer: StreamPeerTCP = _peers[index]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.remove_at(index)
			_buffers.remove_at(index)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var got: Array = peer.get_data(available)
			if int(got[0]) == OK:
				_buffers[index].append_array(got[1])
		messages.append_array(_take_lines(index))
		index += 1
	return messages


func _take_lines(index: int) -> Array:
	var messages: Array = []
	var buffer: PackedByteArray = _buffers[index]
	while true:
		var end := buffer.find(10)
		if end < 0:
			if buffer.size() > MAX_LINE:
				buffer = PackedByteArray()
			break
		var line := buffer.slice(0, end).get_string_from_utf8().strip_edges()
		buffer = buffer.slice(end + 1)
		var json := JSON.new()
		if line != "" and json.parse(line) == OK and json.data is Dictionary and json.data.has("text"):
			messages.append(json.data)
	_buffers[index] = buffer
	return messages
