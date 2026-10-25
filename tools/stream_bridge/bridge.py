#!/usr/bin/env python3
"""Carry a stream's chat to the living reserve: Twitch and YouTube in, lines of JSON out.

The game, started with `--reserve`, listens on a local port (`data/config/reserve.json`
`link`, 127.0.0.1:47821) for one JSON object per line:
`{"platform": "twitch", "user_id": "123", "user": "Вася", "text": "!имя Ветка"}`.
This reads the chats and writes those lines. Only messages that start with «!» go on: the
game reads nothing else, and the rest of the chat stays out of it.

- Twitch: the chat's IRC over TLS. Reading needs no account (an anonymous `justinfan`
  login); a token is only for a channel that hides its chat from guests.
- YouTube: the Live Streaming API, polled. It takes an API key of your own Google Cloud
  project and the id of the live video. Each poll costs 5 units of the project's 10 000 a day,
  so `min_interval_seconds` keeps the polls apart (8 s: about 9 000 units in 4 hours).

Settings are in a JSON file beside this one, `bridge.json`, made from `bridge.example.json`.
It holds your keys and is never committed (`.gitignore`). Standard library only.

Run:  python3 tools/stream_bridge/bridge.py [--config PATH] [--dry-run]
"""

import argparse
import collections
import json
import os
import random
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "bridge.json")
PREFIX = "!"
MAX_TEXT = 300
MAX_QUEUE = 200


def log(source, text):
    print("%s [%s] %s" % (time.strftime("%H:%M:%S"), source, text), flush=True)


