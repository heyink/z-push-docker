<?php
/**
 * Rewrite define()s in a Z-Push config file without sed escaping issues.
 *
 * usage: php zpush-setconfig.php <file> [CONST TYPE VALUE]... [--smtp-params JSON]
 *   TYPE: str | bool | int | intfalse | strfalse | raw
 *   An existing uncommented define('CONST', ...); line is replaced in place,
 *   otherwise the define is appended to the end of the file.
 * Exits non-zero on invalid values so the container refuses to start.
 */
if ($argc < 2) { fwrite(STDERR, "usage: {$argv[0]} file [CONST TYPE VALUE]...\n"); exit(2); }
$file = $argv[1];
$src = file_get_contents($file);
if ($src === false) { fwrite(STDERR, "cannot read $file\n"); exit(1); }

function fail($m) { fwrite(STDERR, "[z-push] config error: $m\n"); exit(1); }
function to_bool($v) {
    $l = strtolower(trim($v));
    if (in_array($l, ['1', 'true', 'yes', 'on'], true)) return true;
    if (in_array($l, ['0', 'false', 'no', 'off', ''], true)) return false;
    fail("not a boolean: '$v'");
}
function php_value($const, $type, $v) {
    switch ($type) {
        case 'str':      return var_export((string)$v, true);
        case 'bool':     return to_bool($v) ? 'true' : 'false';
        case 'int':      if (!preg_match('/^\d+$/', trim($v))) fail("$const must be an integer, got '$v'");
                         return (string)(int)$v;
        case 'intfalse': if (strtolower(trim($v)) === 'false' || trim($v) === '') return 'false';
                         return php_value($const, 'int', $v);
        case 'strfalse': if (strtolower(trim($v)) === 'false' || trim($v) === '') return 'false';
                         return var_export((string)$v, true);
        case 'raw':      if (!preg_match('/^[A-Z_][A-Z0-9_]*$/', $v)) fail("$const: invalid constant '$v'");
                         return $v;
    }
    fail("unknown type $type");
}

$i = 2;
while ($i < $argc) {
    if ($argv[$i] === '--smtp-params') {
        $params = json_decode($argv[$i + 1], true);
        if (!is_array($params)) fail('invalid smtp params JSON');
        $block = "\$imap_smtp_params = " . var_export($params, true) . ";";
        $n = 0;
        $src = preg_replace('/^\$imap_smtp_params\s*=\s*array\(\s*\);\s*$/m', addcslashes($block, '\\$'), $src, 1, $n);
        if ($n !== 1) fail("could not find '\$imap_smtp_params = array();' in $file");
        $i += 2;
        continue;
    }
    if ($i + 2 >= $argc) fail('incomplete CONST TYPE VALUE triple');
    [$const, $type, $raw] = [$argv[$i], $argv[$i + 1], $argv[$i + 2]];
    $i += 3;
    if (!preg_match('/^[A-Z_][A-Z0-9_]*$/', $const)) fail("invalid constant name '$const'");
    $line = "define('$const', " . php_value($const, $type, $raw) . ");";
    $re = '/^([ \t]*)define\(\s*[\'"]' . $const . '[\'"]\s*,.*\);[ \t]*$/m';
    $n = 0;
    $src = preg_replace_callback($re, function ($m) use ($line) { return $m[1] . $line; }, $src, -1, $n);
    if ($n === 0) $src = rtrim($src) . "\n" . $line . "\n";
}
if (file_put_contents($file, $src) === false) fail("cannot write $file");
