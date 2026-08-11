#!/usr/bin/env perl
use strict;
use warnings;

local $/;
my $text = <STDIN>;
$text = '' unless defined $text;

my $secret_tag = qr/(?:authToken|apiToken|password|passwd|secret|secretBytes|secretText|privateKey|passphrase|apiKey)/i;
my $secret_name = qr/[A-Za-z0-9_.-]*(?:api[_-]?key|api[_-]?token|access[_-]?token|token|password|passwd|secret|passphrase|private[_-]?key)[A-Za-z0-9_.-]*/i;

# Structured and multiline values.
$text =~ s#<($secret_tag)\b([^>]*)>.*?</\1\s*>#<${1}${2}>[REDACTED]</${1}>#gis;
$text =~ s#-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)* PRIVATE KEY-----#[REDACTED PRIVATE KEY]#gis;

# HTTP credentials and URL-borne credentials.
$text =~ s#(\bAuthorization\s*:\s*(?:Basic|Bearer)\s+)[^\s<]+#${1}[REDACTED]#gi;
$text =~ s#(https?://)[^/:\s<]+:[^@\s<]+@#${1}[REDACTED]@#gi;
$text =~ s#((?:[?&]|&amp;)(?:token|api[_-]?token|access[_-]?token|key|api[_-]?key)=)[^&\s"'<>]+#${1}[REDACTED]#gi;

# Shell, properties, YAML, and JSON-style assignments.
$text =~ s#($secret_name\s*[:=]\s*)"(?:\\.|[^"\\])*"#${1}[REDACTED]#g;
$text =~ s#($secret_name\s*[:=]\s*)'(?:\\.|[^'\\])*'#${1}[REDACTED]#g;
$text =~ s#($secret_name\s*[:=]\s*)(?:&quot;|&\#34;).*?(?:&quot;|&\#34;)#${1}[REDACTED]#gis;
$text =~ s#($secret_name\s*[:=]\s*)[^\s,;&<>"']+#${1}[REDACTED]#g;
$text =~ s#((?:"|')$secret_name(?:"|')\s*:\s*)"(?:\\.|[^"\\])*"#${1}[REDACTED]#g;
$text =~ s#((?:"|')$secret_name(?:"|')\s*:\s*)'(?:\\.|[^'\\])*'#${1}[REDACTED]#g;
$text =~ s#((?:"|')$secret_name(?:"|')\s*:\s*)[^\s,;&<>"']+#${1}[REDACTED]#g;

# Common opaque secret encodings. These intentionally favor privacy over fidelity.
$text =~ s#\{[A-Za-z0-9+/_=-]{20,}\}#[REDACTED JENKINS SECRET]#g;
$text =~ s#\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,}\b#[REDACTED JWT]#g;
$text =~ s#\b(?:AKIA|ASIA)[A-Z0-9]{16}\b#[REDACTED ACCESS KEY]#g;
$text =~ s#\bgh[pousr]_[A-Za-z0-9]{20,}\b#[REDACTED TOKEN]#gi;
$text =~ s#\b[A-Za-z0-9+/]{40,}={0,2}\b#[REDACTED BASE64]#g;
$text =~ s#\b[0-9a-f]{32,}\b#[REDACTED HEX]#gi;

print $text;