def load_config(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def message(platform, user_id, user, text):
    """The line the game reads, or None for a message that is no command."""
    text = (text or "").strip()
    if not text.startswith(PREFIX):
        return None
    return {"platform": platform, "user_id": str(user_id), "user": str(user or user_id), "text": text[:MAX_TEXT]}


class Backoff:
    """Waits between reconnections: 1 s doubling to `ceiling`, with a little jitter; reset on success."""

    def __init__(self, ceiling=60.0):
        self.ceiling = ceiling
        self.delay = 1.0

    def wait(self, stop):
        stop.wait(self.delay * random.uniform(0.8, 1.2))
        self.delay = min(self.ceiling, self.delay * 2.0)

    def reset(self):
        self.delay = 1.0


class GameLink:
    """The game's port. Lines wait in a queue (the newest `MAX_QUEUE`) while the game is not up."""

    def __init__(self, host, port, dry_run=False):
        self.host = host
        self.port = port
        self.dry_run = dry_run
        self.queue = collections.deque(maxlen=MAX_QUEUE)
        self.ready = threading.Condition()
        self.sent = 0

    def send(self, line):
        with self.ready:
            self.queue.append(line)
            self.ready.notify()

    def run(self, stop):
        backoff = Backoff(10.0)
        while not stop.is_set():
            if self.dry_run:
                self._drain(lambda data: sys.stdout.write("-> " + data.decode("utf-8")), stop)
                continue
            try:
                with socket.create_connection((self.host, self.port), timeout=5.0) as connection:
                    log("game", "connected to %s:%d" % (self.host, self.port))
                    backoff.reset()
                    self._drain(connection.sendall, stop)
            except OSError as error:
                if not stop.is_set():
                    log("game", "not reachable (%s), retrying" % error)
                    backoff.wait(stop)

    def _drain(self, write, stop):
        while not stop.is_set():
            with self.ready:
                while not self.queue and not stop.is_set():
                    self.ready.wait(0.5)
                if stop.is_set():
                    return
                line = self.queue[0]
            write((json.dumps(line, ensure_ascii=False) + "\n").encode("utf-8"))
            with self.ready:
                if self.queue and self.queue[0] is line:
                    self.queue.popleft()
            self.sent += 1

    def stop(self):
        with self.ready:
            self.ready.notify_all()


# --- Twitch -------------------------------------------------------------------------------

TAG_ESCAPES = {"s": " ", ":": ";", "\\": "\\", "r": "\r", "n": "\n"}


def unescape_tag(value):
    out = []
    index = 0
    while index < len(value):
        if value[index] == "\\" and index + 1 < len(value):
            out.append(TAG_ESCAPES.get(value[index + 1], value[index + 1]))
            index += 2
        else:
            out.append(value[index])
            index += 1
    return "".join(out)


def parse_irc_line(line):
    """`{tags, prefix, command, params, trailing}` of one IRC line (IRCv3 tags included)."""
    tags = {}
    if line.startswith("@"):
        raw, _, line = line[1:].partition(" ")
        for pair in raw.split(";"):
            key, _, value = pair.partition("=")
            tags[key] = unescape_tag(value)
    prefix = ""
    if line.startswith(":"):
        prefix, _, line = line[1:].partition(" ")
    trailing = None
    if " :" in line:
        line, _, trailing = line.partition(" :")
    elif line.startswith(":"):
        trailing = line[1:]
        line = ""
    parts = line.split()
    return {"tags": tags, "prefix": prefix, "command": parts[0].upper() if parts else "",
            "params": parts[1:], "trailing": trailing}


def twitch_message(parsed):
    """The game's line for a PRIVMSG, or None."""
    if parsed["command"] != "PRIVMSG" or parsed["trailing"] is None:
        return None
    nick = parsed["prefix"].partition("!")[0]
    tags = parsed["tags"]
    return message("twitch", tags.get("user-id") or nick, tags.get("display-name") or nick, parsed["trailing"])


class TwitchReader:
    def __init__(self, settings, game):
        self.channel = str(settings["channel"]).lower().lstrip("#")
        self.token = str(settings.get("oauth_token", "")).strip()
        self.nick = str(settings.get("nick", "")).lower() if self.token else "justinfan%d" % random.randint(10000, 99999)
        self.host = settings.get("host", "irc.chat.twitch.tv")
        self.tls = bool(settings.get("tls", True))
        self.port = int(settings.get("port", 6697 if self.tls else 6667))
        self.game = game

    def run(self, stop):
        backoff = Backoff()
        while not stop.is_set():
            try:
                self._session(stop, backoff)
            except (OSError, ssl.SSLError) as error:
                if not stop.is_set():
                    log("twitch", "connection lost (%s), reconnecting" % error)
            if not stop.is_set():
                backoff.wait(stop)

    def _session(self, stop, backoff):
        raw = socket.create_connection((self.host, self.port), timeout=10.0)
        connection = ssl.create_default_context().wrap_socket(raw, server_hostname=self.host) if self.tls else raw
        with connection:
            connection.settimeout(1.0)
            lines = ["CAP REQ :twitch.tv/tags twitch.tv/commands"]
            if self.token:
                lines.append("PASS oauth:" + self.token.removeprefix("oauth:"))
            lines += ["NICK " + self.nick, "JOIN #" + self.channel]
            connection.sendall(("\r\n".join(lines) + "\r\n").encode("utf-8"))
            buffer = b""
            heard_at = time.monotonic()
            while not stop.is_set():
                try:
                    chunk = connection.recv(4096)
                except socket.timeout:
                    # Twitch pings every few minutes; silence much longer than that is a dead link.
                    if time.monotonic() - heard_at > 420.0:
                        raise OSError("no word from the server for 7 minutes")
                    continue
                if not chunk:
                    raise OSError("closed by the server")
                heard_at = time.monotonic()
                buffer += chunk
                while b"\r\n" in buffer:
                    line, buffer = buffer.split(b"\r\n", 1)
                    if self._hear(line.decode("utf-8", "replace"), connection, backoff):
                        return

    def _hear(self, line, connection, backoff):
        """True when the server asks to reconnect."""
        parsed = parse_irc_line(line)
        command = parsed["command"]
        if command == "PING":
            connection.sendall(("PONG :%s\r\n" % (parsed["trailing"] or "tmi.twitch.tv")).encode("utf-8"))
        elif command == "RECONNECT":
            log("twitch", "server asks to reconnect")
            return True
        elif command == "NOTICE" and "authentication failed" in (parsed["trailing"] or "").lower():
            raise OSError("login refused: check the token and nick in bridge.json")
        elif command == "JOIN":
            log("twitch", "reading #%s" % self.channel)
            backoff.reset()
        else:
            line_out = twitch_message(parsed)
            if line_out is not None:
                self.game.send(line_out)
        return False


# --- YouTube ------------------------------------------------------------------------------

class YouTubeReader:
    def __init__(self, settings, game):
        self.api_key = str(settings.get("api_key", "")).strip()
        self.oauth_token = str(settings.get("oauth_token", "")).strip()
        self.video_id = str(settings.get("video_id", "")).strip()
        self.chat_id = str(settings.get("live_chat_id", "")).strip()
        self.base_url = str(settings.get("base_url", "https://www.googleapis.com/youtube/v3")).rstrip("/")
        self.min_interval = float(settings.get("min_interval_seconds", 8.0))
        self.game = game
        self.polls = 0

    def _get(self, path, params):
        query = dict(params)
        headers = {"Accept": "application/json"}
        if self.oauth_token:
            headers["Authorization"] = "Bearer " + self.oauth_token
        else:
            query["key"] = self.api_key
        request = urllib.request.Request("%s/%s?%s" % (self.base_url, path, urllib.parse.urlencode(query)), headers=headers)
        with urllib.request.urlopen(request, timeout=20.0) as response:
            return json.load(response)

    def _find_chat(self):
        found = self._get("videos", {"part": "liveStreamingDetails", "id": self.video_id})
        items = found.get("items", [])
        if not items:
            raise LookupError("no video %s: check video_id" % self.video_id)
        chat = items[0].get("liveStreamingDetails", {}).get("activeLiveChatId", "")
        if not chat:
            raise LookupError("video %s has no live chat now (not live yet, or over)" % self.video_id)
        return chat

    def run(self, stop):
        backoff = Backoff(120.0)
        while not stop.is_set():
            try:
                chat = self.chat_id or self._find_chat()
                log("youtube", "reading the live chat of %s" % (self.video_id or chat))
                backoff.reset()
                self._poll(chat, stop)
            except urllib.error.HTTPError as error:
                reason = _http_reason(error)
                log("youtube", "API refused (%d %s)" % (error.code, reason))
                if reason in ("quotaExceeded", "rateLimitExceeded", "dailyLimitExceeded"):
                    stop.wait(600.0)
                    continue
            except (urllib.error.URLError, OSError, LookupError, ValueError) as error:
                log("youtube", str(error))
            if not stop.is_set():
                backoff.wait(stop)

    def _poll(self, chat, stop):
        token = None
        first = True
        while not stop.is_set():
            params = {"liveChatId": chat, "part": "snippet,authorDetails", "maxResults": 200}
            if token:
                params["pageToken"] = token
            page = self._get("liveChat/messages", params)
            self.polls += 1
            token = page.get("nextPageToken", token)
            # The first page is what was said before the bridge started: commands from then are stale.
            if not first:
                for item in page.get("items", []):
                    line_out = youtube_message(item)
                    if line_out is not None:
                        self.game.send(line_out)
            first = False
            if page.get("offlineAt"):
                raise LookupError("the stream is over")
            stop.wait(max(self.min_interval, float(page.get("pollingIntervalMillis", 0)) / 1000.0))


def youtube_message(item):
    snippet = item.get("snippet", {})
    if snippet.get("type", "textMessageEvent") != "textMessageEvent":
        return None
    author = item.get("authorDetails", {})
    text = snippet.get("displayMessage") or snippet.get("textMessageDetails", {}).get("messageText", "")
    return message("youtube", author.get("channelId") or snippet.get("authorChannelId", ""), author.get("displayName", ""), text)


def _http_reason(error):
    try:
        body = json.loads(error.read().decode("utf-8"))
        return body["error"]["errors"][0]["reason"]
    except (ValueError, KeyError, IndexError, TypeError, OSError):
        return ""


# --- Main ---------------------------------------------------------------------------------

def start(config, dry_run=False):
    """Starts the readers and the game's link on their threads; returns (stop, game, readers, threads)."""
    stop = threading.Event()
    link = config.get("game", {})
    game = GameLink(link.get("host", "127.0.0.1"), int(link.get("port", 47821)), dry_run)
    readers = []
    twitch = config.get("twitch", {})
    if twitch.get("enabled") and twitch.get("channel"):
        readers.append(TwitchReader(twitch, game))
    youtube = config.get("youtube", {})
    if youtube.get("enabled") and (youtube.get("api_key") or youtube.get("oauth_token")) \
            and (youtube.get("video_id") or youtube.get("live_chat_id")):
        readers.append(YouTubeReader(youtube, game))
    threads = [threading.Thread(target=game.run, args=(stop,), daemon=True)]
    threads += [threading.Thread(target=reader.run, args=(stop,), daemon=True) for reader in readers]
    for thread in threads:
        thread.start()
    return stop, game, readers, threads


def main():
    parser = argparse.ArgumentParser(description="Carry a stream's chat to the living reserve.")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="settings file (default: bridge.json beside this)")
    parser.add_argument("--dry-run", action="store_true", help="print the lines instead of sending them to the game")
    args = parser.parse_args()
    if not os.path.exists(args.config):
        sys.exit("No settings at %s: copy bridge.example.json to bridge.json and fill it in." % args.config)
    stop, game, readers, threads = start(load_config(args.config), args.dry_run)
    if not readers:
        stop.set()
        sys.exit("Nothing to read: turn on twitch (channel) or youtube (api_key and video_id) in the settings.")
    log("bridge", "running; Ctrl+C stops")
    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        stop.set()
        game.stop()
        log("bridge", "stopped; %d lines sent" % game.sent)


if __name__ == "__main__":
    main()
