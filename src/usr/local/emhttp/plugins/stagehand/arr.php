<?php
// Stagehand: ask one Sonarr or Radarr instance about a file.
// Usage (env): ARR_TYPE=sonarr|radarr ARR_URL=http://host:port ARR_KEY=apikey
//              ARR_MOUNTS="container_path<TAB>host_path\n..." (from docker inspect)
//   php arr.php info              -> "ok <version> <count> series|movies"
//   php arr.php owns <host_path>  -> one of:
//        owned      this instance tracks this exact file (it is a real library file)
//        not-owned  this instance manages the folder but not this file (leftover)
//        unmanaged  this instance does not manage this folder at all
//   Any failure prints "error: <reason>" and exits 1. The API key is sent as a header only.

$type = getenv('ARR_TYPE');
$base = rtrim(getenv('ARR_URL') ?: '', '/');
$key  = getenv('ARR_KEY') ?: '';
$mounts = [];
foreach (preg_split('/\r?\n/', getenv('ARR_MOUNTS') ?: '') as $line) {
    $p = explode("\t", $line);
    if (count($p) === 2 && $p[0] !== '' && $p[1] !== '') $mounts[] = [rtrim($p[0], '/'), rtrim($p[1], '/')];
}
// longest host path first, so the most specific mount wins
usort($mounts, fn($a, $b) => strlen($b[1]) <=> strlen($a[1]));

function api($path) {
    global $base, $key;
    $ctx = stream_context_create(['http' => ['header' => "X-Api-Key: $key\r\nAccept: application/json", 'timeout' => 30]]);
    $body = @file_get_contents("$base/api/v3/$path", false, $ctx);
    if ($body === false) throw new Exception("request to /api/v3/" . strtok($path, '?') . " failed");
    $data = json_decode($body, true);
    if ($data === null) throw new Exception("bad JSON from /api/v3/" . strtok($path, '?'));
    return $data;
}
// host path -> every path this container can see it under (a host folder may be mounted
// more than once, e.g. /mnt/user/data_tv at /data_tv and /mnt/user at /mnt/user).
// Most specific mount first. Empty when no mount covers it.
function to_container($host) {
    global $mounts;
    $out = [];
    foreach ($mounts as [$dst, $src]) {
        if ($host === $src || strpos($host, "$src/") === 0) $out[] = $dst . substr($host, strlen($src));
    }
    return array_values(array_unique($out));
}
function under($file, $folder) { $folder = rtrim($folder, '/'); return $folder !== '' && strpos($file, "$folder/") === 0; }

try {
    if (!in_array($type, ['sonarr', 'radarr'], true)) throw new Exception("unknown type '$type'");
    $cmd = $argv[1] ?? '';
    if ($cmd === 'info') {
        $st = api('system/status');
        $n = count(api($type === 'sonarr' ? 'series' : 'movie'));
        echo "ok " . ($st['version'] ?? '?') . " $n " . ($type === 'sonarr' ? 'series' : 'movies') . "\n";
        exit(0);
    }
    if ($cmd !== 'owns' || empty($argv[2])) throw new Exception("usage: owns <host_path>");
    $files = to_container($argv[2]);
    if (!$files) { echo "unmanaged\n"; exit(0); }   // this container cannot even see the file
    $under_any = function ($folder) use ($files) { foreach ($files as $f) if (under($f, $folder)) return true; return false; };

    if ($type === 'sonarr') {
        foreach (api('series') as $s) {
            if (!$under_any($s['path'] ?? '')) continue;
            foreach (api('episodefile?seriesId=' . (int)$s['id']) as $ef) {
                if (in_array($ef['path'] ?? '', $files, true)) { echo "owned\n"; exit(0); }
            }
            echo "not-owned\n"; exit(0);
        }
    } else {
        foreach (api('movie') as $m) {
            if (!$under_any($m['path'] ?? '')) continue;
            foreach (api('moviefile?movieId=' . (int)$m['id']) as $mf) {
                if (in_array($mf['path'] ?? '', $files, true)) { echo "owned\n"; exit(0); }
            }
            echo "not-owned\n"; exit(0);
        }
    }
    echo "unmanaged\n";
} catch (Exception $e) {
    echo "error: " . $e->getMessage() . "\n";
    exit(1);
}
