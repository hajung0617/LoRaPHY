% Software LoRaPHY text loopback.

script_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(fileparts(script_dir));
addpath(project_dir);

rf_freq = 470e6;    % carrier frequency 470 MHz, used to correct clock drift
sf = 7;             % spreading factor SF7
bw = 125e3;         % bandwidth 125 kHz
fs = 1e6;           % sampling rate 1 MHz

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;         % explicit header mode
phy.cr = 4;                 % code rate = 4/8 (1:4/5 2:4/6 3:4/7 4:4/8)
phy.crc = 1;                % enable payload CRC checksum
phy.preamble_len = 8;       % preamble: 8 basic upchirps

% Encode payload [1 2 3 4 5]
% symbols = phy.encode((1:5)');
message = 'Hello World!';
payload = unicode2native(message, 'UTF-8');
payload = uint8(payload(:));
symbols = phy.encode(payload);
fprintf("[encode] symbols:\n");
disp(symbols);

% Baseband Modulation
sig = phy.modulate(symbols);

% Demodulation
[symbols_d, cfo, netid] = phy.demodulate(sig);
fprintf("[demodulate] symbols:\n");
disp(symbols_d);

% Decoding
[data, checksum] = phy.decode(symbols_d);

fprintf("[decode] data:\n");
disp(data);

fprintf("[decode] checksum:\n");
disp(checksum);

received_bytes = uint8(data(1:phy.payload_len));
received_text = native2unicode(received_bytes(:)', 'UTF-8');

fprintf("[decode] text: %s\n", received_text);
