#!/usr/bin/env python3
"""The stream bridge against stand-ins: an IRC server that speaks as Twitch's chat does, web
servers that answer as YouTube's API and Telegram's Bot API do, and a port that takes the game's
lines.

Run:  python3 tools/stream_bridge/test_bridge.py
"""

import http.server
import json
import os
import socket
import sys
import threading
import time
import unittest
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bridge  # noqa: E402


def listener():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(10.0)
    return server, server.getsockname()[1]


class FakeGame:
    """Takes the bridge's lines on a local port, as the game does."""

    def __init__(self):
        self.server, self.port = listener()
        self.lines = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        connection, _ = self.server.accept()
        connection.settimeout(10.0)
        buffer = b""
        with connection:
            while True:
                try:
                    chunk = connection.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    self.lines.append(json.loads(line.decode("utf-8")))

    def close(self):
        self.server.close()

    def wait_for(self, count, seconds=10.0):
        deadline = time.monotonic() + seconds
        while len(self.lines) < count and time.monotonic() < deadline:
            time.sleep(0.02)
        return self.lines


class ParsingTests(unittest.TestCase):
    def test_a_twitch_line(self):
        parsed = bridge.parse_irc_line(
            "@badge-info=;display-name=Вася;user-id=123;flags= :vasya!vasya@vasya.tmi.twitch.tv PRIVMSG #reserve :!имя Ветка")
        self.assertEqual(bridge.twitch_message(parsed),
                         {"platform": "twitch", "user_id": "123", "user": "Вася", "text": "!имя Ветка"})

    def test_escaped_tags_and_no_display_name(self):
        parsed = bridge.parse_irc_line("@display-name=;user-id=7;msg=a\\sb\\:c :petya!petya@x PRIVMSG #r :!моё")
        self.assertEqual(parsed["tags"]["msg"], "a b;c")
        self.assertEqual(bridge.twitch_message(parsed)["user"], "petya")

    def test_talk_is_left_out(self):
        self.assertIsNone(bridge.twitch_message(bridge.parse_irc_line(":a!a@a PRIVMSG #r :привет всем")))
        self.assertIsNone(bridge.message("youtube", "1", "Аня", "  "))

    def test_a_ping(self):
        parsed = bridge.parse_irc_line("PING :tmi.twitch.tv")
        self.assertEqual((parsed["command"], parsed["trailing"]), ("PING", "tmi.twitch.tv"))

    def test_a_youtube_item(self):
        item = {"snippet": {"type": "textMessageEvent", "displayMessage": "!олени"},
                "authorDetails": {"channelId": "UC1", "displayName": "Аня"}}
        self.assertEqual(bridge.youtube_message(item), {"platform": "youtube", "user_id": "UC1", "user": "Аня", "text": "!олени"})
        item["snippet"]["type"] = "superChatEvent"
        self.assertIsNone(bridge.youtube_message(item))


class TwitchTests(unittest.TestCase):
    def test_reads_the_chat_and_answers_pings(self):
        game = FakeGame()
        irc, irc_port = listener()
        heard = []

        def serve():
            connection, _ = irc.accept()
            connection.settimeout(10.0)
            with connection:
                received = b""
                while b"JOIN #reserve" not in received:
                    received += connection.recv(4096)
                heard.append(received.decode("utf-8"))
                connection.sendall(b":justinfan!justinfan@x JOIN #reserve\r\nPING :tmi.twitch.tv\r\n")
                connection.sendall("@display-name=Маша;user-id=42 :masha!masha@x PRIVMSG #reserve :!имя Звёздочка\r\n"
                                   ":kolya!kolya@x PRIVMSG #reserve :просто болтаю\r\n".encode("utf-8"))
                while b"PONG" not in received:
                    received += connection.recv(4096)
                heard.append(received.decode("utf-8"))
                time.sleep(0.5)

        threading.Thread(target=serve, daemon=True).start()
        config = {"game": {"port": game.port},
                  "twitch": {"enabled": True, "channel": "Reserve", "host": "127.0.0.1", "port": irc_port, "tls": False}}
        stop, link, readers, _threads = bridge.start(config)
        try:
            lines = game.wait_for(1)
            self.assertEqual(lines, [{"platform": "twitch", "user_id": "42", "user": "Маша", "text": "!имя Звёздочка"}])
            deadline = time.monotonic() + 5.0
            while len(heard) < 2 and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIn("NICK justinfan", heard[0])
            self.assertNotIn("PASS", heard[0])
            self.assertIn("PONG :tmi.twitch.tv", heard[1])
        finally:
            stop.set()
            link.stop()
            irc.close()
            game.close()


