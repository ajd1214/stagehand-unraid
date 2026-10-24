<?php
// Stagehand: list active media-server playback sessions.
// Output: one line per file, "state<TAB>exact|guess<TAB>server_path".
// "guess" = Plex reported several versions without saying which is playing.
// Env: SH_TYPE (plex|jellyfin|emby), SH_URL, SH_TOKEN, SH_VERBOSE=1 (session summary on stderr).
// The token is sent in a header, never in the URL, so it cannot leak into logs.

$type = getenv('SH_TYPE') ?: 'plex';
$base = rtrim(getenv('SH_URL') ?: '', '/');
$token = getenv('SH_TOKEN') ?: '';
$verbose = getenv('SH_VERBOSE') === '1';

function fetch($url, $headers) {
    $ctx = stream_context_create(['http' => ['header' => implode("\r\n", $headers), 'timeout' => 10]]);
    $body = @file_get_contents($url, false, $ctx);
    if ($body === false) {
        $path = parse_url($url, PHP_URL_PATH);
        throw new Exception("request to $path failed");
    }
    return $body;
}

try {
    if ($type === 'plex') {
        $hdr = ["X-Plex-Token: $token", "Accept: application/xml"];
        $root = @simplexml_load_string(fetch("$base/status/sessions", $hdr));
        if ($root === false) throw new Exception("could not parse Plex sessions");
        foreach ($root->children() as $item) {
            $state = isset($item->Player) ? (string)$item->Player['state'] : '';
            $files = [];
            foreach ($item->xpath('.//Part') as $part) {
                if ((string)$part['file'] !== '') $files[] = (string)$part['file'];
            }
            $how = 'session'; $flag = 'exact';
            if (!$files && (string)$item['ratingKey'] !== '') {
                // Transcoded sessions may not carry the source path; ask the library.
                $how = 'library';
                $mid = isset($item->Media) ? (string)$item->Media['id'] : '';
                $meta = @simplexml_load_string(fetch("$base/library/metadata/" . rawurlencode((string)$item['ratingKey']), $hdr));
                $all = []; $match = [];
                if ($meta !== false) {
                    foreach ($meta->xpath('//Media') as $media) {
                        foreach ($media->xpath('.//Part') as $part) {
                            $f = (string)$part['file'];
                            if ($f === '') continue;
                            $all[] = $f;
                            if ($mid !== '' && (string)$media['id'] === $mid) $match[] = $f;
                        }
                    }
                }
                $files = $match ?: $all;
                if (!$match && count($all) > 1) $flag = 'guess';
            }
            if ($verbose) {
                fwrite(STDERR, sprintf("session: %s | %s | state=%s | files=%d (%s%s)\n",
                    $item->getName(), (string)$item['title'] ?: '?', $state ?: '?', count($files), $how,
                    $flag === 'guess' ? ', several versions' : ''));
            }
            foreach ($files as $f) echo "$state\t$flag\t$f\n";
        }
    } else {
        $path = $type === 'emby' ? '/emby/Sessions' : '/Sessions';
        $hdr = ["Authorization: MediaBrowser Token=\"$token\"", "X-Emby-Token: $token", "Accept: application/json"];
        $data = json_decode(fetch($base . $path, $hdr), true);
        if (!is_array($data)) throw new Exception("could not parse sessions");
        foreach ($data as $s) {
            $n = $s['NowPlayingItem'] ?? null;
            if (!$n || empty($n['Path'])) continue;
            $state = !empty($s['PlayState']['IsPaused']) ? 'paused' : 'playing';
            if ($verbose) fwrite(STDERR, sprintf("session: %s | %s | state=%s | files=1\n", $n['Type'] ?? '?', $n['Name'] ?? '?', $state));
            echo "$state\texact\t{$n['Path']}\n";
        }
    }
} catch (Exception $e) {
    echo "media server query failed: " . $e->getMessage() . "\n";
    exit(1);
}