class YouTubeTests(unittest.TestCase):
    def test_polls_the_chat_past_what_was_said_before(self):
        game = FakeGame()
        asked = []

        class Api(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                query = dict(urllib.parse.parse_qsl(url.query))
                asked.append((url.path, query))
                if url.path.endswith("/videos"):
                    body = {"items": [{"liveStreamingDetails": {"activeLiveChatId": "chat-1"}}]}
                elif "pageToken" not in query:
                    body = {"nextPageToken": "p1", "pollingIntervalMillis": 100,
                            "items": [_item("UC0", "Старый", "!имя Прошлое")]}
                else:
                    body = {"nextPageToken": "p2", "pollingIntervalMillis": 100,
                            "items": [_item("UC1", "Аня", "!олени"), _item("UC2", "Боря", "привет")]}
                data = json.dumps(body).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        config = {"game": {"port": game.port},
                  "youtube": {"enabled": True, "api_key": "test-key", "video_id": "vid", "min_interval_seconds": 0.1,
                              "base_url": "http://127.0.0.1:%d/youtube/v3" % api.server_address[1]}}
        stop, link, readers, _threads = bridge.start(config)
        try:
            lines = game.wait_for(1)
            self.assertEqual(lines[0], {"platform": "youtube", "user_id": "UC1", "user": "Аня", "text": "!олени"})
            self.assertEqual(asked[0][1].get("id"), "vid")
            self.assertEqual(asked[1][1].get("liveChatId"), "chat-1")
            self.assertEqual(asked[1][1].get("key"), "test-key")
            self.assertTrue(all(line["user_id"] != "UC0" for line in lines), "nothing from before the bridge started")
        finally:
            stop.set()
            link.stop()
            api.shutdown()
            api.server_close()
            game.close()


class TelegramTests(unittest.TestCase):
    def test_reading_an_update(self):
        def update(chat, text, user=7, username="masha"):
            return {"update_id": 1, "message": {"chat": chat, "text": text, "from": {"id": user, "username": username}}}
        group = {"id": -1001, "title": "Заповедник"}
        chats = [-1001, "@reserve_open"]
        self.assertEqual(bridge.telegram_message(update(group, "!имя Ветка"), chats),
                         {"platform": "telegram", "user_id": "7", "user": "masha", "text": "!имя Ветка"})
        self.assertEqual(bridge.telegram_message(update(group, "/имя@ReserveBot Ветка"), chats)["text"], "!имя Ветка")
        self.assertEqual(bridge.telegram_message(update(group, "/моё"), chats)["text"], "!моё")
        self.assertEqual(bridge.telegram_message(update({"id": -5, "username": "Reserve_Open"}, "!олени"), chats)["text"], "!олени")
        self.assertIsNone(bridge.telegram_message(update({"id": -9}, "!олени"), chats), "a chat not in chats is not heard")
        self.assertIsNone(bridge.telegram_message(update(group, "привет"), chats))
        self.assertIsNone(bridge.telegram_message(update(group, "/моё"), chats, accept_slash=False))
        named = {"update_id": 2, "message": {"chat": group, "text": "!моё", "from": {"id": 8, "first_name": "Аня", "last_name": "К"}}}
        self.assertEqual(bridge.telegram_message(named, chats)["user"], "Аня К")

    def test_polls_past_what_was_said_before(self):
        game = FakeGame()
        asked = []

        def message(update_id, chat, text, user):
            return {"update_id": update_id, "message": {"chat": {"id": chat, "title": "Группа"}, "text": text,
                                                         "from": {"id": user, "username": "u%d" % user}}}

        class Api(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                query = dict(urllib.parse.parse_qsl(url.query))
                asked.append((url.path, query))
                if query.get("offset") == "-1":
                    result = [message(10, -1001, "!имя Прошлое", 1)]
                elif query.get("offset") == "11":
                    result = [message(11, -1001, "!олени", 2), message(12, -42, "!имя Чужой", 3), message(13, -1001, "привет", 4)]
                else:
                    time.sleep(0.2)
                    result = []
                data = json.dumps({"ok": True, "result": result}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        config = {"game": {"port": game.port},
                  "telegram": {"enabled": True, "bot_token": "123:test", "chats": [-1001], "poll_seconds": 1,
                               "api_url": "http://127.0.0.1:%d" % api.server_address[1]}}
        stop, link, readers, _threads = bridge.start(config)
        try:
            lines = game.wait_for(1)
            self.assertEqual(lines[0], {"platform": "telegram", "user_id": "2", "user": "u2", "text": "!олени"})
            time.sleep(0.5)
            self.assertEqual(len(game.lines), 1, "nothing from before the bridge, nor from another chat, nor talk")
            self.assertEqual(asked[0][0], "/bot123:test/getUpdates")
        finally:
            stop.set()
            link.stop()
            api.shutdown()
            api.server_close()
            game.close()


class TelegramRulesTests(unittest.TestCase):
    def test_who_asks_for_the_rules(self):
        def update(chat, text):
            return {"update_id": 1, "message": {"message_id": 5, "chat": chat, "text": text, "from": {"id": 7}}}
        group = {"id": -1001, "type": "supergroup"}
        alone = {"id": 7, "type": "private"}
        chats = [-1001]
        self.assertTrue(bridge.wants_rules(update(group, "!помощь"), chats))
        self.assertTrue(bridge.wants_rules(update(group, "/help@ReserveBot"), chats))
        self.assertTrue(bridge.wants_rules(update(alone, "/start"), chats), "a private chat needs no listing")
        self.assertTrue(bridge.wants_rules(update(alone, "/правила"), chats, accept_slash=False), "and always takes «/»")
        self.assertFalse(bridge.wants_rules(update({"id": -9, "type": "group"}, "!помощь"), chats), "a group not heard")
        self.assertFalse(bridge.wants_rules(update(group, "!олени"), chats))
        self.assertFalse(bridge.wants_rules(update(group, "/help"), chats, accept_slash=False))

    def test_answers_once_a_while_in_a_group(self):
        game = FakeGame()
        sent = []
        queue = [[], [
            {"update_id": 11, "message": {"message_id": 1, "chat": {"id": -1001, "type": "supergroup"}, "text": "!помощь", "from": {"id": 2}}},
            {"update_id": 12, "message": {"message_id": 2, "chat": {"id": -1001, "type": "supergroup"}, "text": "/help", "from": {"id": 3}}},
            {"update_id": 13, "message": {"message_id": 3, "chat": {"id": 2, "type": "private"}, "text": "/start", "from": {"id": 2}}},
        ]]

        class Api(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _reply(self, result):
                data = json.dumps({"ok": True, "result": result}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if queue:
                    self._reply(queue.pop(0))
                else:
                    time.sleep(0.2)
                    self._reply([])

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                sent.append((urllib.parse.urlparse(self.path).path, dict(urllib.parse.parse_qsl(self.rfile.read(length).decode("utf-8")))))
                self._reply({"message_id": 99})

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        config = {"game": {"port": game.port},
                  "telegram": {"enabled": True, "bot_token": "123:test", "chats": [-1001], "poll_seconds": 1,
                               "rules": ["Правила:", "!моё"], "api_url": "http://127.0.0.1:%d" % api.server_address[1]}}
        stop, link, readers, _threads = bridge.start(config)
        try:
            lines = game.wait_for(2)
            time.sleep(0.5)
            self.assertEqual([line["text"] for line in lines], ["!помощь", "!help"], "the group's asks go on to the game as well")
            self.assertEqual([(path, params["chat_id"]) for path, params in sent],
                             [("/bot123:test/sendMessage", "-1001"), ("/bot123:test/sendMessage", "2")],
                             "one answer in the group for two asks, one in private")
            self.assertEqual(sent[0][1]["text"], "Правила:\n!моё")
            self.assertEqual(json.loads(sent[0][1]["reply_parameters"])["message_id"], 1, "a reply to who asked")
            self.assertNotIn("reply_parameters", sent[1][1])
        finally:
            stop.set()
            link.stop()
            api.shutdown()
            api.server_close()
            game.close()


def _item(channel, name, text):
    return {"snippet": {"type": "textMessageEvent", "displayMessage": text},
            "authorDetails": {"channelId": channel, "displayName": name}}


if __name__ == "__main__":
    unittest.main()
